#!/usr/bin/env bash
# ============================================================================
#  LuaTools aarch64 stack - offline bundle bootstrap
# ============================================================================
#  Installs SLSsteam (patched aarch64 build) + Lumen + LuaTools plugin from the
#  artifacts shipped next to this script, without compiling anything.
#
#  Local:   cd luatools-stack-armada && sudo ./install.sh
#  Hosted:  curl -fsSL https://host/luatools-stack-armada/install.sh \
#             | BUNDLE_BASE_URL=https://host/luatools-stack-armada bash
# ============================================================================
set -uo pipefail

BASE_URL="${BUNDLE_BASE_URL:-https://raw.githubusercontent.com/DaniloSkyrim/luatools-stack-armada/main}"
# Private repos: export GH_TOKEN (or GITHUB_TOKEN) before piping, or pass
# BUNDLE_AUTH_HEADER="Authorization: Bearer <token>" explicitly.
AUTH_HEADER="${BUNDLE_AUTH_HEADER:-}"
if [ -z "$AUTH_HEADER" ]; then
	if [ -n "${GH_TOKEN:-}" ]; then
		AUTH_HEADER="Authorization: Bearer $GH_TOKEN"
	elif [ -n "${GITHUB_TOKEN:-}" ]; then
		AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
	fi
fi
SELF="${BASH_SOURCE[0]:-}"

fetch() {
	if [ -n "$AUTH_HEADER" ]; then
		curl -fsSL -H "$AUTH_HEADER" "$1" -o "$2"
	else
		curl -fsSL "$1" -o "$2"
	fi
}
SELF_DIR=""
if [ -n "$SELF" ] && [ -f "$SELF" ]; then
	SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)"
fi

run_installer() {
	local dir="$1"
	shift
	bash "$dir/installer.sh" \
		--slsteam-bin "$dir/artifacts/slsteam" \
		--lumen-archive "$dir/artifacts/lumen.zip" \
		--plugin-archive "$dir/artifacts/luatools-linux.zip" \
		--sevenzip "$dir/artifacts/7zz" \
		"$@"
}

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/installer.sh" ] && [ -d "$SELF_DIR/artifacts" ]; then
	exec bash "$SELF_DIR/installer.sh" \
		--slsteam-bin "$SELF_DIR/artifacts/slsteam" \
		--lumen-archive "$SELF_DIR/artifacts/lumen.zip" \
		--plugin-archive "$SELF_DIR/artifacts/luatools-linux.zip" \
		--sevenzip "$SELF_DIR/artifacts/7zz" \
		"$@"
fi

if [ -z "$BASE_URL" ]; then
	echo "error: BUNDLE_BASE_URL is empty." >&2
	exit 1
fi

dest="${XDG_DATA_HOME:-$HOME/.local/share}/Lumen/bundle"
echo "  -> downloading the stack bundle into $dest"
for f in installer.sh artifacts/slsteam/SLSsteam.so artifacts/slsteam/library-inject.so \
         artifacts/lumen.zip artifacts/luatools-linux.zip artifacts/7zz; do
	mkdir -p "$dest/$(dirname "$f")" || exit 1
	fetch "$BASE_URL/$f" "$dest/$f" || {
		echo "error: could not download $f" >&2
		echo "       private repo? export GH_TOKEN=<token with Contents: Read> first." >&2
		exit 1
	}
done
chmod +x "$dest/artifacts/7zz" 2>/dev/null || true

run_installer "$dest" "$@"
exit $?
