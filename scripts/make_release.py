#!/usr/bin/env python3
"""Gathers what this PC builds for a VyseTV release into dist/<version>/.

Windows and Android are built here (Windows needs the patched engine; Android must always be
signed with this PC's key so updates install over older copies). Mac, iOS and Linux come from
GitHub Actions. Build first:

    flutter build windows --release
    flutter build apk --release --split-per-abi

then:

    python scripts/make_release.py

It writes, under dist/<version from pubspec.yaml>/:

    VyseTV-Setup.exe              the installer (needs Inno Setup 6.3+; skipped with a note if absent)
    VyseTV-Windows.zip            the same program as a folder, for people who don't want an installer
    VyseTV-Android-arm64.apk      most phones and tablets
    VyseTV-Android-armv7.apk      older 32-bit devices
    VyseTV-Android-x86_64.apk     emulators and a few tablets

and prints the scripts/make_update.py line that tells installed copies about the release, with
the links left for you to fill in once the files are uploaded.

Nothing here builds, uploads or publishes anything.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASE = os.path.join(ROOT, 'build', 'windows', 'x64', 'runner', 'Release')
APKS = os.path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk')
ISS = os.path.join(ROOT, 'windows', 'installer', 'vysetv.iss')
# build leftovers that sit next to the program and are no use to anyone running it
LEFTOVERS = ('.lib', '.exp', '.pdb', '.ilk')
ANDROID = [
    ('android-arm64-v8a', 'app-arm64-v8a-release.apk', 'VyseTV-Android-arm64.apk'),
    ('android-armeabi-v7a', 'app-armeabi-v7a-release.apk', 'VyseTV-Android-armv7.apk'),
    ('android-x86_64', 'app-x86_64-release.apk', 'VyseTV-Android-x86_64.apk'),
]


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def version():
    with open(os.path.join(ROOT, 'pubspec.yaml'), encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9.]+)', f.read(), re.M)
    if not m:
        sys.exit('pubspec.yaml has no version')
    return m.group(1)


def find_iscc():
    found = shutil.which('ISCC') or shutil.which('iscc')
    if found:
        return found
    for base in (os.environ.get('ProgramFiles(x86)'), os.environ.get('ProgramFiles'), os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs')):
        if not base or not os.path.isdir(base):
            continue
        # the newest one, if there are several ("Inno Setup 6", "Inno Setup 7"...)
        for folder in sorted((d for d in os.listdir(base) if d.lower().startswith('inno setup')), reverse=True):
            p = os.path.join(base, folder, 'ISCC.exe')
            if os.path.isfile(p):
                return p
    return None


def check_windows_build():
    """The Windows build now and then leaves the old compiled app in the Release folder."""
    exe = os.path.join(RELEASE, 'vyse_tv.exe')
    if not os.path.isfile(exe):
        return 'no Windows build in build/windows/x64/runner/Release'
    built = os.path.join(ROOT, 'build', 'windows', 'app.so')
    shipped = os.path.join(RELEASE, 'data', 'app.so')
    if not os.path.isfile(shipped):
        return 'the Release folder has no data/app.so'
    if os.path.isfile(built) and sha256_of(built) != sha256_of(shipped):
        return 'data/app.so in the Release folder is older than build/windows/app.so (copy it over, or build again)'
    return None


def zip_windows(out):
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for folder, _, names in os.walk(RELEASE):
            for name in sorted(names):
                if name.lower().endswith(LEFTOVERS):
                    continue
                full = os.path.join(folder, name)
                z.write(full, os.path.join('VyseTV', os.path.relpath(full, RELEASE)))


def main():
    ap = argparse.ArgumentParser(description="Gather this PC's builds for a VyseTV release.")
    ap.add_argument('--out', help='where to put them (default: dist/<version>)')
    ap.add_argument('--skip-windows', action='store_true')
    ap.add_argument('--skip-android', action='store_true')
    a = ap.parse_args()

    ver = version()
    out = os.path.abspath(a.out or os.path.join(ROOT, 'dist', ver))
    os.makedirs(out, exist_ok=True)
    made = []   # (platform, path)
    notes = []

    if not a.skip_windows:
        problem = check_windows_build()
        if problem:
            notes.append(f'Windows left out: {problem}.')
        else:
            z = os.path.join(out, 'VyseTV-Windows.zip')
            print('Zipping the Windows folder...')
            zip_windows(z)
            made.append(('windows-x64', z))
            iscc = find_iscc()
            if not iscc:
                notes.append('No installer: Inno Setup 6 is not on this PC (ISCC.exe not found).')
            else:
                print('Making the installer...')
                r = subprocess.run([iscc, '/Qp', f'/DAppVersion={ver}', f'/DSource={RELEASE}', f'/O{out}', ISS], capture_output=True, text=True)
                setup = os.path.join(out, 'VyseTV-Setup.exe')
                if r.returncode != 0 or not os.path.isfile(setup):
                    notes.append('The installer failed to compile:\n' + (r.stdout + r.stderr).strip()[-1500:])
                else:
                    made.append(('windows-x64-setup', setup))

    if not a.skip_android:
        for platform, built, name in ANDROID:
            src = os.path.join(APKS, built)
            if not os.path.isfile(src):
                notes.append(f'{name} left out: {built} is not built.')
                continue
            dst = os.path.join(out, name)
            shutil.copy2(src, dst)
            made.append((platform, dst))

    print(f'\nVyseTV {ver}, in {out}')
    for platform, path in made:
        print(f'  {os.path.basename(path):30} {os.path.getsize(path) / 1e6:7.1f} MB  {sha256_of(path)[:16]}...  ({platform})')
    for n in notes:
        print('  ! ' + n)
    if made:
        rel = os.path.relpath(out, ROOT).replace('\\', '/')
        print('\nOnce they are uploaded, tell installed copies (put each file\'s link in place of LINK):\n')
        print(f'python scripts/make_update.py {ver} --notes "What changed" ^')
        for platform, path in made:
            print(f'  --file {platform} {rel}/{os.path.basename(path)} LINK ^')
        print('  --publish')
    return 0 if made and not notes else 1


if __name__ == '__main__':
    sys.exit(main())
