import 'package:novelty/sites/novel_source.dart';
import 'package:novelty/utils/ncode_utils.dart';

/// 作品ページのURLを組み立てる。
///
/// - なろう: `https://ncode.syosetu.com/{ncode}/`
/// - カクヨム: `https://kakuyomu.jp/works/{workId}`
/// - ノクターン／ミッドナイト: `https://novel18.syosetu.com/{ncode}/`
/// - ハーメルン: `https://syosetu.org/novel/{workId}/`
String buildWorkUrl(
  NovelSource source, {
  String? ncode,
  String? workId,
}) {
  switch (source) {
    case NovelSource.narou:
      return '${source.baseUrl}/${ncode?.toNormalizedNcode() ?? ''}/';
    case NovelSource.kakuyomu:
      return '${source.baseUrl}/works/${workId ?? ''}';
    case NovelSource.nocturne:
    case NovelSource.midnight:
      final id = (workId ?? ncode)?.toNormalizedNcode() ?? '';
      return '${source.baseUrl}/$id/';
    case NovelSource.hameln:
      return '${source.baseUrl}/novel/${workId ?? ''}/';
  }
}
