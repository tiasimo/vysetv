#!/usr/bin/env python3
"""Writes and signs the file VyseTV's updater reads, and can put it on the account server.

The updater in every installed copy asks the addresses its build was given
(updateListAddresses in lib/data/server_config.dart) for latest.json, in order. It
names the newest version and, per platform, where to download it and what it must hash to. The
app only believes it when it is signed with the release key, which lives on this PC only:

    C:\\Users\\<you>\\.vyse\\update-signing-key.pem      (keep a copy somewhere safe; never share it)

Lose the key and installed copies can no longer be told about updates: they would have to be
replaced by hand once, with a build that carries a new key.

A release, start to finish:

  1. Build each platform and upload the files where people can download them (anywhere that
     gives a direct https link: a public GitHub release, your own storage...).
  2. Run this with the version, what changed, and for each platform the file you built and the
     link(s) it can be downloaded from. The file is only read to measure and hash it:

       python scripts/make_update.py 1.0.1 --notes "Downloads, and an updater." ^
         --file android-arm64-v8a build/app/outputs/flutter-apk/app-arm64-v8a-release.apk https://.../VyseTV-arm64.apk ^
         --file windows-x64 dist/VyseTV-Windows.zip https://.../VyseTV-Windows.zip ^
         --file linux-x64 VyseTV-x86_64.AppImage https://.../VyseTV-x86_64.AppImage ^
         --publish

     Give more than one link after a file to list mirrors; the app tries them in order.
  3. --publish copies latest.json and latest.json.sig to the server. Without it they are left
     in build/update/ to look at first.

Platforms the app knows: android-arm64-v8a, android-armeabi-v7a, android-x86_64, windows-x64,
windows-x64-setup, linux-x64, linux-arm64, macos, ios. A platform left out keeps working; its
users are sent to --page (a web page about the release) when you give one.

Windows has two entries, and a release should list both: windows-x64-setup is the installer
(VyseTV-Setup.exe), used by copies that were installed with it; windows-x64 is the zip of the
program's folder, used by copies someone unzipped by hand. scripts/make_release.py makes both
and prints this command with the files filled in.

If the server is ever lost: put latest.json and latest.json.sig (from build/update/) on any host
that serves them over https at the top level, and point the update address's DNS record at it.
Installed copies follow on their next check.

Where --publish sends the two files is not in this repository. It is read from
~/.vyse/release-server.json on the PC that makes the releases:

    {"ssh": "user@your.server", "ssh_key": "~/.ssh/your_key",
     "remote_dir": "/path/served/over/https", "public_url": "https://your.name/latest.json"}

Windows expects the installer and a .zip of the app folder, Linux the .AppImage, macOS the .dmg,
Android the APK for that processor. Android only installs an update signed with the same key as the copy it
replaces, so build every Android release on the same machine (or with the same keystore).
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import subprocess
import sys

PLATFORMS = ['android-arm64-v8a', 'android-armeabi-v7a', 'android-x86_64', 'windows-x64', 'windows-x64-setup', 'linux-x64', 'linux-arm64', 'macos', 'ios']
KEY = os.path.join(os.path.expanduser('~'), '.vyse', 'update-signing-key.pem')
SERVER_FILE = os.path.join(os.path.expanduser('~'), '.vyse', 'release-server.json')


def release_server():
    """Where --publish puts the files: read from this PC, never kept in the repository."""
    try:
        with open(SERVER_FILE, encoding='utf-8-sig') as f:
            s = json.load(f)
        return s['ssh'], os.path.expanduser(s['ssh_key']), s['remote_dir'].rstrip('/'), s['public_url']
    except (OSError, ValueError, KeyError) as e:
        sys.exit(f'--publish needs {SERVER_FILE} (see the top of this file): {e}')


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description='Write, sign and optionally publish VyseTV update information.', epilog='See the top of this file for a full example.')
    ap.add_argument('version', help='the new version, e.g. 1.0.1 (must match pubspec.yaml of the builds)')
    ap.add_argument('--notes', default='', help="what changed, shown in the app's update box")
    ap.add_argument('--notes-file', help='read the notes from a text file instead')
    ap.add_argument('--page', help='a web page about the release, for platforms without a file')
    ap.add_argument('--file', nargs='+', action='append', default=[], metavar=('PLATFORM', 'PATH URL'), help='a platform, the built file, and one or more https links to it')
    ap.add_argument('--key', default=KEY, help='the release signing key (default: %(default)s)')
    ap.add_argument('--out', default=os.path.join('build', 'update'), help='where to write the two files (default: %(default)s)')
    ap.add_argument('--publish', action='store_true', help='copy them to the account server')
    a = ap.parse_args()

    if not all(p.isdigit() for p in a.version.split('.')) or not 1 <= len(a.version.split('.')) <= 4:
        sys.exit(f'"{a.version}" is not a version like 1.0.1')
    if not os.path.isfile(a.key):
        sys.exit(f'The release key is not at {a.key}')
    notes = a.notes
    if a.notes_file:
        notes = open(a.notes_file, encoding='utf-8').read().strip()

    files = {}
    for entry in a.file:
        if len(entry) < 3:
            sys.exit('--file needs a platform, a file and at least one link')
        platform, path, urls = entry[0], entry[1], entry[2:]
        if platform not in PLATFORMS:
            sys.exit(f'Unknown platform "{platform}". Known: {", ".join(PLATFORMS)}')
        if not os.path.isfile(path):
            sys.exit(f'No such file: {path}')
        bad = [u for u in urls if not u.startswith('https://')]
        if bad:
            sys.exit(f'Links must start with https://: {bad[0]}')
        files[platform] = {'urls': urls, 'sha256': sha256_of(path), 'size': os.path.getsize(path)}
        print(f'  {platform}: {os.path.getsize(path) / 1e6:.1f} MB, {len(urls)} link(s)')

    manifest = {'version': a.version, 'date': datetime.date.today().isoformat(), 'notes': notes, 'files': files}
    if a.page:
        if not a.page.startswith('https://'):
            sys.exit('--page must start with https://')
        manifest['page'] = a.page

    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, 'latest.json')
    data = (json.dumps(manifest, indent=2, ensure_ascii=False) + '\n').encode('utf-8')
    with open(path, 'wb') as f:
        f.write(data)
    # the signature is of exactly these bytes; the app checks it before reading them
    raw = os.path.join(a.out, 'latest.json.sig.bin')
    r = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', a.key, '-out', raw, path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit('Signing failed (is openssl installed?): ' + r.stderr.strip())
    with open(raw, 'rb') as f:
        sig = base64.b64encode(f.read())
    os.remove(raw)
    with open(path + '.sig', 'wb') as f:
        f.write(sig + b'\n')
    print(f'Wrote {path} and {path}.sig for version {a.version}')
    if not files:
        print('No files listed: installed copies will be told about this version only if it is newer than theirs, and sent to --page.')

    if a.publish:
        SERVER, SSH_KEY, REMOTE_DIR, PUBLIC_URL = release_server()
        opts = ['-i', SSH_KEY, '-o', 'BatchMode=yes']
        steps = [
            ['ssh', *opts, SERVER, f'install -d -o vyse -g vyse {REMOTE_DIR}'],
            ['scp', '-q', *opts, path, path + '.sig', f'{SERVER}:{REMOTE_DIR}/'],
            ['ssh', *opts, SERVER, f'chown vyse:vyse {REMOTE_DIR}/latest.json {REMOTE_DIR}/latest.json.sig && chmod 644 {REMOTE_DIR}/latest.json {REMOTE_DIR}/latest.json.sig'],
        ]
        for step in steps:
            r = subprocess.run(step, capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit('Publishing failed: ' + (r.stderr.strip() or r.stdout.strip()))
        print(f'Published. Installed copies will see it at {PUBLIC_URL}')
    else:
        print('Not published (add --publish to put it on the server).')


if __name__ == '__main__':
    main()
