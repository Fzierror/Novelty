import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// サイトのボット確認（Cloudflare）を本人が通過するための画面。
///
/// アプリ内ブラウザでページを開き、確認が完了してページが切り替わったら
/// 自動で閉じる。確認済みのCookieはWebView間で共有されるため、
/// 以後のバックグラウンド取得もそのまま通過できる。
///
/// 確認を通過できた場合は `true` を返す。
class SiteVerificationPage extends StatefulWidget {
  /// コンストラクタ。
  const SiteVerificationPage({required this.url, super.key});

  /// 確認対象のURL。
  final String url;

  /// 確認画面を開き、通過できたかどうかを返す。
  static Future<bool> open(BuildContext context, String url) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SiteVerificationPage(url: url),
      ),
    );
    return result ?? false;
  }

  @override
  State<SiteVerificationPage> createState() => _SiteVerificationPageState();
}

class _SiteVerificationPageState extends State<SiteVerificationPage> {
  /// Cloudflareの確認ページのタイトル。
  static const String _challengeTitle = 'Just a moment...';

  bool _closed = false;

  void _close({required bool verified}) {
    if (_closed || !mounted) {
      return;
    }
    _closed = true;
    Navigator.of(context).pop(verified);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ブラウザで確認'),
        actions: [
          TextButton(
            onPressed: () => _close(verified: true),
            child: const Text('完了'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'サイトの確認画面が表示された場合は、画面の指示に従って'
              '確認を完了してください。完了すると自動で戻ります。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              onTitleChanged: (controller, title) {
                // 確認ページ以外のタイトルになったら通過済みとみなす
                // （読み込み前はURLがタイトルになることがあるため除外する）
                final host = Uri.parse(widget.url).host;
                if (title != null &&
                    title.isNotEmpty &&
                    title != _challengeTitle &&
                    !title.contains(host)) {
                  _close(verified: true);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
