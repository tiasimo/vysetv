#!/usr/bin/env bash
#
# build-appimage.sh — Wrap a resolved Linux bundle into an AppImage.
# (From Plezy's linux/packaging/build-appimage.sh, without its update feed.)
#
# Usage: build-appimage.sh <bundle-dir> <x64|arm64> <output-dir>
#
# The bundle must already have been through bundle-libs.sh and have vysetv.sh
# copied in: the same tree the tarball is cut from. Writes
# VyseTV-<x86_64|aarch64>.AppImage to <output-dir>.
#
# Needs appimagetool (or APPIMAGETOOL=<path>). Optional environment:
#   RUNTIME_FILE   AppImage runtime to embed; appimagetool downloads the
#                  latest one when unset (fetch-appimage-tools.sh pins one).
#   VERSION        Recorded as X-AppImage-Version in the embedded desktop file.

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <bundle-dir> <x64|arm64> <output-dir>" >&2
    exit 1
fi

BUNDLE_DIR="$(realpath "$1")"
ARCH_SUFFIX="$2"
OUTPUT_DIR="$(realpath "$3")"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
APPIMAGETOOL="${APPIMAGETOOL:-appimagetool}"

case "$ARCH_SUFFIX" in
    x64) APPIMAGE_ARCH=x86_64 ;;
    arm64) APPIMAGE_ARCH=aarch64 ;;
    *)
        echo "Error: unknown arch '$ARCH_SUFFIX' (expected x64 or arm64)" >&2
        exit 1
        ;;
esac

for file in vyse_tv vysetv.sh; do
    if [[ ! -f "$BUNDLE_DIR/$file" ]]; then
        echo "Error: $file not found in $BUNDLE_DIR" >&2
        exit 1
    fi
done
for file in com.vyse.vyse_tv.desktop vysetv.png; do
    if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
        echo "Error: $file not found in $SCRIPT_DIR" >&2
        exit 1
    fi
done

OUTPUT_NAME="VyseTV-$APPIMAGE_ARCH.AppImage"
OUTPUT="$OUTPUT_DIR/$OUTPUT_NAME"

TOOL_ARGS=(--no-appstream)
if [[ -n "${RUNTIME_FILE:-}" ]]; then
    TOOL_ARGS+=(--runtime-file "$(realpath "$RUNTIME_FILE")")
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
APPDIR="$WORK_DIR/VyseTV.AppDir"

echo "==> Assembling AppDir"
cp -a "$BUNDLE_DIR" "$APPDIR"

# vysetv.sh resolves its own path with readlink -f, so as AppRun it finds the
# binary and lib/ at the root of the mounted image.
chmod 0755 "$APPDIR/vysetv.sh" "$APPDIR/vyse_tv"
ln -s vysetv.sh "$APPDIR/AppRun"

# An AppImage is mounted read-only, so what has to run from inside it must
# already be executable: the torrent engine (the app looks for it in lib/) and
# the helpers bundle-libs.sh put there.
for helper in lib/torrserver lib/glib-2.0/gio-launch-desktop lib/gstreamer-1.0/gst-plugin-scanner; do
    if [[ -f "$APPDIR/$helper" ]]; then
        chmod 0755 "$APPDIR/$helper"
    fi
done
if [[ -s "$APPDIR/lib/torrserver" ]]; then
    echo "    torrent engine: bundled"
else
    echo "WARNING: no torrent engine in the bundle; the app would fetch one on first use" >&2
fi

# appimagetool reads the one .desktop file at the AppDir root and expects the
# icon its Icon= names beside it; .DirIcon is what file managers show.
cp "$SCRIPT_DIR/com.vyse.vyse_tv.desktop" "$APPDIR/"
ICON_DIR="$APPDIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
cp "$SCRIPT_DIR/vysetv.png" "$ICON_DIR/vysetv.png"
ln -s usr/share/icons/hicolor/256x256/apps/vysetv.png "$APPDIR/vysetv.png"
ln -s vysetv.png "$APPDIR/.DirIcon"

echo "==> Building $OUTPUT_NAME"
rm -f "$OUTPUT"
# appimagetool changes to $OWD first; an OWD inherited from an AppImage further
# up the process tree would outlive the cd, so it is pinned here too.
(cd "$OUTPUT_DIR" && OWD="$OUTPUT_DIR" ARCH="$APPIMAGE_ARCH" "$APPIMAGETOOL" "${TOOL_ARGS[@]}" "$APPDIR" "$OUTPUT")

chmod 0755 "$OUTPUT"
echo "==> Done"
ls -l "$OUTPUT"
