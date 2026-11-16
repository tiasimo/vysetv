import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tracker_keys.dart';

/// Signing in on a computer: the browser comes back to `http://127.0.0.1:port/path` and this
/// tiny local server picks up the answer. Only this computer can reach it, it answers once and
/// then closes.
class LoopbackAuth {
  static HttpServer? _server;
  static Completer<Map<String, String>>? _waiting;

  static String redirectFor(String path) => 'http://127.0.0.1:${TrackerKeys.loopbackPort}/$path';

  /// Waits for the browser to arrive at [path]. With [fragment], the answer is in the part after
  /// "#" (AniList's token), which browsers never send to a server, so a small page reads it and
  /// sends it back. [openBrowser] runs once the server is listening.
  static Future<Map<String, String>> start(
    String path, {
    required bool fragment,
    required Future<void> Function() openBrowser,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    cancel();
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, TrackerKeys.loopbackPort);
    } on SocketException {
      throw const LoopbackException("Couldn't open the sign-in window. Close other Lorewatch windows and try again.");
    }
    _server = server;
    final done = _waiting = Completer<Map<String, String>>();
    server.listen((req) async {
      try {
        final p = req.uri.path;
        if (p == '/$path/done' || (p == '/$path' && !fragment) || req.uri.queryParameters.containsKey('error')) {
          final q = req.uri.queryParameters;
          final error = q['error'];
          await _page(req, error == null ? 'Signed in. You can close this tab and go back to Lorewatch.' : "Sign-in didn't finish. You can close this tab.");
          if (!done.isCompleted) {
            error == null ? done.complete(q) : done.completeError(LoopbackException(q['error_description'] ?? error));
          }
        } else if (p == '/$path') {
          await _forwardFragment(req, '/$path/done');
        } else {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      } catch (_) {}
    });
    try {
      await openBrowser();
      return await done.future.timeout(timeout, onTimeout: () => throw const LoopbackException('Sign-in timed out. Try again.'));
    } finally {
      _close(server);
    }
  }

  /// Stops waiting (the dialog was closed).
  static void cancel() {
    final w = _waiting;
    if (w != null && !w.isCompleted) w.completeError(const LoopbackException('cancelled'));
    final s = _server;
    if (s != null) _close(s);
  }

  static void _close(HttpServer s) {
    if (_server == s) _server = null;
    s.close(force: true).catchError((Object _) {});
  }

  static Future<void> _page(HttpRequest req, String message) async {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_html(message));
    await req.response.close();
  }

  static Future<void> _forwardFragment(HttpRequest req, String to) async {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_html(
        'Finishing sign-in…',
        script: 'var h=location.hash.substring(1);'
            'fetch("$to?"+h).then(function(){document.getElementById("m").textContent='
            '"Signed in. You can close this tab and go back to Lorewatch.";});',
      ));
    await req.response.close();
  }

  static String _html(String message, {String script = ''}) =>
      '<!doctype html><html><head><meta charset="utf-8"><title>Lorewatch</title>'
      '<meta name="viewport" content="width=device-width,initial-scale=1"></head>'
      '<body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;'
      'background:#07080d;color:#e9e9ef;font:16px system-ui,sans-serif">'
      '<p id="m">${const HtmlEscape().convert(message)}</p>'
      '${script.isEmpty ? '' : '<script>$script</script>'}</body></html>';
}

class LoopbackException implements Exception {
  const LoopbackException(this.message);
  final String message;
  bool get cancelled => message == 'cancelled';
  @override
  String toString() => message;
}
