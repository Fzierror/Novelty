import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:novelty/models/episode.dart';
import 'package:novelty/models/novel_info.dart';
import 'package:novelty/models/novel_search_query.dart';
import 'package:novelty/models/novel_search_result.dart';
import 'package:novelty/models/ranking_page.dart';
import 'package:novelty/services/api_service.dart' show NovelNotFoundException;
import 'package:novelty/sites/novel_site.dart';
import 'package:novelty/sites/novel_source.dart';
import 'package:novelty/sites/site_http.dart';
import 'package:novelty/utils/ncode_utils.dart';

/// 小説家になろうのR18系サイト（ノクターン／ミッドナイト）のサイト定義。
///
/// なろうと同じ基盤のため、作品情報・検索・ランキングは
/// [なろうR18小説API](https://dev.syosetu.com/xman/api/)（`novel18api`）、
/// 目次・本文は `novel18.syosetu.com` のHTMLから取得する。
///
/// - サイトの区別はAPIの `nocgenre` パラメータで行う
///   （1=ノクターン, 2=ムーンライト女性向け, 3=ムーンライトBL, 4=ミッドナイト）
/// - HTML取得時は年齢確認済みCookie（`over18=yes`）を付与する
/// - R18ランキングAPIは存在しないため、ランキングは
///   `novel18api` のポイント順ソートで代替する
class Syosetu18Site extends NovelSite {
  /// コンストラクタ。
  ///
  /// [dio] と [rateLimiter] はテスト時に注入できる。
  Syosetu18Site({
    required this.source,
    required this.nocgenre,
    Dio? dio,
    SiteRateLimiter? rateLimiter,
  }) : _dio = dio ?? Dio(),
       _rateLimiter = rateLimiter ?? SiteRateLimiter();

  /// ノクターンノベルズのサイト定義を生成する。
  factory Syosetu18Site.nocturne({Dio? dio, SiteRateLimiter? rateLimiter}) =>
      Syosetu18Site(
        source: NovelSource.nocturne,
        nocgenre: nocgenreNocturne,
        dio: dio,
        rateLimiter: rateLimiter,
      );

  /// ミッドナイトノベルズのサイト定義を生成する。
  factory Syosetu18Site.midnight({Dio? dio, SiteRateLimiter? rateLimiter}) =>
      Syosetu18Site(
        source: NovelSource.midnight,
        nocgenre: nocgenreMidnight,
        dio: dio,
        rateLimiter: rateLimiter,
      );

  /// ノクターンノベルズの `nocgenre` 値。
  static const int nocgenreNocturne = 1;

  /// ミッドナイトノベルズの `nocgenre` 値。
  static const int nocgenreMidnight = 4;

  /// R18小説APIのホスト。
  static const String _apiHost = 'api.syosetu.com';

  /// R18小説APIのパス。
  static const String _apiPath = '/novel18api/api/';

  /// APIの検索開始位置（st）の上限。
  static const int _maxStart = 2000;

  /// ランキング1ページあたりの件数。
  static const int _rankingPageSize = 20;

  /// 年齢確認済みとして扱うCookie。
  static const String _over18Cookie = 'over18=yes';

  final Dio _dio;
  final SiteRateLimiter _rateLimiter;

  @override
  final NovelSource source;

  /// APIの `nocgenre`（掲載サイト）パラメータ値。
  final int nocgenre;

  /// なろうと同じポイント表記。
  @override
  String? metaText(NovelInfo info) {
    final point = info.allPoint;
    if (point == null) {
      return null;
    }
    return '${(point / 1000).toStringAsFixed(1)}k pt';
  }

  /// R18系サイトにはなろうのようなジャンル区分がないため空とする。
  @override
  List<GenreMaster> get genres => const <GenreMaster>[];

  /// ランキング種別マスタ。
  ///
  /// IDはなろうと共通、[RankingTypeMaster.urlPath] はAPIの `order` 値。
  @override
  List<RankingTypeMaster> get rankingTypes => const <RankingTypeMaster>[
    RankingTypeMaster(id: 'd', label: '日間', urlPath: 'dailypoint'),
    RankingTypeMaster(id: 'w', label: '週間', urlPath: 'weeklypoint'),
    RankingTypeMaster(id: 'm', label: '月間', urlPath: 'monthlypoint'),
    RankingTypeMaster(id: 'q', label: '四半期', urlPath: 'quarterpoint'),
    RankingTypeMaster(id: 'all', label: '累計', urlPath: 'hyoka'),
  ];

  /// 作品情報をAPIから取得する。
  @override
  Future<NovelInfo> fetchNovelInfo(String workId) async {
    final result = await _callApi(<String, String>{
      'ncode': workId.toNormalizedNcode(),
    });
    if (result.novels.isEmpty) {
      throw const NovelNotFoundException();
    }
    return result.novels.first;
  }

  /// キーワード検索を実行する。
  ///
  /// 使用する条件は [NovelSearchQuery.word] / [NovelSearchQuery.notword] /
  /// [NovelSearchQuery.order] / [NovelSearchQuery.lim] / [NovelSearchQuery.st]。
  @override
  Future<NovelSearchResult> searchNovels(NovelSearchQuery query) {
    final word = query.word?.trim() ?? '';
    final notword = query.notword?.trim() ?? '';
    return _callApi(<String, String>{
      if (word.isNotEmpty) 'word': word,
      if (notword.isNotEmpty) 'notword': notword,
      'order': query.order,
      'lim': '${query.lim}',
      'st': '${query.st}',
    });
  }

  /// ランキングをAPIのポイント順ソートで取得する。
  @override
  Future<RankingPage> fetchRanking(
    String rankingType, {
    int page = 1,
  }) async {
    final type = rankingTypes.where((t) => t.id == rankingType).firstOrNull;
    if (type == null) {
      throw ArgumentError.value(rankingType, 'rankingType', '未対応の種別です');
    }
    final start = (page - 1) * _rankingPageSize + 1;
    if (start > _maxStart) {
      return const RankingPage(novels: <NovelInfo>[], hasNextPage: false);
    }
    final result = await _callApi(<String, String>{
      'order': type.urlPath,
      'lim': '$_rankingPageSize',
      'st': '$start',
    });
    final hasNext =
        result.novels.length >= _rankingPageSize &&
        start + _rankingPageSize <= _maxStart &&
        start + _rankingPageSize <= result.allCount;
    return RankingPage(novels: result.novels, hasNextPage: hasNext);
  }

  /// 目次の全エピソードを取得する。
  ///
  /// 目次は100話ごとにページ分割されているため、次ページがなくなるまで取得する。
  @override
  Future<List<Episode>> fetchToc(String workId) async {
    final all = <Episode>[];
    // 異常なループを防ぐための上限（10,000話相当）
    const maxPages = 100;
    for (var page = 1; page <= maxPages; page++) {
      final (episodes, hasNext) = await _fetchTocPageWithPager(workId, page);
      all.addAll(episodes);
      if (!hasNext) {
        break;
      }
    }
    return all;
  }

  /// 目次の指定ページのみを取得する（`/{ncode}/?p={page}`）。
  @override
  Future<List<Episode>> fetchTocPage(String workId, int page) async {
    if (page < 1) {
      return const <Episode>[];
    }
    final (episodes, _) = await _fetchTocPageWithPager(workId, page);
    return episodes;
  }

  /// エピソード本文を取得する。
  ///
  /// [url] が省略された場合は `/{ncode}/{index}/` を組み立てる。
  /// 短編は `/{ncode}/{index}/` が404になるため、
  /// [index] が1の場合は作品トップ（`/{ncode}/`）にフォールバックする。
  @override
  Future<Episode> fetchEpisode(
    String workId,
    int index, {
    String? url,
  }) async {
    final ncode = workId.toNormalizedNcode();
    var episodeUrl = url ?? '${source.baseUrl}/$ncode/$index/';
    var response = await _get(episodeUrl);
    if (response.statusCode == 404 && url == null && index == 1) {
      episodeUrl = '${source.baseUrl}/$ncode/';
      response = await _get(episodeUrl);
    }
    _ensureOk(response, episodeUrl);
    return parseEpisodePage(response.data ?? '', index, episodeUrl);
  }

  /// エピソードページのHTMLを [Episode] に変換する。
  ///
  /// 前書き・後書きを除いた本文のみを返す。
  /// 本文が見つからない場合（年齢確認ページ等）は [FormatException] を投げる。
  Episode parseEpisodePage(String html, int index, String episodeUrl) {
    final document = html_parser.parse(html);
    final title =
        (document.querySelector('h1.p-novel__title--rensai') ??
                document.querySelector('h1.p-novel__title'))
            ?.text
            .trim();
    final textBlocks = document.querySelectorAll(
      '.p-novel__text:not(.p-novel__text--preface):not('
      '.p-novel__text--afterword)',
    );
    if (textBlocks.isEmpty) {
      throw FormatException('本文が見つかりません（年齢確認ページの可能性）: $episodeUrl');
    }
    return Episode(
      source: source,
      index: index,
      subtitle: title,
      url: episodeUrl,
      body: textBlocks.map((el) => el.innerHtml).join(),
    );
  }

  /// 目次ページのHTMLを解析し、エピソード一覧と次ページ有無を返す。
  ///
  /// 短編（目次がなく本文のみのページ）の場合は1話のみのリストを返す。
  (List<Episode>, bool) parseTocPage(String html, String workId) {
    final ncode = workId.toNormalizedNcode();
    final document = html_parser.parse(html);
    final episodes = _parseEpisodeList(document);
    final hasNext =
        document.querySelector('.c-pager__item--next') != null &&
        episodes.isNotEmpty;

    if (episodes.isEmpty && document.querySelector('.p-novel__body') != null) {
      // 短編：作品トップ自体が本文ページ
      final title = document.querySelector('h1.p-novel__title')?.text.trim();
      return (
        <Episode>[
          Episode(
            source: source,
            index: 1,
            subtitle: title,
            url: '${source.baseUrl}/$ncode/',
          ),
        ],
        false,
      );
    }
    return (episodes, hasNext);
  }

  Future<(List<Episode>, bool)> _fetchTocPageWithPager(
    String workId,
    int page,
  ) async {
    final ncode = workId.toNormalizedNcode();
    final url = page > 1
        ? '${source.baseUrl}/$ncode/?p=$page'
        : '${source.baseUrl}/$ncode/';
    final response = await _get(url);
    if (response.statusCode == 404) {
      if (page == 1) {
        throw const NovelNotFoundException();
      }
      return (const <Episode>[], false);
    }
    _ensureOk(response, url);
    return parseTocPage(response.data ?? '', workId);
  }

  /// 目次（`.p-eplist__sublist`）をパースする。
  ///
  /// なろう本体（ApiService）と同じHTML構造。
  List<Episode> _parseEpisodeList(dom.Document document) {
    final elements = document.querySelectorAll('.p-eplist__sublist');
    final episodes = <Episode>[];
    for (final el in elements) {
      final subtitle = el.querySelector('.p-eplist__subtitle');
      final update = el.querySelector('.p-eplist__update');
      final revisedAttr = update?.querySelector('span')?.attributes['title'];
      final href = subtitle?.attributes['href'];
      int? index;
      if (href != null) {
        final match = RegExp(r'/(\d+)/?$').firstMatch(href);
        if (match != null) {
          index = int.tryParse(match.group(1)!);
        }
      }
      episodes.add(
        Episode(
          source: source,
          subtitle: subtitle?.text.trim(),
          url: _toAbsoluteUrl(href),
          update: update?.text
              .trim()
              .replaceAll(RegExp('（.+）'), '')
              .trim(),
          revised: revisedAttr?.replaceAll(' 改稿', '').trim(),
          index: index,
        ),
      );
    }
    return episodes;
  }

  /// R18小説APIを呼び出し、結果を [NovelSearchResult] に変換する。
  Future<NovelSearchResult> _callApi(Map<String, String> params) async {
    final uri = Uri.https(_apiHost, _apiPath, <String, String>{
      ...params,
      'nocgenre': '$nocgenre',
      'out': 'json',
    });
    final url = uri.toString();
    await _rateLimiter.wait();
    final response = await _dio.get<String>(
      url,
      options: Options(
        headers: <String, String>{'User-Agent': browserUserAgent},
        responseType: ResponseType.plain,
      ),
    );
    _ensureOk(response, url);
    return parseApiResponse(response.data ?? '[]');
  }

  /// R18小説APIのJSONレスポンスを [NovelSearchResult] に変換する。
  ///
  /// 先頭要素は `allcount`、以降が作品データ（なろう小説APIと同形式）。
  NovelSearchResult parseApiResponse(String body) {
    final decoded = json.decode(body);
    if (decoded is! List || decoded.isEmpty) {
      return const NovelSearchResult(novels: <NovelInfo>[], allCount: 0);
    }
    final head = decoded.first;
    final allCount = head is Map<String, dynamic>
        ? (head['allcount'] as num?)?.toInt() ?? 0
        : 0;
    final novels = decoded
        .skip(1)
        .whereType<Map<String, dynamic>>()
        .map(_toNovelInfo)
        .toList();
    return NovelSearchResult(novels: novels, allCount: allCount);
  }

  /// APIの作品データを [NovelInfo] に変換する。
  NovelInfo _toNovelInfo(Map<String, dynamic> raw) {
    final data = Map<String, dynamic>.of(raw);
    // APIは連載/短編を `noveltype` で返す（1=連載, 2=短編）
    data['novel_type'] ??= data['noveltype'];
    if (data['novel_type'] == null) {
      final allNo = int.tryParse('${data['general_all_no'] ?? ''}') ?? 0;
      data['novel_type'] = allNo <= 1 ? 2 : 1;
    }
    final ncode = (data['ncode'] as String?)?.toNormalizedNcode();
    return NovelInfo.fromJson(data).copyWith(
      source: source,
      workId: ncode,
      // ncode はなろう本体専用（表紙画像URL等に使われる）のため保持しない
      ncode: null,
    );
  }

  /// 年齢確認Cookieを付与してGETする。404はそのまま返す。
  Future<Response<String>> _get(String url) async {
    await _rateLimiter.wait();
    return _dio.get<String>(
      url,
      options: Options(
        headers: <String, String>{
          'User-Agent': browserUserAgent,
          'Cookie': _over18Cookie,
        },
        responseType: ResponseType.plain,
        followRedirects: true,
        validateStatus: (status) => status != null && status < 500,
      ),
    );
  }

  void _ensureOk(Response<dynamic> response, String url) {
    final status = response.statusCode ?? -1;
    if (status != 200) {
      throw SiteHttpException(status, url);
    }
  }

  String? _toAbsoluteUrl(String? href) {
    if (href == null) {
      return null;
    }
    if (Uri.parse(href).hasScheme) {
      return href;
    }
    return '${source.baseUrl}$href';
  }
}
