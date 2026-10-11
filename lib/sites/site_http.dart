/// 公式APIを持たない（またはHTML取得が必要な）サイト実装で共有する
/// HTTP関連のユーティリティ。
library;

/// サイトへのリクエスト間隔を制御するレートリミッター。
///
/// サーバー負荷軽減のため、連続リクエスト間に最低限の間隔を設ける。
/// 壁時計（DateTime）ではなくモノトニッククロック（Stopwatch）を
/// 使用することで、システム時刻の変更の影響を受けない。
class SiteRateLimiter {
  /// コンストラクタ。
  SiteRateLimiter({
    this.interval = const Duration(seconds: 1),
  });

  /// リクエスト間隔。
  final Duration interval;

  final Stopwatch _stopwatch = Stopwatch();

  /// 直前のリクエストから [interval] 以上経過するまで待機する。
  Future<void> wait() async {
    if (_stopwatch.isRunning) {
      final elapsed = _stopwatch.elapsed;
      if (elapsed < interval) {
        await Future<void>.delayed(interval - elapsed);
      }
      _stopwatch
        ..reset()
        ..start();
    } else {
      _stopwatch.start();
    }
  }
}

/// サイトからのHTTP取得に失敗した場合の例外。
class SiteHttpException implements Exception {
  /// コンストラクタ。
  const SiteHttpException(this.statusCode, this.url);

  /// HTTPステータスコード。
  final int statusCode;

  /// リクエストURL。
  final String url;

  @override
  String toString() => 'HTTP $statusCode エラー: $url';
}

/// Cloudflare等のボット確認ページが返され、本文を取得できなかった場合の例外。
class BotChallengeException implements Exception {
  /// コンストラクタ。
  const BotChallengeException(this.statusCode, this.url);

  /// HTTPステータスコード。
  final int statusCode;

  /// リクエストURL。
  final String url;

  @override
  String toString() =>
      'サイトのボット確認（Cloudflare）でブロックされました '
      '(HTTP $statusCode): $url';
}

/// レスポンスがCloudflareのボット確認ページかどうかを判定する。
///
/// `cf-mitigated: challenge` ヘッダー、または確認ページ特有の
/// タイトルが含まれるかで判定する。
bool isBotChallenge({
  required Map<String, List<String>> headers,
  required String body,
}) {
  final mitigated = headers['cf-mitigated']?.join(',') ?? '';
  if (mitigated.contains('challenge')) {
    return true;
  }
  // 通常ページにもCloudflareのスクリプトは含まれ得るため、
  // 確認ページ固有のタイトルのみで判定する
  return body.contains('<title>Just a moment...</title>');
}

/// ブラウザ相当のUser-Agent。
///
/// ハーメルン等は一般的でないUser-Agentを拒否することがあるため、
/// カクヨム実装と同じブラウザ相当の値を使用する。
const String browserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36';
