#!/usr/bin/env bash
# Installer for AllCrack Package Manager (ac).
#
# Usage:
#   sudo ./install.sh              Install under /usr/local
#   sudo ./install.sh uninstall    Remove an installation
#   PREFIX=/opt/ac sudo -E ./install.sh   Use a different prefix
#
# Layout: $PREFIX/lib/ac/{ac,lib/...}, a symlink $PREFIX/bin/ac and the example
# configuration in $PREFIX/share/ac/. /etc/ac.conf is never created or touched.

set -eu

PREFIX=${PREFIX:-/usr/local}
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC_DIR=$ROOT_DIR/src
SHARE_DEST="$PREFIX/share/ac"
LIB_DEST="$PREFIX/lib/ac"
BIN_LINK="$PREFIX/bin/ac"

# Copies ac and its modules into place and creates the PATH symlink.
# Arguments: none (uses PREFIX, ROOT_DIR, SRC_DIR, LIB_DEST, SHARE_DEST, BIN_LINK).
# Returns: 0 on success; aborts (set -e) on any failure.
# Side effects: writes under $PREFIX; replaces any previous installation.
do_install() {
    rm -rf -- "$LIB_DEST"
    install -d -m 755 "$LIB_DEST" "$PREFIX/bin"
    cp -R -- "$SRC_DIR/lib" "$LIB_DEST/lib"
    install -m 755 "$SRC_DIR/ac" "$LIB_DEST/ac"
    find "$LIB_DEST/lib" -type d -exec chmod 755 {} +
    find "$LIB_DEST/lib" -type f -exec chmod 644 {} +
    install -d -m 755 "$SHARE_DEST"
    install -m 644 "$ROOT_DIR/ac.conf.example" "$SHARE_DEST/ac.conf.example"
    ln -sf -- "$LIB_DEST/ac" "$BIN_LINK"
    echo "Installed ac to $BIN_LINK"
}

# Removes the files created by do_install.
# Arguments: none.
# Returns: 0.
# Side effects: deletes $LIB_DEST, $SHARE_DEST and the $BIN_LINK symlink.
do_uninstall() {
    rm -rf -- "$LIB_DEST" "$SHARE_DEST"
    rm -f -- "$BIN_LINK"
    echo "Removed ac from $PREFIX"
}

# Dispatches on the first argument ("uninstall" or nothing).
# Arguments:
#   $1 - Optional action: "install" (default) or "uninstall".
# Returns: 0 on success, 2 for an unknown action.
main() {
    case "${1:-install}" in
        install) do_install ;;
        uninstall) do_uninstall ;;
        *) echo "usage: $0 [install|uninstall]" >&2; return 2 ;;
    esac
}

main "$@"
