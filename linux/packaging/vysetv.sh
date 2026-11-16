#!/usr/bin/env bash
# Wrapper script for VyseTV (from Plezy). Works for both:
#   - Portable tarball (run from extracted directory)
#   - System packages (/usr/bin/vysetv -> /opt/vysetv/)

# Resolve the real path of this script, following symlinks
SCRIPT_PATH="$(readlink -f "$0")"
INSTALL_DIR="$(dirname "$SCRIPT_PATH")"

# If we're in /usr/bin, the actual install is in /opt/vysetv
if [[ "$INSTALL_DIR" == "/usr/bin" ]]; then
    INSTALL_DIR="/opt/vysetv"
fi

# Prepend bundled libraries to LD_LIBRARY_PATH
if [[ -d "$INSTALL_DIR/lib" ]]; then
    export LD_LIBRARY_PATH="$INSTALL_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# gdk-pixbuf loaders
if [[ -f "$INSTALL_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" ]]; then
    export GDK_PIXBUF_MODULE_FILE="$INSTALL_DIR/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
fi

# GIO modules
if [[ -d "$INSTALL_DIR/lib/gio/modules" ]]; then
    export GIO_MODULE_DIR="$INSTALL_DIR/lib/gio/modules"
fi

# gio-launch-desktop: the bundled libgio spawns URL/desktop-file handlers
# through this helper. Its compiled-in path only exists on the build distro
# and glib's PATH fallback misses hosts that keep it in /usr/libexec, which
# broke every URL launch (#1477). Point libgio at the bundled copy.
if [[ -x "$INSTALL_DIR/lib/glib-2.0/gio-launch-desktop" ]]; then
    export GIO_LAUNCH_DESKTOP="$INSTALL_DIR/lib/glib-2.0/gio-launch-desktop"
fi

# GStreamer (the alert tones): only the bundled plugins, which match the bundled
# GStreamer, and a registry of our own so the system's is left alone.
if [[ -d "$INSTALL_DIR/lib/gstreamer-1.0" ]]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$INSTALL_DIR/lib/gstreamer-1.0"
    GST_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/vysetv"
    mkdir -p "$GST_CACHE_DIR" 2>/dev/null || true
    export GST_REGISTRY_1_0="$GST_CACHE_DIR/gstreamer-registry.bin"
    if [[ -x "$INSTALL_DIR/lib/gstreamer-1.0/gst-plugin-scanner" ]]; then
        export GST_PLUGIN_SCANNER_1_0="$INSTALL_DIR/lib/gstreamer-1.0/gst-plugin-scanner"
    fi
fi

# GTK IM modules
if [[ -f "$INSTALL_DIR/lib/gtk-3.0/3.0.0/immodules.cache" ]]; then
    export GTK_IM_MODULE_FILE="$INSTALL_DIR/lib/gtk-3.0/3.0.0/immodules.cache"
fi

# GTK module path (print backends, etc.)
if [[ -d "$INSTALL_DIR/lib/gtk-3.0" ]]; then
    export GTK_PATH="$INSTALL_DIR/lib/gtk-3.0"
fi

# GSettings schemas
if [[ -d "$INSTALL_DIR/share/glib-2.0/schemas" ]]; then
    export GSETTINGS_SCHEMA_DIR="$INSTALL_DIR/share/glib-2.0/schemas"
fi

exec "$INSTALL_DIR/vyse_tv" "$@"
