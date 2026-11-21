#!/usr/bin/env bash
# Wrapper script for Pleazyng. Works for both:
#   - Portable tarball (run from extracted directory)
#   - System packages (/usr/bin/pleazyng -> /opt/pleazyng/)

# Resolve the real path of this script, following symlinks
SCRIPT_PATH="$(readlink -f "$0")"
INSTALL_DIR="$(dirname "$SCRIPT_PATH")"

# If we're in /usr/bin, the actual install is in /opt/pleazyng
if [[ "$INSTALL_DIR" == "/usr/bin" ]]; then
    INSTALL_DIR="/opt/pleazyng"
fi

# Prepend bundled libraries to LD_LIBRARY_PATH
if [[ -d "$INSTALL_DIR/lib" ]]; then
    export LD_LIBRARY_PATH="$INSTALL_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Fixed Steam decoder plugins matching the bundled GStreamer runtime.
if [[ -d "$INSTALL_DIR/lib/gstreamer-1.0" ]]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$INSTALL_DIR/lib/gstreamer-1.0"
    export GST_PLUGIN_PATH_1_0=""
    export GST_PLUGIN_SCANNER_1_0="$INSTALL_DIR/lib/gstreamer-tools/gst-plugin-scanner"
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

# GTK and GdkPixbuf open the module paths recorded in their caches. Relocate
# those records to the actual bundle without writing inside a read-only AppImage.
module_cache() (
    local cache="$1" modules="$2" name="$3"
    local record='^"(.*\/)?([^"/]+\.so)"[[:space:]]*$'
    local line module escaped quoted found=false relocate=false
    local -a lines=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $record ]]; then
            found=true
            module="$modules/${BASH_REMATCH[2]}"
            if [[ ! -f "$module" ]]; then
                echo "Missing bundled module: $module" >&2
                return 1
            fi
            escaped="${module//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            escaped="${escaped//$'\n'/\\n}"
            escaped="${escaped//$'\r'/\\r}"
            escaped="${escaped//$'\t'/\\t}"
            quoted="\"$escaped\""
            [[ "$line" == "$quoted"* ]] || relocate=true
            line="$quoted"
        fi
        lines+=("$line")
    done < "$cache"
    if ! $found; then
        echo "Missing module records in bundled cache: $cache" >&2
        return 1
    fi
    if ! $relocate; then
        printf '%s\n' "$cache"
        return
    fi
    local directory="${XDG_CACHE_HOME:-$HOME/.cache}/pleazyng/$name" key destination temporary
    key=$(printf '%s' "$INSTALL_DIR" | sha256sum) || return 1
    destination="$directory/${key%% *}.cache"
    mkdir -p -- "$directory" || return 1
    temporary=$(mktemp "$directory/.cache.XXXXXX") || return 1
    trap 'rm -f -- "$temporary"' EXIT
    printf '%s\n' "${lines[@]}" > "$temporary" || return 1
    mv -f -- "$temporary" "$destination" || return 1
    printf '%s\n' "$destination"
)

pixbuf="$INSTALL_DIR/lib/gdk-pixbuf-2.0/2.10.0"
if [[ -f "$pixbuf/loaders.cache" ]]; then
    GDK_PIXBUF_MODULE_FILE=$(module_cache "$pixbuf/loaders.cache" "$pixbuf/loaders" pixbuf) || exit 1
    export GDK_PIXBUF_MODULE_FILE
fi

gtk="$INSTALL_DIR/lib/gtk-3.0/3.0.0"
if [[ -f "$gtk/immodules.cache" ]]; then
    GTK_IM_MODULE_FILE=$(module_cache "$gtk/immodules.cache" "$gtk/immodules" gtk-im) || exit 1
    export GTK_IM_MODULE_FILE
fi

# GTK module path (print backends, etc.)
if [[ -d "$INSTALL_DIR/lib/gtk-3.0" ]]; then
    export GTK_PATH="$INSTALL_DIR/lib/gtk-3.0"
fi

# GSettings schemas
if [[ -d "$INSTALL_DIR/share/glib-2.0/schemas" ]]; then
    export GSETTINGS_SCHEMA_DIR="$INSTALL_DIR/share/glib-2.0/schemas"
fi

exec "$INSTALL_DIR/pleazyng" "$@"
