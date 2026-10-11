import 'package:flutter_test/flutter_test.dart';
import 'package:novelty/sites/hameln/hameln_site.dart';
import 'package:novelty/sites/kakuyomu/kakuyomu_site.dart';
import 'package:novelty/sites/narou/narou_site.dart';
import 'package:novelty/sites/novel_site_registry.dart';
import 'package:novelty/sites/novel_source.dart';
import 'package:novelty/sites/syosetu18/syosetu18_site.dart';

void main() {
  group('novelSiteRegistry', () {
    test('narou が登録されており実装は NarouSite', () {
      expect(defaultNovelSiteRegistry.keys, contains(NovelSource.narou));
      expect(defaultNovelSiteRegistry[NovelSource.narou], isA<NarouSite>());
    });

    test('kakuyomu が登録されており実装は KakuyomuSite', () {
      expect(defaultNovelSiteRegistry.keys, contains(NovelSource.kakuyomu));
      expect(
        defaultNovelSiteRegistry[NovelSource.kakuyomu],
        isA<KakuyomuSite>(),
      );
    });

    test('nocturne / midnight は Syosetu18Site（nocgenre 1 / 4）', () {
      final nocturne = defaultNovelSiteRegistry[NovelSource.nocturne];
      final midnight = defaultNovelSiteRegistry[NovelSource.midnight];
      expect(nocturne, isA<Syosetu18Site>());
      expect(midnight, isA<Syosetu18Site>());
      expect((nocturne! as Syosetu18Site).nocgenre, 1);
      expect((midnight! as Syosetu18Site).nocgenre, 4);
    });

    test('hameln が登録されており実装は HamelnSite', () {
      expect(
        defaultNovelSiteRegistry[NovelSource.hameln],
        isA<HamelnSite>(),
      );
    });

    test('すべてのサイト種別が登録されている', () {
      expect(
        defaultNovelSiteRegistry.keys,
        containsAll(NovelSource.values),
      );
    });

    test('全サイトにランキング種別が1つ以上ある（探索画面のタブ用）', () {
      for (final site in defaultNovelSiteRegistry.values) {
        expect(site.rankingTypes, isNotEmpty, reason: site.source.label);
      }
    });

    test('登録済みエントリのキーと実装の source が一致する', () {
      for (final entry in defaultNovelSiteRegistry.entries) {
        expect(entry.value.source, entry.key);
      }
    });
  });
}
