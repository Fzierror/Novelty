import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:novelty/sites/site_http.dart';

/// URLからHTML文字列を取得する抽象インターフェース。
///
/// 通常のHTTPクライアントでは取得できないサイト（ボット確認があるサイト）向けに、
/// 実ブラウザエンジン（WebView）での取得へ差し替えられるようにする。
// ignore: one_member_abstracts, reason: テストとWebViewで実装を差し替えるため
abstract class HtmlFetcher {
  /// [url] のページを読み込み、描画後のHTMLを返す。
  Future<String> fetch(String url);
}

/// 画面に表示しないWebView（実ブラウザエンジン）でページを取得する実装。
///
/// Cloudflareのボット確認はブラウザ上のJavaScriptで判定されるため、
/// 通常のHTTP通信では通過できない。WebViewはChromeと同じエンジンで
/// ページを表示するため、確認が自動で完了する場合はそのまま本文を取得できる。
///
/// 自動で完了しない場合（操作が必要な確認）は [BotChallengeException] を投げ、
/// 呼び出し側で確認用の画面（SiteVerificationPage）を表示して本人に通過してもらう。
/// 確認済みのCookieはWebView間で共有されるため、以後は自動取得できる。
class WebViewHtmlFetcher implements HtmlFetcher {
  /// コンストラクタ。
  const WebViewHtmlFetcher({
    this.cookies = const <String, String>{},
    this.timeout = const Duration(seconds: 25),
  });

  /// 読み込み前に設定するCookie（名前→値）。
  final Map<String, String> cookies;

  /// 確認ページが解除されるのを待つ最大時間。
  final Duration timeout;

  @override
  Future<String> fetch(String url) async {
    await _applyCookies(url);

    final completer = Completer<String>();
    InAppWebViewController? controller;

    Future<void> check() async {
      final c = controller;
      if (c == null || completer.isCompleted) {
        return;
      }
      final result = await c.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      if (result is! String || result.isEmpty) {
        return;
      }
      // 確認ページの間は待つ（通過するとページが切り替わる）
      const noHeaders = <String, List<String>>{};
      if (isBotChallenge(headers: noHeaders, body: result)) {
        return;
      }
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    final webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      onWebViewCreated: (c) => controller = c,
      onLoadStop: (c, _) async {
        controller = c;
        await check();
      },
      onReceivedError: (c, request, error) {
        // メインフレームの読み込み失敗のみ扱う（広告等のサブリソースは無視）
        if ((request.isForMainFrame ?? false) && !completer.isCompleted) {
          completer.completeError(
            SiteHttpException(-1, '$url (${error.description})'),
          );
        }
      },
    );

    // 読み込み完了イベントなしで確認が解除される場合に備えて定期的に確認する
    final poll = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(check());
    });
    try {
      await webView.run();
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw BotChallengeException(403, url),
      );
    } finally {
      poll.cancel();
      await webView.dispose();
    }
  }

  Future<void> _applyCookies(String url) async {
    if (cookies.isEmpty) {
      return;
    }
    final uri = Uri.parse(url);
    final origin = WebUri('${uri.scheme}://${uri.host}/');
    final manager = CookieManager.instance();
    for (final entry in cookies.entries) {
      await manager.setCookie(
        url: origin,
        name: entry.key,
        value: entry.value,
        path: '/',
      );
    }
  }
}
