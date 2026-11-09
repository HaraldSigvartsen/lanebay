#!/bin/sh
# Builds the control CLI and links it as `lanebay` in ~/.local/bin.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product lanebayctl
bin="$(swift build -c release --show-bin-path)/lanebayctl"
mkdir -p "$HOME/.local/bin"
ln -sf "$bin" "$HOME/.local/bin/lanebay"
echo "Installed $HOME/.local/bin/lanebay -> $bin"
