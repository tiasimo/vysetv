// The updater: is there a newer Lorewatch, and if so fetch it, check it, and put it in place.
//
// The app asks its update address (and, failing that, the account server) for a small signed file,
// latest.json, that names the newest version and where each platform's build can be downloaded.
// The name is the user's own, so it can be pointed elsewhere if the server is lost. The downloads
// can sit anywhere (the file lists one or more addresses per platform, tried in order), so they
// can move without a new version of the app. Nothing is believed unless the release key signed
// it (update_signature.dart), and no download is used unless its SHA-256 matches the signed file.
//
// Putting it in place, by platform:
//  * Android: the APK for this device's processor is handed to the system installer;
//  * Windows: the zip is unpacked, the app closes, its files are replaced, and it starts again;
//  * Linux: the AppImage file is swapped for the new one and started again;
//  * macOS: the disk image opens, to drag Lorewatch to Applications;
//  * iPhone / iPad: a sideloaded app can't replace itself, so the download link is opened.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:crypto/crypto.dart' as crypto;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'server_config.dart' show updateListAddresses;
import 'app_settings.dart';
import 'net.dart';
import 'update_signature.dart';

/// One platform's build: where to get it (tried in order) and what it must hash to.
class UpdateFile {
  const UpdateFile({required this.urls, required this.sha256, required this.size});
  final List<String> urls;
  final String sha256;
  final int size;

  static UpdateFile? fromJson(Object? j) {
    if (j is! Map) return null;
    final urls = [
      if (j['url'] is String) j['url'] as String,
      if (j['urls'] is List)
        for (final u in j['urls'] as List)
          if (u is String) u,
    ].where((u) => u.startsWith('https://')).toList();
    final sum = '${j['sha256'] ?? ''}'.toLowerCase();
    if (urls.isEmpty || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sum)) return null;
    return UpdateFile(urls: urls, sha256: sum, size: (j['size'] as num?)?.toInt() ?? 0);
  }
}

/// What the signed file says.
class UpdateInfo {
  const UpdateInfo({required this.version, required this.notes, required this.date, required this.files, required this.page});
  final String version;
  final String notes;
  final String date;
  final Map<String, UpdateFile> files;

  /// A page about the release, to open when this platform has no build in the list.
  final String? page;

  static UpdateInfo fromJson(Map<String, dynamic> j) {
    final version = '${j['version'] ?? ''}'.trim();
    if (!RegExp(r'^\d+(\.\d+){0,3}').hasMatch(version)) throw const FormatException('no version');
    final page = j['page'] is String && (j['page'] as String).startsWith('https://') ? j['page'] as String : null;
    return UpdateInfo(
      version: version,
      notes: '${j['notes'] ?? ''}'.trim(),
      date: '${j['date'] ?? ''}'.trim(),
      page: page,
      files: {
        if (j['files'] is Map)
          for (final e in (j['files'] as Map).entries) '${e.key}': ?UpdateFile.fromJson(e.value),
      },
    );
  }
}

enum UpdateStage {
  /// Nothing asked yet.
  idle,
  checking,
  upToDate,

  /// A newer version exists ([Updater.info]).
  available,
  downloading,
  verifying,

  /// Fetched and checked; the platform's own step is next or under way.
  installing,

  /// The system has taken over (Android's installer, the Mac's disk image): the rest is yours.
  handedOver,
  failed,
}

class Updater extends ChangeNotifier {
  Updater._();
  static final instance = Updater._();

  /// Where the signed file is asked for, in order. Its signature sits next to it, at the same
  /// address plus ".sig".
  /// The addresses are this build's own (server_config.dart). None is trusted for being asked:
  /// only the release key's signature counts.
  static const manifestUrls = updateListAddresses;

  static const _channel = MethodChannel('vyse/update');

  /// This copy's version ("1.0.0"); empty until [initialize].
  String current = '';
  UpdateStage stage = UpdateStage.idle;
  UpdateInfo? info;

  /// 0 to 1 while downloading (null: the size isn't known).
  double? progress;
  int received = 0;

  /// In words, when [stage] is failed.
  String? error;
  DateTime? checkedAt;

  String? _platform;
  bool _cancel = false;
  HttpClient? _client;
  Timer? _timer;
  Future<UpdateInfo?>? _checking;

  bool get busy => stage == UpdateStage.checking || stage == UpdateStage.downloading || stage == UpdateStage.verifying || stage == UpdateStage.installing;

  /// The newer version, when there is one for this copy to move to.
  UpdateInfo? get newer => info != null && current.isNotEmpty && compareVersions(info!.version, current) > 0 ? info : null;

  /// This device's build in the list, if it has one.
  UpdateFile? get file => _setupFile ?? info?.files[_platform];

  /// The list's name for the Windows installer (the plain `windows-x64` entry is a zip of the
  /// program's folder).
  static const _setupKey = 'windows-x64-setup';

  /// Whether this copy was put here by the installer: its uninstaller sits next to the program.
  /// Such a copy updates through the next installer, so Windows' list of installed apps keeps
  /// the right version; a copy unzipped by hand has its files swapped instead.
  static final bool _installed = Platform.isWindows && File('${File(Platform.resolvedExecutable).parent.path}\\unins000.exe').existsSync();

  UpdateFile? get _setupFile => _installed ? info?.files[_setupKey] : null;

  /// What pressing Update does here, in a few words.
  String get how {
    if (file == null) return 'Opens the download page';
    if (Platform.isAndroid) return 'Downloads it, then Android asks to install';
    if (Platform.isWindows) return 'Downloads it, then Lorewatch restarts';
    if (Platform.isLinux) return _appImage == null ? 'Opens the download' : 'Downloads it, then Lorewatch restarts';
    if (Platform.isMacOS) return 'Downloads it and opens the disk image';
    return 'Opens the download';
  }

  static String? get _appImage {
    final p = Platform.environment['APPIMAGE'];
    return p == null || p.isEmpty ? null : p;
  }

  Future<void> initialize() async {
    if (current.isNotEmpty) return;
    try {
      current = (await PackageInfo.fromPlatform()).version;
    } catch (_) {}
    _platform = await _platformKey();
    notifyListeners();
    // quietly, a little after start-up and then a few times a day while Lorewatch stays open
    if (AppSettings.updateAuto.value) {
      Timer(const Duration(seconds: 6), () => unawaited(check()));
    }
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) {
      if (AppSettings.updateAuto.value && !busy) unawaited(check());
    });
    unawaited(_tidy());
  }

  static Future<String> _platformKey() async {
    if (Platform.isAndroid) {
      try {
        final abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
        for (final abi in abis) {
          if (const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains(abi)) return 'android-$abi';
        }
      } catch (_) {}
      return 'android-arm64-v8a';
    }
    if (Platform.isWindows) return 'windows-x64';
    if (Platform.isLinux) return Abi.current() == Abi.linuxArm64 ? 'linux-arm64' : 'linux-x64';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  Future<Directory> _folder() async {
    final d = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates');
    await d.create(recursive: true);
    return d;
  }

  /// Old downloads of updates that were installed, or given up on.
  Future<void> _tidy() async {
    try {
      final d = await _folder();
      await for (final f in d.list()) {
        final age = DateTime.now().difference((await f.stat()).modified);
        if (age > const Duration(days: 2)) await f.delete(recursive: true);
      }
    } catch (_) {}
  }

  // ── asking ──

  /// Asks whether there's a newer version. Answers it when there is one, null when this copy is
  /// current or the question couldn't be settled ([stage] and [error] say which). Several calls
  /// at once share one request.
  Future<UpdateInfo?> check() => _checking ??= _check().whenComplete(() => _checking = null);

  Future<UpdateInfo?> _check() async {
    if (busy && stage != UpdateStage.checking) return newer;
    if (current.isEmpty) await initialize();
    stage = UpdateStage.checking;
    error = null;
    notifyListeners();
    try {
      // (the minute in the address keeps a cache in between from answering with an old file)
      final stamp = DateTime.now().millisecondsSinceEpoch ~/ 60000;
      // each place in turn; one that doesn't answer, or answers with something the release key
      // didn't sign, is passed over for the next
      UpdateInfo? found;
      Object? last;
      for (final url in manifestUrls) {
        try {
          final got = await Future.wait([
            netClient.get(Uri.parse('$url?t=$stamp'), headers: const {'Cache-Control': 'no-cache'}),
            netClient.get(Uri.parse('$url.sig?t=$stamp'), headers: const {'Cache-Control': 'no-cache'}),
          ]).timeout(const Duration(seconds: 12));
          if (got[0].statusCode != 200 || got[1].statusCode != 200) throw const HttpException('not there');
          final Uint8List signature;
          try {
            signature = base64.decode(got[1].body.replaceAll(RegExp(r'\s'), ''));
          } catch (_) {
            throw const _Untrusted();
          }
          if (!updateSignatureIsValid(got[0].bodyBytes, signature)) throw const _Untrusted();
          found = UpdateInfo.fromJson(json.decode(utf8.decode(got[0].bodyBytes)) as Map<String, dynamic>);
          break;
        } catch (e) {
          // what's remembered is the most telling failure: a file that failed the check, over
          // one that couldn't be read, over a place that didn't answer
          if (e is _Untrusted || (e is FormatException && last is! _Untrusted) || last == null) last = e;
        }
      }
      if (found == null) throw last ?? const HttpException('not there');
      info = found;
      checkedAt = DateTime.now();
      stage = newer != null ? UpdateStage.available : UpdateStage.upToDate;
    } on _Untrusted {
      stage = UpdateStage.failed;
      error = "Non è stato possibile verificare le informazioni sull'aggiornamento, quindi sono state ignorate.";
    } on FormatException {
      stage = UpdateStage.failed;
      error = "Impossibile leggere le informazioni sull'aggiornamento.";
    } catch (_) {
      stage = UpdateStage.failed;
      error = "Impossibile controllare gli aggiornamenti. Controlla la connessione e riprova.";
    }
    notifyListeners();
    return newer;
  }

  /// "Not this one": the automatic check stops offering [version].
  void skip(String version) => AppSettings.updateSkipped.set(version);

  /// The update box has been up since Lorewatch started (by itself, or from Settings). It comes up
  /// by itself once per start at most: after "Later" it waits for the next start.
  bool shownThisRun = false;

  /// Whether the automatic check should bring [u] up by itself.
  bool shouldOffer(UpdateInfo u) => !shownThisRun && AppSettings.updateAuto.value && AppSettings.updateSkipped.value != u.version;

  // ── getting it ──

  void cancel() {
    if (stage != UpdateStage.downloading) return;
    _cancel = true;
    try {
      _client?.close(force: true);
    } catch (_) {}
  }

  /// Fetches the newer version, checks it, and puts it in place the way this platform allows.
  /// Where there's nothing to fetch for this platform, the download page is opened instead.
  Future<void> update() async {
    final u = newer;
    if (u == null || busy) return;
    final f = file;
    final external = f == null || Platform.isIOS || (Platform.isLinux && _appImage == null);
    if (external) {
      final link = f?.urls.first ?? u.page;
      final ok = link != null && await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication).catchError((Object _) => false);
      stage = ok ? UpdateStage.handedOver : UpdateStage.failed;
      error = ok ? null : "There's no download for this device in this release yet.";
      notifyListeners();
      return;
    }
    _cancel = false;
    error = null;
    try {
      final got = await _download(u, f);
      if (got == null) {
        stage = UpdateStage.available; // called off
        notifyListeners();
        return;
      }
      stage = UpdateStage.installing;
      notifyListeners();
      await _install(got, u);
    } on _Failed catch (e) {
      stage = UpdateStage.failed;
      error = e.message;
      notifyListeners();
    } catch (_) {
      stage = UpdateStage.failed;
      error = "Impossibile installare l'aggiornamento. Riprova.";
      notifyListeners();
    }
  }

  String _name(UpdateInfo u, String url) {
    final ext = Platform.isAndroid ? 'apk' : (Platform.isWindows ? (_setupFile != null ? 'exe' : 'zip') : (Platform.isMacOS ? 'dmg' : (Platform.isLinux ? 'AppImage' : (RegExp(r'\.([A-Za-z0-9]{2,8})$').firstMatch(Uri.parse(url).path)?[1] ?? 'bin'))));
    return 'Lorewatch-${u.version.replaceAll(RegExp(r'[^0-9A-Za-z.]'), '_')}.$ext';
  }

  /// The checked file, or null when it was called off. Each address is tried in turn; one that
  /// answers with the wrong bytes is as good as one that doesn't answer.
  Future<File?> _download(UpdateInfo u, UpdateFile f) async {
    final dir = await _folder();
    final file = File('${dir.path}${Platform.pathSeparator}${_name(u, f.urls.first)}');
    if (await file.exists() && await _hash(file) == f.sha256) return file; // fetched before
    final part = File('${file.path}.part');
    Object? last;
    for (final url in f.urls) {
      stage = UpdateStage.downloading;
      progress = f.size > 0 ? 0 : null;
      received = 0;
      notifyListeners();
      final client = _client = resilientHttpClient()..connectionTimeout = const Duration(seconds: 20);
      try {
        final rq = await client.getUrl(Uri.parse(url));
        rq.headers.removeAll(HttpHeaders.acceptEncodingHeader);
        final res = await rq.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) {
          await res.drain<void>().catchError((Object _) {});
          throw HttpException('HTTP ${res.statusCode}');
        }
        final total = f.size > 0 ? f.size : res.contentLength;
        final out = _DigestSink();
        final hasher = crypto.sha256.startChunkedConversion(out);
        final sink = part.openWrite();
        var shown = DateTime.now();
        try {
          await for (final chunk in res.timeout(const Duration(seconds: 60))) {
            if (_cancel) break;
            sink.add(chunk);
            hasher.add(chunk);
            received += chunk.length;
            if (DateTime.now().difference(shown) > const Duration(milliseconds: 150)) {
              shown = DateTime.now();
              progress = total > 0 ? (received / total).clamp(0, 1) : null;
              notifyListeners();
            }
          }
        } finally {
          await sink.flush().catchError((Object _) {});
          await sink.close().catchError((Object _) {});
        }
        if (_cancel) {
          await part.delete().catchError((Object _) => part);
          return null;
        }
        hasher.close();
        stage = UpdateStage.verifying;
        progress = 1;
        notifyListeners();
        if (out.value?.toString() != f.sha256 || (f.size > 0 && received != f.size)) {
          await part.delete().catchError((Object _) => part);
          throw const _Failed("The download didn't match the release, so it wasn't used.");
        }
        if (await file.exists()) await file.delete();
        await part.rename(file.path);
        return file;
      } catch (e) {
        if (_cancel) {
          await part.delete().catchError((Object _) => part);
          return null;
        }
        last = e;
      } finally {
        client.close(force: true);
        _client = null;
      }
    }
    if (last is _Failed) throw last;
    if (last is FileSystemException) throw const _Failed("There's no room to download the update, or the folder can't be written to.");
    throw const _Failed("Couldn't download the update. Check your connection and try again.");
  }

  static Future<String> _hash(File f) async => (await crypto.sha256.bind(f.openRead()).first).toString();

  // ── putting it in place ──

  Future<void> _install(File f, UpdateInfo u) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod<bool>('install', {'path': f.path});
      } on PlatformException catch (e) {
        throw _Failed(e.message ?? "Android couldn't open the installer.");
      }
      stage = UpdateStage.handedOver;
      notifyListeners();
      return;
    }
    if (Platform.isMacOS) {
      final ok = await launchUrl(Uri.file(f.path)).catchError((Object _) => false);
      if (!ok) throw const _Failed("The disk image couldn't be opened. It's in your temporary folder.");
      stage = UpdateStage.handedOver;
      notifyListeners();
      return;
    }
    if (Platform.isLinux) return _installAppImage(f);
    if (Platform.isWindows) return _setupFile != null ? _installWithSetup(f) : _installWindows(f, u);
    throw const _Failed("This device can't install the update by itself.");
  }

  /// The installer does the work: it shows its progress, closes Lorewatch if it is still open,
  /// replaces the files and (asked to with relaunch=1) starts Lorewatch again.
  Future<void> _installWithSetup(File setup) async {
    try {
      await Process.start(setup.path, const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/relaunch=1'], mode: ProcessStartMode.detached);
    } catch (_) {
      throw const _Failed("The installer couldn't be started. Try again.");
    }
    await _quit();
  }

  /// The running AppImage is one file: the new one takes its name (the running copy keeps
  /// working from the old file until it closes), then starts.
  Future<void> _installAppImage(File f) async {
    final target = _appImage;
    if (target == null) throw const _Failed("Lorewatch wasn't started from an AppImage, so it can't replace itself.");
    final staged = File('$target.new');
    try {
      await f.copy(staged.path);
      final chmod = await Process.run('chmod', ['755', staged.path]);
      if (chmod.exitCode != 0) throw const FileSystemException('chmod');
      await staged.rename(target);
    } catch (_) {
      await staged.delete().catchError((Object _) => staged);
      throw const _Failed("The AppImage's folder can't be written to. Download the new one and replace it by hand.");
    }
    await f.delete().catchError((Object _) => f);
    // the new copy starts clear of this one's own library paths
    final env = Map<String, String>.from(Platform.environment)
      ..remove('LD_LIBRARY_PATH')
      ..remove('APPDIR')
      ..remove('APPIMAGE')
      ..remove('ARGV0')
      ..remove('OWD')
      ..remove('GST_PLUGIN_SYSTEM_PATH_1_0')
      ..remove('GST_PLUGIN_SCANNER_1_0')
      ..remove('GST_REGISTRY_1_0');
    await Process.start(target, const [], mode: ProcessStartMode.detached, environment: env, includeParentEnvironment: false);
    await _quit();
  }

  /// The zip is unpacked next to the download; a small script then waits for Lorewatch to close,
  /// copies the new files over the old ones, starts Lorewatch and cleans up after itself.
  Future<void> _installWindows(File zip, UpdateInfo u) async {
    final exe = File(Platform.resolvedExecutable);
    final appDir = exe.parent;
    // can the app's own folder be written to? (not under Program Files without asking)
    try {
      final probe = File('${appDir.path}\\.vyse-update-test');
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      throw const _Failed("Lorewatch's folder can't be written to from here. Unzip the new version over it by hand.");
    }
    final unpack = Directory('${zip.parent.path}\\unpacked-${u.version}');
    if (await unpack.exists()) await unpack.delete(recursive: true);
    await unpack.create(recursive: true);
    // Windows 10 and later carry tar, which reads zips; PowerShell is the slower way round
    var done = false;
    try {
      done = (await Process.run('tar', ['-xf', zip.path, '-C', unpack.path])).exitCode == 0;
    } catch (_) {}
    if (!done) {
      try {
        final r = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Expand-Archive -LiteralPath '${zip.path.replaceAll("'", "''")}' -DestinationPath '${unpack.path.replaceAll("'", "''")}' -Force",
        ]);
        done = r.exitCode == 0;
      } catch (_) {}
    }
    if (!done) throw const _Failed("The update couldn't be unpacked.");
    // the folder that holds the program, wherever the zip put it
    Directory? fresh;
    await for (final e in unpack.list(recursive: true)) {
      if (e is File && e.path.toLowerCase().endsWith('\\${exe.uri.pathSegments.last.toLowerCase()}')) {
        fresh = e.parent;
        break;
      }
    }
    if (fresh == null) throw const _Failed("The update doesn't look like Lorewatch, so it wasn't used.");
    final script = File('${zip.parent.path}\\vyse-update.cmd');
    await script.writeAsString(
      [
        '@echo off',
        'setlocal',
        'set "PID=$pid"',
        'set "SRC=${fresh.path}"',
        'set "DST=${appDir.path}"',
        'set "EXE=${exe.uri.pathSegments.last}"',
        // Windows' own tools by their full path, whatever PATH says (a `find` from elsewhere
        // would make the wait below end at once, with Lorewatch's files still in use)
        r'set "SYS=%SystemRoot%\System32"',
        'set /a TRIES=0',
        ':wait',
        r'"%SYS%\tasklist.exe" /FI "PID eq %PID%" 2>nul | "%SYS%\find.exe" "%PID%" >nul',
        'if not errorlevel 1 (',
        '  set /a TRIES+=1',
        r'  if %TRIES% GEQ 60 "%SYS%\taskkill.exe" /PID %PID% /F >nul 2>&1',
        r'  "%SYS%\ping.exe" -n 2 127.0.0.1 >nul',
        '  goto wait',
        ')',
        r'"%SYS%\robocopy.exe" "%SRC%" "%DST%" /E /R:8 /W:1 /NFL /NDL /NJH /NJS /NP >nul',
        r'start "" "%DST%\%EXE%"',
        'rmdir /s /q "${unpack.path}" >nul 2>&1',
        'del "${zip.path}" >nul 2>&1',
        '(goto) 2>nul & del "%~f0"',
        '',
      ].join('\r\n'),
    );
    await Process.start('cmd.exe', ['/c', script.path], mode: ProcessStartMode.detached, runInShell: false);
    await _quit();
  }

  /// Closes Lorewatch the way its window's close button does, so everything it runs shuts down.
  Future<void> _quit() async {
    try {
      await ServicesBinding.instance.exitApplication(AppExitType.required).timeout(const Duration(seconds: 4));
    } catch (_) {}
    exit(0);
  }
}

/// Keeps the one hash a finished download comes to.
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

class _Untrusted implements Exception {
  const _Untrusted();
}

class _Failed implements Exception {
  const _Failed(this.message);
  final String message;
}
