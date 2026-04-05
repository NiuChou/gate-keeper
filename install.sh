#!/usr/bin/env bash
set -euo pipefail
REPO="NiuChou/gate-keeper"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/gate-keeper}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Attempt to create directories if they don't exist
mkdir -p "$INSTALL_DIR" "$BIN_DIR" 2>/dev/null || true

# Permission check (after mkdir attempt)
if [ ! -w "$INSTALL_DIR" ] 2>/dev/null || [ ! -w "$BIN_DIR" ] 2>/dev/null; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Permission denied for $INSTALL_DIR or $BIN_DIR"
    echo "Try: sudo bash install.sh"
    echo "Or:  INSTALL_DIR=~/.local/lib/gate-keeper BIN_DIR=~/.local/bin bash install.sh"
    exit 1
  fi
fi

echo "Installing gate-keeper..."
if command -v git >/dev/null 2>&1; then
  git clone --depth 1 "https://github.com/${REPO}.git" "$TMP_DIR/gk" 2>/dev/null
else
  curl -sL "https://github.com/${REPO}/archive/main.tar.gz" | tar xz -C "$TMP_DIR"
  mv "$TMP_DIR/gate-keeper-main" "$TMP_DIR/gk"
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
cp -r "$TMP_DIR/gk/lib" "$INSTALL_DIR/"
cp -r "$TMP_DIR/gk/templates" "$INSTALL_DIR/"
cp "$TMP_DIR/gk/bin/gate-keeper" "$BIN_DIR/"
sed -i.bak "s|LIB_DIR=.*|LIB_DIR=\"${INSTALL_DIR}/lib\"|" "$BIN_DIR/gate-keeper"
sed -i.bak "s|TEMPLATE_DIR=.*|TEMPLATE_DIR=\"${INSTALL_DIR}/templates\"|" "$BIN_DIR/gate-keeper"
rm -f "$BIN_DIR/gate-keeper.bak"
chmod +x "$BIN_DIR/gate-keeper"

echo "Installed to $BIN_DIR/gate-keeper"
echo "Run 'gate-keeper help' to get started"
