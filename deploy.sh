#!/usr/bin/env bash
# Copy the scripts from this repo (in WSL) to the Windows host.
# Copying with cp from WSL does not add a Zone.Identifier mark, so RemoteSigned lets them run
# (copies made via Explorer from \\wsl.localhost are marked Internet-zone and get blocked).
set -euo pipefail

src_dir="$(cd "$(dirname "$0")" && pwd)/src"
localappdata="$(cd /mnt/c && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r')"
dest="${1:-$(wslpath "$localappdata")/win_daily}"

mkdir -p "$dest"
cp "$src_dir"/*.ps1 "$src_dir"/*.psm1 "$dest"/
echo "Deployed to $(wslpath -w "$dest")"
