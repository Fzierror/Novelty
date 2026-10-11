import 'package:flutter_test/flutter_test.dart';
import 'package:novelty/sites/site_http.dart';

void main() {
  group('isBotChallenge', () {
    test('cf-mitigated: challenge ヘッダーがあれば確認ページと判定する', () {
      expect(
        isBotChallenge(
          headers: <String, List<String>>{
            'cf-mitigated': <String>['challenge'],
          },
          body: '',
        ),
        true,
      );
    });

    test('Just a moment... のタイトルがあれば確認ページと判定する', () {
      expect(
        isBotChallenge(
          headers: const <String, List<String>>{},
          body: '<html><head><title>Just a moment...</title></head></html>',
        ),
        true,
      );
    });

    test('通常ページは確認ページと判定しない', () {
      expect(
        isBotChallenge(
          headers: const <String, List<String>>{},
          body: '<html><head><title>ハーメルン</title></head></html>',
        ),
        false,
      );
    });
  });
}
