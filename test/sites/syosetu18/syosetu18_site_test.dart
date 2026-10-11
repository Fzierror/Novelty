import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelty/models/novel_search_query.dart';
import 'package:novelty/services/api_service.dart' show NovelNotFoundException;
import 'package:novelty/sites/novel_source.dart';
import 'package:novelty/sites/site_http.dart';
import 'package:novelty/sites/syosetu18/syosetu18_site.dart';

/// リクエストURIに応じてレスポンスを返すHTTPアダプタ。
class _HandlerAdapter implements HttpClientAdapter {
  _HandlerAdapter(this._handler);

  /// URIを受け取り（ステータス, 本文）を返す。nullの場合は404。
  final (int, String)? Function(Uri uri) _handler;

  /// リクエストされたURIの一覧。
  final List<Uri> requested = <Uri>[];

  /// リクエストヘッダーの一覧（requestedと同順）。
  final List<Map<String, dynamic>> headers = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requested.add(uri);
    headers.add(Map<String, dynamic>.of(options.headers));
    final result = _handler(uri) ?? (404, 'not found');
    return ResponseBody.fromString(
      result.$2,
      result.$1,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _fixture(String name) =>
    File('test/fixtures/syosetu18/$name').readAsStringSync();

Syosetu18Site _site(_HandlerAdapter adapter, {bool midnight = false}) {
  final dio = Dio()..httpClientAdapter = adapter;
  final limiter = SiteRateLimiter(interval: Duration.zero);
  return midnight
      ? Syosetu18Site.midnight(dio: dio, rateLimiter: limiter)
      : Syosetu18Site.nocturne(dio: dio, rateLimiter: limiter);
}

void main() {
  group('Syosetu18Site 基本情報', () {
    test('ノクターンとミッドナイトでsourceとnocgenreが異なる', () {
      final adapter = _HandlerAdapter((_) => null);
      final nocturne = _site(adapter);
      final midnight = _site(adapter, midnight: true);
      expect(nocturne.source, NovelSource.nocturne);
      expect(nocturne.nocgenre, 1);
      expect(midnight.source, NovelSource.midnight);
      expect(midnight.nocgenre, 4);
    });

    test('ランキング種別は5種類', () {
      final site = _site(_HandlerAdapter((_) => null));
      expect(site.rankingTypes.map((t) => t.id), ['d', 'w', 'm', 'q', 'all']);
    });
  });

  group('fetchNovelInfo', () {
    test('novel18apiにncodeとnocgenreを指定して作品情報を取得する', () async {
      final adapter = _HandlerAdapter(
        (uri) => uri.host == 'api.syosetu.com'
            ? (200, _fixture('api_novel.json'))
            : null,
      );
      final info = await _site(adapter).fetchNovelInfo('N9999ZZ');

      final uri = adapter.requested.single;
      expect(uri.path, '/novel18api/api/');
      expect(uri.queryParameters['ncode'], 'n9999zz');
      expect(uri.queryParameters['nocgenre'], '1');
      expect(uri.queryParameters['out'], 'json');

      expect(info.source, NovelSource.nocturne);
      expect(info.workId, 'n9999zz');
      expect(info.ncode, isNull);
      expect(info.title, 'テスト作品');
      expect(info.writer, 'テスト作者');
      expect(info.novelType, 1);
      expect(info.generalAllNo, 101);
      expect(info.allPoint, 4000);
    });

    test('該当作品がない場合はNovelNotFoundException', () async {
      final adapter = _HandlerAdapter((_) => (200, '[{"allcount":0}]'));
      await expectLater(
        _site(adapter).fetchNovelInfo('n0000aa'),
        throwsA(isA<NovelNotFoundException>()),
      );
    });
  });

  group('searchNovels / fetchRanking', () {
    test('キーワード・並び順・ページングをAPIに渡す', () async {
      final adapter = _HandlerAdapter(
        (_) => (200, _fixture('api_search.json')),
      );
      final result = await _site(adapter, midnight: true).searchNovels(
        const NovelSearchQuery(word: '魔法', order: 'weekly', st: 21),
      );

      final params = adapter.requested.single.queryParameters;
      expect(params['word'], '魔法');
      expect(params['order'], 'weekly');
      expect(params['st'], '21');
      expect(params['lim'], '20');
      expect(params['nocgenre'], '4');

      expect(result.allCount, 45);
      expect(result.novels.map((n) => n.workId), ['n0001aa', 'n0002bb']);
      expect(
        result.novels.every((n) => n.source == NovelSource.midnight),
        true,
      );
      expect(result.novels[1].novelType, 2);
    });

    test('ランキングはポイント順ソートで取得する', () async {
      final adapter = _HandlerAdapter(
        (_) => (200, _fixture('api_search.json')),
      );
      final page = await _site(adapter).fetchRanking('w', page: 2);

      final params = adapter.requested.single.queryParameters;
      expect(params['order'], 'weeklypoint');
      expect(params['st'], '21');
      // 2件しか返らないため次ページなし
      expect(page.hasNextPage, false);
      expect(page.novels, hasLength(2));
    });
  });

  group('目次', () {
    (int, String)? tocHandler(Uri uri) {
      if (uri.host != 'novel18.syosetu.com' || uri.path != '/n9999zz/') {
        return null;
      }
      return uri.queryParameters['p'] == '2'
          ? (200, _fixture('toc_page2.html'))
          : (200, _fixture('toc_page1.html'));
    }

    test('fetchTocPageは指定ページのみを取得する', () async {
      final adapter = _HandlerAdapter(tocHandler);
      final episodes = await _site(adapter).fetchTocPage('n9999zz', 1);

      expect(adapter.requested, hasLength(1));
      expect(episodes, hasLength(2));
      expect(episodes[0].index, 1);
      expect(episodes[0].subtitle, '第1話 はじまり');
      expect(episodes[0].url, 'https://novel18.syosetu.com/n9999zz/1/');
      expect(episodes[0].update, '2024/01/01 00:00');
      expect(episodes[0].revised, '2024/02/01 12:34');
      expect(episodes[0].source, NovelSource.nocturne);
      expect(episodes[1].revised, isNull);
    });

    test('年齢確認Cookieを付与する', () async {
      final adapter = _HandlerAdapter(tocHandler);
      await _site(adapter).fetchTocPage('n9999zz', 1);
      expect(adapter.headers.single['Cookie'], 'over18=yes');
    });

    test('fetchTocは次ページがなくなるまで取得する', () async {
      final adapter = _HandlerAdapter(tocHandler);
      final episodes = await _site(adapter).fetchToc('n9999zz');

      expect(adapter.requested, hasLength(2));
      expect(episodes.map((e) => e.index), [1, 2, 101]);
    });

    test('短編は作品トップを1話として返す', () async {
      final adapter = _HandlerAdapter(
        (_) => (200, _fixture('short_story.html')),
      );
      final episodes = await _site(adapter).fetchToc('n1111ss');

      expect(episodes, hasLength(1));
      expect(episodes.single.index, 1);
      expect(episodes.single.subtitle, '短編作品');
      expect(episodes.single.url, 'https://novel18.syosetu.com/n1111ss/');
    });
  });

  group('fetchEpisode', () {
    test('前書き・後書きを除いた本文を取得する', () async {
      final adapter = _HandlerAdapter(
        (uri) => uri.path == '/n9999zz/1/'
            ? (200, _fixture('episode.html'))
            : null,
      );
      final episode = await _site(adapter).fetchEpisode('n9999zz', 1);

      expect(episode.subtitle, '第1話 はじまり');
      expect(episode.url, 'https://novel18.syosetu.com/n9999zz/1/');
      expect(episode.body, contains('本文'));
      expect(episode.body, isNot(contains('前書き')));
      expect(episode.body, isNot(contains('後書き')));
    });

    test('短編は /{ncode}/1/ が404なら作品トップにフォールバックする', () async {
      final adapter = _HandlerAdapter(
        (uri) => uri.path == '/n1111ss/'
            ? (200, _fixture('short_story.html'))
            : null,
      );
      final episode = await _site(adapter).fetchEpisode('n1111ss', 1);

      expect(
        adapter.requested.map((u) => u.path),
        ['/n1111ss/1/', '/n1111ss/'],
      );
      expect(episode.body, contains('短編の本文です。'));
    });

    test('年齢確認ページが返った場合はFormatException', () async {
      final adapter = _HandlerAdapter((_) => (200, _fixture('age_gate.html')));
      await expectLater(
        _site(adapter).fetchEpisode('n9999zz', 1),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
