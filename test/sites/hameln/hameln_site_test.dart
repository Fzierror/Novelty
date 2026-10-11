import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novelty/models/novel_search_query.dart';
import 'package:novelty/services/api_service.dart' show NovelNotFoundException;
import 'package:novelty/sites/hameln/hameln_site.dart';
import 'package:novelty/sites/html_fetcher.dart';
import 'package:novelty/sites/novel_source.dart';
import 'package:novelty/sites/site_http.dart';

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
    requested.add(options.uri);
    headers.add(Map<String, dynamic>.of(options.headers));
    final result = _handler(options.uri) ?? (404, 'not found');
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

/// 取得したURLを記録し、固定のHTMLを返すフェッチャー。
class _FakeFetcher implements HtmlFetcher {
  _FakeFetcher(this.html);

  final String html;
  final List<String> urls = <String>[];

  @override
  Future<String> fetch(String url) async {
    urls.add(url);
    return html;
  }
}

String _fixture(String name) =>
    File('test/fixtures/hameln/$name').readAsStringSync();

HamelnSite _site(_HandlerAdapter adapter) => HamelnSite(
  dio: Dio()..httpClientAdapter = adapter,
  rateLimiter: SiteRateLimiter(interval: Duration.zero),
);

/// 指定パスのみフィクスチャを返すハンドラ。
(int, String)? Function(Uri) _only(String path, String fixture) =>
    (uri) => uri.path == path ? (200, _fixture(fixture)) : null;

void main() {
  group('fetchNovelInfo', () {
    test('作品トップからタイトル・作者・あらすじ・話数を取得する', () async {
      final adapter = _HandlerAdapter(
        _only('/novel/123456/', 'novel_top.html'),
      );
      final info = await _site(adapter).fetchNovelInfo('123456');

      expect(
        adapter.requested.single.toString(),
        'https://syosetu.org/novel/123456/',
      );
      expect(info.source, NovelSource.hameln);
      expect(info.workId, '123456');
      expect(info.ncode, isNull);
      expect(info.title, 'テスト二次創作');
      expect(info.writer, 'テスト作者');
      expect(info.story, 'これはあらすじです。');
      expect(info.novelType, 1);
      expect(info.generalAllNo, 3);
    });

    test('年齢確認Cookieとブラウザ相当のUser-Agentを付与する', () async {
      final adapter = _HandlerAdapter(
        _only('/novel/123456/', 'novel_top.html'),
      );
      await _site(adapter).fetchNovelInfo('123456');

      expect(adapter.headers.single['Cookie'], 'over18=off');
      expect(adapter.headers.single['User-Agent'], browserUserAgent);
    });

    test('短編は話数1・novelType 2', () async {
      final adapter = _HandlerAdapter(_only('/novel/7/', 'short_story.html'));
      final info = await _site(adapter).fetchNovelInfo('7');

      expect(info.title, '短編テスト');
      expect(info.writer, '短編作者');
      expect(info.novelType, 2);
      expect(info.generalAllNo, 1);
    });

    test('404はNovelNotFoundException', () async {
      final adapter = _HandlerAdapter((_) => null);
      await expectLater(
        _site(adapter).fetchNovelInfo('1'),
        throwsA(isA<NovelNotFoundException>()),
      );
    });
  });

  group('fetchToc', () {
    test('目次テーブルのエピソードを目次順に取得する', () async {
      final adapter = _HandlerAdapter(
        _only('/novel/123456/', 'novel_top.html'),
      );
      final episodes = await _site(adapter).fetchToc('123456');

      expect(episodes.map((e) => e.index), [1, 2, 3]);
      expect(episodes.map((e) => e.subtitle), [
        '第1話　出会い',
        '第2話　別れ',
        '第3話　再会',
      ]);
      expect(episodes.map((e) => e.url), [
        'https://syosetu.org/novel/123456/1.html',
        'https://syosetu.org/novel/123456/2.html',
        'https://syosetu.org/novel/123456/3.html',
      ]);
      expect(episodes[0].update, '2024/01/02 03:04');
      expect(episodes[0].revised, '2024/02/03 05:06');
      expect(episodes[1].update, '2024/01/09 12:00');
      expect(episodes[1].revised, isNull);
      expect(episodes.every((e) => e.source == NovelSource.hameln), true);
    });

    test('短編は作品トップを1話として返す', () async {
      final adapter = _HandlerAdapter(_only('/novel/7/', 'short_story.html'));
      final episodes = await _site(adapter).fetchToc('7');

      expect(episodes, hasLength(1));
      expect(episodes.single.url, 'https://syosetu.org/novel/7/');
      expect(episodes.single.subtitle, '短編テスト');
    });

    test('fetchTocPageはデフォルト実装で100件ずつ区切る', () async {
      final adapter = _HandlerAdapter(
        _only('/novel/123456/', 'novel_top.html'),
      );
      final site = _site(adapter);
      expect(await site.fetchTocPage('123456', 1), hasLength(3));
      expect(await site.fetchTocPage('123456', 2), isEmpty);
    });
  });

  group('fetchEpisode', () {
    test('前書き・後書きを除いた本文とサブタイトルを取得する', () async {
      final adapter = _HandlerAdapter(
        _only('/novel/123456/1.html', 'episode.html'),
      );
      final episode = await _site(adapter).fetchEpisode('123456', 1);

      expect(episode.source, NovelSource.hameln);
      expect(episode.index, 1);
      expect(episode.subtitle, '第1話　出会い');
      expect(episode.url, 'https://syosetu.org/novel/123456/1.html');
      expect(episode.body, contains('<ruby>本文'));
      expect(episode.body, isNot(contains('前書き')));
      expect(episode.body, isNot(contains('後書き')));
    });

    test('短編は目次で解決したURL（作品トップ）から本文を取得する', () async {
      final adapter = _HandlerAdapter(_only('/novel/7/', 'short_story.html'));
      final episode = await _site(
        adapter,
      ).fetchEpisode('7', 1, url: 'https://syosetu.org/novel/7/');

      expect(episode.body, contains('短編の本文です。'));
      expect(episode.subtitle, '短編テスト');
    });

    test('年齢確認ページが返った場合はFormatException', () async {
      final adapter = _HandlerAdapter((_) => (200, _fixture('age_gate.html')));
      await expectLater(
        _site(adapter).fetchEpisode('123456', 1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('HtmlFetcher（WebView取得）', () {
    test('fetcherを指定するとHTTP通信の代わりにそれで取得する', () async {
      final adapter = _HandlerAdapter((_) => null);
      final fetcher = _FakeFetcher(_fixture('novel_top.html'));
      final site = HamelnSite(
        dio: Dio()..httpClientAdapter = adapter,
        rateLimiter: SiteRateLimiter(interval: Duration.zero),
        fetcher: fetcher,
      );
      final info = await site.fetchNovelInfo('123456');

      expect(fetcher.urls, ['https://syosetu.org/novel/123456/']);
      expect(adapter.requested, isEmpty);
      expect(info.title, 'テスト二次創作');
    });
  });

  group('エラーの切り分け', () {
    test('Cloudflareの確認ページはBotChallengeException', () async {
      final adapter = _HandlerAdapter(
        (_) => (
          403,
          '<html><head><title>Just a moment...</title></head></html>',
        ),
      );
      await expectLater(
        _site(adapter).fetchRanking('daily'),
        throwsA(isA<BotChallengeException>()),
      );
    });

    test('ランキングから作品が見つからない場合はFormatException', () async {
      final adapter = _HandlerAdapter(
        (_) => (200, '<html><body></body></html>'),
      );
      await expectLater(
        _site(adapter).fetchRanking('daily'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('検索・ランキング', () {
    test('検索結果から作品ID・タイトル・作者と次ページ有無を取得する', () async {
      final adapter = _HandlerAdapter(_only('/search/', 'search.html'));
      final result = await _site(
        adapter,
      ).searchNovels(const NovelSearchQuery(word: 'test'));

      final params = adapter.requested.single.queryParameters;
      expect(params['mode'], 'search');
      expect(params['word'], 'test');
      expect(params.containsKey('page'), false);

      expect(result.novels.map((n) => n.workId), ['111', '222']);
      expect(result.novels.map((n) => n.title), ['作品その1', '作品その2']);
      expect(result.novels.map((n) => n.writer), ['作者その1', '作者その2']);
      // 次ページがあるため、読み込み済み件数より多い総件数を返す
      expect(result.allCount, greaterThan(result.novels.length));
    });

    test('2ページ目はpageパラメータを付与する', () async {
      final adapter = _HandlerAdapter(_only('/search/', 'search.html'));
      await _site(
        adapter,
      ).searchNovels(const NovelSearchQuery(word: 'test', st: 21));

      expect(adapter.requested.single.queryParameters['page'], '2');
    });

    test('ランキングはトップページのmodeパラメータで取得する', () async {
      final adapter = _HandlerAdapter(
        (uri) => uri.path == '/' ? (200, _fixture('search.html')) : null,
      );
      final page = await _site(adapter).fetchRanking('daily');

      expect(adapter.requested.single.queryParameters['mode'], 'rank');
      expect(page.novels, hasLength(2));
      expect(page.hasNextPage, true);
    });
  });
}
