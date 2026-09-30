#!/bin/sh
# deepGit 快速启动：构建（如需）并运行常用命令
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$DIR"

if ! command -v cjc >/dev/null 2>&1; then
  CJ_HOME="${CANGJIE_HOME:-$HOME/.local/share/cangjie/current}"
  [ -f "$CJ_HOME/envsetup.sh" ] && . "$CJ_HOME/envsetup.sh" >/dev/null 2>&1
fi
if [ -z "${SDKROOT:-}" ] && [ -d "$HOME/.local/share/sdks/MacOSX.minimal/latest" ]; then
  export SDKROOT="$HOME/.local/share/sdks/MacOSX.minimal/latest"
fi

BIN="$ENGINE/target/release/bin/main"
if [ ! -x "$BIN" ]; then
  echo "› 首次运行，构建引擎…"
  (cd "$ENGINE" && cjpm build 2>&1 | tail -2)
fi

exec "$BIN" "$@"
