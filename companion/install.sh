#!/bin/sh
# Installs the `meterkat` companion CLI for the Meterkat iOS app (macOS + Linux).
#
#   ./companion/install.sh [meterkat install flags, e.g. --no-menubar --port 47300]
#   ./companion/install.sh --files-only   # copy the files and stop (used by `meterkat update`)
#
# Copies meterkat.py (and the modules it imports) into ${XDG_DATA_HOME:-~/.local/share}/meterkat, links
# ~/.local/bin/meterkat to it, then runs `meterkat setup` (Linux, interactive, no
# flags) or `meterkat install` to start the background service (and, on macOS, open the Meterkat app at login if it's
# installed; build it with Mac/build.sh).
set -eu

SRC_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/meterkat"
BIN_DIR="$HOME/.local/bin"
FILES_ONLY=false
if [ "${1:-}" = --files-only ]; then
    FILES_ONLY=true
    shift
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found. Install Python 3.9 or newer first." >&2
    exit 1
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    echo "meterkat needs Python 3.9 or newer (found $(python3 --version 2>&1))." >&2
    exit 1
fi

[ ! -e "$DEST_DIR" ] || rm -r "$DEST_DIR"
mkdir -p "$DEST_DIR" "$BIN_DIR"
cp "$SRC_DIR/meterkat.py" "$DEST_DIR/meterkat.py"
cp "$SRC_DIR/api_cost.py" "$DEST_DIR/api_cost.py"
cp "$SRC_DIR/qr.py" "$DEST_DIR/qr.py"
cp "$SRC_DIR/devices.py" "$DEST_DIR/devices.py"
cp "$SRC_DIR/discovery.py" "$DEST_DIR/discovery.py"
chmod +x "$DEST_DIR/meterkat.py"
# `meterkat update` pulls this checkout and copies from it again.
if [ "${METERKAT_INSTALL_SOURCE:-}" = release ]; then
    cp "$SRC_DIR/../install.sh" "$DEST_DIR/bootstrap.sh"
    printf '%s\n' release > "$DEST_DIR/source"
else
    printf '%s\n' "$SRC_DIR" > "$DEST_DIR/source"
fi
ln -sf "$DEST_DIR/meterkat.py" "$BIN_DIR/meterkat"
echo "Installed $BIN_DIR/meterkat -> $DEST_DIR/meterkat.py"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "$BIN_DIR is not on your PATH. Add this to your shell profile:"
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
        ;;
esac

if [ "$FILES_ONLY" = true ]; then
    exit 0
fi

# Run interactively on Linux with no flags, it walks through `meterkat setup`
# (providers, keys, service, pairing). Otherwise it installs the service directly,
# as the Mac app's setup and scripted installs expect.
command=install
if [ "$(uname)" = Linux ] && [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    command=setup
fi
# The service runs this python3 by its stable path (see _service_args in meterkat.py).
METERKAT_PYTHON=$(command -v python3) "$BIN_DIR/meterkat" "$command" "$@"

# setup ends on the pairing screen.
if [ "$command" = install ]; then
    echo ""
    echo "Done. To pair your iPhone, run \`meterkat pair\` or open the Meterkat app (macOS)."
fi
