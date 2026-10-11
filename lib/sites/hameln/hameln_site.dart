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

/// ハーメルン（syosetu.org）のサイト定義。
///
/// 公式APIが存在しないため、公開HTMLの取得・解析で
/// 作品情報・目次・本文・検索・ランキングを提供する。
///
/// - 作品トップ: `/novel/{id}/`（目次。短編は本文を直接含む）
/// - 本文: `/novel/{id}/{n}.html`（`#honbun`）
/// - R18作品の年齢確認は Cookie `over18=off` で省略する
/// - サーバー負荷軽減のため2秒間隔でアクセスする
///
/// 検索結果・ランキングはレイアウト変更に強くするため、
/// 特定のクラス名ではなく作品リンク（`/novel/{id}/`）を起点に解析する。
class HamelnSite extends NovelSite {
  /// コンストラクタ。
  ///
  /// [dio] と [rateLimiter] はテスト時に注入できる。
  HamelnSite({Dio? dio, SiteRateLimiter? rateLimiter})
    : _dio = dio ?? Dio(),
      _rateLimiter =
          rateLimiter ?? SiteRateLimiter(interval: const Duration(seconds: 2));

  final Dio _dio;
  final SiteRateLimiter _rateLimiter;

  /// 年齢確認を省略するCookie。
  static const String _over18Cookie = 'over18=off';

  /// 作品トップへのリンク（`/novel/{id}/`）。エピソードリンクは含まない。
  static final RegExp _novelLinkPattern = RegExp(
    r'(?:^|syosetu\.org)/novel/(\d+)/?$',
  );

  /// エピソードへのリンク（`./{n}.html` や `/novel/{id}/{n}.html`）。
  static final RegExp _episodeLinkPattern = RegExp(r'(?:^|/)(\d+)\.html$');

  /// 日時表記（例: `2024年01月02日(火) 03:04`）。
  static final RegExp _datePattern = RegExp(
    r'(\d{4})年(\d{1,2})月(\d{1,2})日[^\d]*?(\d{1,2}):(\d{2})',
  );

  @override
  NovelSource get source => NovelSource.hameln;

  /// ハーメルンは一覧で表示できる評価指標を取得しないため null。
  @override
  String? metaText(NovelInfo info) => null;

  /// ハーメルンは原作（二次創作元）単位の分類のため、ジャンルは扱わない。
  @override
  List<GenreMaster> get genres => const <GenreMaster>[];

  /// ランキング種別マスタ。
  ///
  /// [RankingTypeMaster.urlPath] はトップページの `mode` パラメータ値。
  @override
  List<RankingTypeMaster> get rankingTypes => const <RankingTypeMaster>[
    RankingTypeMaster(id: 'daily', label: '日間', urlPath: 'rank'),
  ];

  /// 作品トップのURL。
  String workUrl(String workId) => '${source.baseUrl}/novel/$workId/';

  /// 作品情報を取得する。
  @override
  Future<NovelInfo> fetchNovelInfo(String workId) async {
    final html = await _fetch(workUrl(workId));
    return parseNovelInfo(html, workId);
  }

  /// 目次（エピソード一覧）を取得する。
  ///
  /// ハーメルンの目次は1ページに全話が載るため、1リクエストで取得する。
  @override
  Future<List<Episode>> fetchToc(String workId) async {
    final html = await _fetch(workUrl(workId));
    return parseToc(html, workId);
  }

  /// エピソード本文を取得する。
  ///
  /// [url] が省略された場合は `/novel/{id}/{index}.html` を組み立てる
  /// （ハーメルンの話番号は目次順の連番）。
  @override
  Future<Episode> fetchEpisode(
    String workId,
    int index, {
    String? url,
  }) async {
    final episodeUrl = url ?? '${workUrl(workId)}$index.html';
    final html = await _fetch(episodeUrl);
    return parseEpisode(html, index, episodeUrl);
  }

  /// キーワード検索を実行する。
  ///
  /// 使用する条件は [NovelSearchQuery.word] とページング（[NovelSearchQuery.st]）。
  @override
  Future<NovelSearchResult> searchNovels(NovelSearchQuery query) async {
    final word = query.word?.trim() ?? '';
    final page = query.lim > 0 ? ((query.st - 1) ~/ query.lim) + 1 : 1;
    final uri = Uri.parse('${source.baseUrl}/search/').replace(
      queryParameters: <String, String>{
        'mode': 'search',
        if (word.isNotEmpty) 'word': word,
        if (page > 1) 'page': '$page',
      },
    );
    final html = await _fetch(uri.toString());
    final (novels, hasNext) = parseNovelList(html, page: page);
    // 総件数は取得できないため、次ページがある場合は「まだある」ことを示す
    final loaded = (query.st - 1) + novels.length;
    return NovelSearchResult(
      novels: novels,
      allCount: hasNext ? loaded + 1 : loaded,
    );
  }

  /// ランキングを取得する。
  @override
  Future<RankingPage> fetchRanking(
    String rankingType, {
    int page = 1,
  }) async {
    final type = rankingTypes.where((t) => t.id == rankingType).firstOrNull;
    if (type == null) {
      throw ArgumentError.value(rankingType, 'rankingType', '未対応の種別です');
    }
    final uri = Uri.parse('${source.baseUrl}/').replace(
      queryParameters: <String, String>{
        'mode': type.urlPath,
        if (page > 1) 'page': '$page',
      },
    );
    final html = await _fetch(uri.toString());
    final (novels, hasNext) = parseNovelList(html, page: page);
    return RankingPage(novels: novels, hasNextPage: hasNext);
  }

  // ---------------------------------------------------------------------
  // 解析
  // ---------------------------------------------------------------------

  /// 作品トップのHTMLから [NovelInfo] を組み立てる。
  NovelInfo parseNovelInfo(String html, String workId) {
    final document = html_parser.parse(html);
    _assertNotRemoved(document, workId);
    final episodes = _parseTocDocument(document, workId);
    final isShort = episodes.isEmpty && _honbun(document) != null;
    final count = isShort ? 1 : episodes.length;

    return NovelInfo(
      source: NovelSource.hameln,
      workId: workId,
      title: _parseTitle(document),
      writer: _parseWriter(document),
      story: _metaContent(document, 'og:description') ??
          _metaContent(document, 'description'),
      novelType: isShort ? 2 : 1,
      generalAllNo: count,
    );
  }

  /// 作品トップのHTMLから目次を組み立てる。
  ///
  /// 短編（目次がなく本文を直接含むページ）は1話のみのリストを返す。
  List<Episode> parseToc(String html, String workId) {
    final document = html_parser.parse(html);
    _assertNotRemoved(document, workId);
    final episodes = _parseTocDocument(document, workId);
    if (episodes.isEmpty && _honbun(document) != null) {
      return <Episode>[
        Episode(
          source: NovelSource.hameln,
          index: 1,
          subtitle: _parseTitle(document),
          url: workUrl(workId),
        ),
      ];
    }
    return episodes;
  }

  /// エピソードページ（または短編の作品トップ）から [Episode] を組み立てる。
  ///
  /// 前書き（`#maegaki`）・後書き（`#atogaki`）は含めない。
  /// 本文が見つからない場合（年齢確認ページ等）は [FormatException] を投げる。
  Episode parseEpisode(String html, int index, String episodeUrl) {
    final document = html_parser.parse(html);
    final honbun = _honbun(document);
    if (honbun == null) {
      throw FormatException('本文が見つかりません（年齢確認ページの可能性）: $episodeUrl');
    }
    return Episode(
      source: NovelSource.hameln,
      index: index,
      subtitle: _parseEpisodeSubtitle(document) ?? _parseTitle(document),
      url: episodeUrl,
      body: honbun.innerHtml,
    );
  }

  /// 検索結果・ランキング等の一覧ページから作品と次ページ有無を取得する。
  ///
  /// 作品トップへのリンクを起点に、その作品だけを含む最も外側の要素を
  /// 1件分のブロックとみなして作者名を取得する。
  (List<NovelInfo>, bool) parseNovelList(String html, {int page = 1}) {
    final document = html_parser.parse(html);
    final links = document.querySelectorAll('a[href]');

    final order = <String>[];
    final titles = <String, String>{};
    final anchors = <String, dom.Element>{};
    for (final a in links) {
      final id = _novelIdOf(a.attributes['href']);
      if (id == null) {
        continue;
      }
      final text = a.text.trim();
      if (!titles.containsKey(id)) {
        order.add(id);
        anchors[id] = a;
        titles[id] = '';
      }
      // 最初に見つかった非空のリンクテキストをタイトルとする
      if (titles[id]!.isEmpty && text.isNotEmpty) {
        titles[id] = text;
        anchors[id] = a;
      }
    }

    final novels = <NovelInfo>[
      for (final id in order)
        if (titles[id]!.isNotEmpty)
          NovelInfo(
            source: NovelSource.hameln,
            workId: id,
            title: titles[id],
            writer: _writerNear(anchors[id]!, id),
          ),
    ];

    final nextPage = 'page=${page + 1}';
    final hasNext = links.any(
      (a) => (a.attributes['href'] ?? '').contains(nextPage),
    );
    return (novels, hasNext);
  }

  /// 目次テーブルを解析する。
  ///
  /// 目次はテーブル内のエピソードリンクで構成されるため、
  /// まずテーブル内のリンクを探し、なければページ全体から探す。
  List<Episode> _parseTocDocument(dom.Document document, String workId) {
    var candidates = document.querySelectorAll('table a[href]');
    if (!candidates.any(_isEpisodeLink)) {
      candidates = document.querySelectorAll('a[href]');
    }

    final base = Uri.parse(workUrl(workId));
    final seen = <String>{};
    final episodes = <Episode>[];
    for (final a in candidates.where(_isEpisodeLink)) {
      final href = a.attributes['href']!;
      final url = base.resolve(href).toString();
      // 作品外のエピソードリンク（他作品の最新話等）は除外する
      if (!url.startsWith(base.toString()) || !seen.add(url)) {
        continue;
      }
      final row = _ancestor(a, 'tr');
      final rowText = row?.text ?? '';
      final revisedTitle = row
          ?.querySelectorAll('span[title]')
          .map((s) => s.attributes['title']!)
          .where((t) => t.contains('改稿'))
          .firstOrNull;
      episodes.add(
        Episode(
          source: NovelSource.hameln,
          // 目次順の連番（アプリ内でのエピソード番号）
          index: episodes.length + 1,
          subtitle: a.text.trim(),
          url: url,
          update: _normalizeDate(rowText),
          revised: revisedTitle == null ? null : _normalizeDate(revisedTitle),
        ),
      );
    }
    return episodes;
  }

  bool _isEpisodeLink(dom.Element a) {
    final href = a.attributes['href'];
    return href != null &&
        _episodeLinkPattern.hasMatch(Uri.parse(href).path) &&
        a.text.trim().isNotEmpty;
  }

  /// 作品タイトル。
  String? _parseTitle(dom.Document document) {
    final name = document.querySelector('[itemprop="name"]')?.text.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    final og = _metaContent(document, 'og:title');
    if (og != null) {
      return og;
    }
    final title = document.querySelector('title')?.text.trim();
    // <title> は「作品名 - ハーメルン」形式
    return title?.split(' - ').first.trim();
  }

  /// 作者名。
  String? _parseWriter(dom.Document document) {
    final author = document.querySelector('[itemprop="author"]')?.text.trim();
    if (author != null && author.isNotEmpty) {
      return author;
    }
    return document
        .querySelector('a[href*="/user/"]')
        ?.text
        .trim();
  }

  /// エピソードのサブタイトル。
  ///
  /// 本文ページでは作品名（リンク付き）とサブタイトル（リンクなし）が
  /// 同じ強調スタイルで並ぶため、リンクを含まない最後のものを採用する。
  String? _parseEpisodeSubtitle(dom.Document document) {
    final spans = document
        .querySelectorAll('span[style*="font-size:120%"]')
        .where((s) => s.querySelector('a') == null)
        .map((s) => s.text.trim())
        .where((t) => t.isNotEmpty);
    return spans.lastOrNull;
  }

  /// 一覧のリンク周辺から作者名を探す。
  String? _writerNear(dom.Element anchor, String id) {
    dom.Element? block;
    var current = anchor.parent;
    // その作品だけを含む最も外側の要素まで遡る（最大6階層）
    for (var depth = 0; current != null && depth < 6; depth++) {
      final ids = current
          .querySelectorAll('a[href]')
          .map((a) => _novelIdOf(a.attributes['href']))
          .whereType<String>()
          .toSet();
      if (ids.length > 1 || (ids.isNotEmpty && !ids.contains(id))) {
        break;
      }
      block = current;
      current = current.parent;
    }
    final writer = block?.querySelector('a[href*="/user/"]')?.text.trim();
    return (writer == null || writer.isEmpty) ? null : writer;
  }

  String? _novelIdOf(String? href) {
    if (href == null) {
      return null;
    }
    final path = href.split('?').first.split('#').first;
    return _novelLinkPattern.firstMatch(path)?.group(1);
  }

  dom.Element? _honbun(dom.Document document) =>
      document.querySelector('#honbun');

  String? _metaContent(dom.Document document, String key) {
    final meta =
        document.querySelector('meta[property="$key"]') ??
        document.querySelector('meta[name="$key"]');
    final content = meta?.attributes['content']?.trim();
    return (content == null || content.isEmpty) ? null : content;
  }

  dom.Element? _ancestor(dom.Element element, String tag) {
    var current = element.parent;
    while (current != null && current.localName != tag) {
      current = current.parent;
    }
    return current;
  }

  /// 「2024年1月2日(火) 03:04」を「2024/01/02 03:04」に整形する。
  String? _normalizeDate(String text) {
    final m = _datePattern.firstMatch(text);
    if (m == null) {
      return null;
    }
    String pad(int i) => m.group(i)!.padLeft(2, '0');
    return '${m.group(1)}/${pad(2)}/${pad(3)} ${pad(4)}:${m.group(5)}';
  }

  /// 削除・非公開作品のページでないことを確認する。
  void _assertNotRemoved(dom.Document document, String workId) {
    final hasContent =
        _honbun(document) != null ||
        document.querySelector('[itemprop="name"]') != null ||
        document.querySelectorAll('a[href]').any(_isEpisodeLink);
    if (!hasContent) {
      throw const NovelNotFoundException();
    }
  }

  // ---------------------------------------------------------------------
  // 通信
  // ---------------------------------------------------------------------

  /// 年齢確認Cookieを付与してGETし、HTML文字列を返す。
  Future<String> _fetch(String url) async {
    await _rateLimiter.wait();
    final response = await _dio.get<String>(
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
    final status = response.statusCode ?? -1;
    if (status == 404) {
      throw const NovelNotFoundException();
    }
    if (status != 200) {
      throw SiteHttpException(status, url);
    }
    return response.data ?? '';
  }
}
