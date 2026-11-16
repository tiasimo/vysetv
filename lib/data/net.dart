import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP client for hosts the local network may block. It uses the system resolver first; when
/// that answers with a sinkhole (0.0.0.0, 127.x) or the address can't be reached, it looks the
/// host up over Cloudflare DNS-over-HTTPS and connects to that address instead (TLS still
/// verifies the real hostname). Names that spell out their address (sslip.io and nip.io
/// names) go straight to it before asking anyone.
final http.Client netClient = IOClient(
  HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    ..idleTimeout = const Duration(seconds: 20)
    ..connectionFactory = _connect,
);

/// A fresh client that gets through the same way (for code that closes its clients, like the
/// account server's live connection).
http.Client resilientClient() => IOClient(resilientHttpClient());

HttpClient resilientHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..connectionFactory = _connect;

/// Runs [body] with every HttpClient it makes (WebSockets included) getting through this way.
Future<T> withResilientHttp<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _Resilient());

class _Resilient extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..connectionTimeout = const Duration(seconds: 12)
    ..connectionFactory = _connect;
}

class _Plain extends HttpOverrides {}

final _viaDoh = <String>{}; // hosts whose system answer didn't work this session
final _dohCache = <String, Future<List<InternetAddress>>>{};

/// Names that spell out their own address (1-2-3-4.sslip.io, 1.2.3.4.nip.io): no DNS
/// needed at all, for networks whose DNS won't answer for them.
InternetAddress? _spelledOut(String host) {
  final m = RegExp(r'^(?:.*[.-])?(\d{1,3})[.-](\d{1,3})[.-](\d{1,3})[.-](\d{1,3})\.(?:sslip|nip)\.io$').firstMatch(host);
  return m == null ? null : InternetAddress.tryParse('${m[1]}.${m[2]}.${m[3]}.${m[4]}');
}

Future<ConnectionTask<Socket>> _connect(Uri uri, String? proxyHost, int? proxyPort) async {
  final host = uri.host;
  final secure = uri.scheme == 'https' || uri.scheme == 'wss';
  // WebSockets come through with port 0 when the address doesn't name one
  final port = uri.hasPort && uri.port != 0 ? uri.port : (secure ? 443 : 80);

  Future<Socket> open() async {
    // an address given as numbers (a self-hosted addon on your network), or this machine: just
    // dial it; the sinkhole filter below is only for names a DNS server answered
    final literal = InternetAddress.tryParse(host) ?? (host == 'localhost' ? InternetAddress.loopbackIPv4 : null);
    if (literal != null) return _dial(literal, host, port, secure, const Duration(seconds: 8));
    Object? error;
    final tried = <InternetAddress>{};
    if (!_viaDoh.contains(host)) {
      for (final a in await _system(host)) {
        tried.add(a);
        try {
          return await _dial(a, host, port, secure, const Duration(seconds: 5));
        } catch (e) {
          error = e;
        }
      }
      _viaDoh.add(host);
    }
    final spelled = _spelledOut(host);
    if (spelled != null && tried.add(spelled)) {
      try {
        return await _dial(spelled, host, port, secure, const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
    }
    for (final a in await _doh(host)) {
      if (!tried.add(a)) continue;
      try {
        return await _dial(a, host, port, secure, const Duration(seconds: 8));
      } catch (e) {
        error = e;
      }
    }
    throw error ?? SocketException('Could not reach $host');
  }

  return ConnectionTask.fromSocket(open(), () {});
}

Future<Socket> _dial(InternetAddress a, String host, int port, bool secure, Duration timeout) async {
  final s = await Socket.connect(a, port, timeout: timeout);
  if (!secure) return s;
  try {
    return await SecureSocket.secure(s, host: host).timeout(timeout);
  } catch (_) {
    s.destroy();
    rethrow;
  }
}

bool _sinkhole(InternetAddress a) => a.isLoopback || a.address == '0.0.0.0' || a.address == '::';

Future<List<InternetAddress>> _system(String host) async {
  try {
    final all = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    return [
      ...all.where((a) => a.type == InternetAddressType.IPv4 && !_sinkhole(a)),
      ...all.where((a) => a.type == InternetAddressType.IPv6 && !_sinkhole(a)),
    ];
  } catch (_) {
    return const [];
  }
}

Future<List<InternetAddress>> _doh(String host) => _dohCache[host] ??= () async {
  // a plain client even inside withResilientHttp (it mustn't come back here for its own lookup)
  final plain = HttpOverrides.runWithHttpOverrides(HttpClient.new, _Plain())..connectionTimeout = const Duration(seconds: 6);
  try {
    for (final server in const ['https://cloudflare-dns.com/dns-query', 'https://1.1.1.1/dns-query']) {
      try {
        final rq = await plain.getUrl(Uri.parse('$server?name=${Uri.encodeQueryComponent(host)}&type=A'));
        rq.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        final res = await rq.close().timeout(const Duration(seconds: 6));
        final body = json.decode(await utf8.decodeStream(res)) as Map<String, dynamic>;
        final ips = [
          for (final a in (body['Answer'] as List? ?? const []).cast<Map>())
            if (a['type'] == 1) InternetAddress.tryParse('${a['data']}'),
        ].whereType<InternetAddress>().where((a) => !_sinkhole(a)).toList();
        if (ips.isNotEmpty) return ips;
      } catch (_) {}
    }
    _dohCache.remove(host); // try again next time rather than remembering a failure
    return const <InternetAddress>[];
  } finally {
    plain.close();
  }
}();
