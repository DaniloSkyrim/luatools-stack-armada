#!/usr/bin/env bash
# ============================================================================
#  LuaTools stack installer — native aarch64 / x86_64 and x86 Steam
# ============================================================================
#  Replaces the swwayps/luatools-moon installer for machines where the stack is
#  built from our own SLSsteam tree (the native aarch64 port) instead of the
#  prebuilt 32-bit slsteam-moon release.
#
#  Usage:
#    curl -fsSL <url>/install.sh | bash -s -- --slsteam-src "$HOME/SLSsteam"
#    ./install.sh --slsteam-src ../SLSsteam --nolaunch
#    ./install.sh --uninstall
#
#  Components:
#    SLSsteam       built from --slsteam-src / --slsteam-repo, or installed from
#                   a prebuilt bin/ directory or archive (--slsteam-bin).
#    Lumen          built from --lumen-src / cloned, or from --lumen-archive.
#    LuaTools       plugin release (arch-independent Lua/JS tree) with the
#                   bundled 7-Zip replaced by an aarch64 binary when needed.
#    CloudRedirect  not installed: its Linux hook patches the 32-bit x86 client
#                   and Steam ships no 32-bit client on aarch64.
#    Steam launcher aarch64 Steam Runtime: steamrtarm64/steam is wrapped in place
#                   and the client runs as steam.real (desktop and Game Mode).
#
#  Options: --help
# ============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Paths and defaults
# ----------------------------------------------------------------------------
SLSDIR="${SLSSTEAM_DIR:-$HOME/.local/share/SLSsteam}"
LUMEN_DIR="${LUMEN_DIR:-$HOME/.local/share/Lumen}"
PLUGIN_DIR="$LUMEN_DIR/luatools"
SDIR="$SLSDIR/path"
BACKUP_DIR="$SLSDIR/backup"
DESKTOP_BACKUP="$BACKUP_DIR/desktop"
MANIFEST="$BACKUP_DIR/desktop-manifest.txt"
GAMEMODE_MANIFEST="$BACKUP_DIR/gamemode-hooks.txt"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/SLSsteam"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

PLUGIN_REPO="swwayps/luatools-moon"
PLUGIN_ASSET="luatools-linux.zip"
MIRROR_MANIFEST="https://cdn.jsdelivr.net/gh/swwayps/jsdelivr@main/manifest.json"
LUMEN_REPO="https://github.com/swwayps/lumen.git"
# The aarch64 patch (lumen_patch_content) applies to this commit. Override with
# --lumen-ref only together with a patch that still applies.
LUMEN_REF_DEFAULT="52475c3ec0bbe2bf0ccdd209d86a40d99a9881fa"
SEVENZIP_URL="https://www.7-zip.org/a/7z2501-linux-arm64.tar.xz"
SEVENZIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/luatools-aarch64/7zz"
# Lumen links Lua 5.4 statically. Distros without the development package
# (SteamOS, Bazzite) get this tarball built into a private static library.
LUA_VERSION="5.4.7"
LUA_URL="https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
LUA_SHA256="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"

# Steam Runtime launcher layout (aarch64): <root>/steamrtarm64/steam is replaced
# by a wrapper and the client runs as steamrtarm64/steam.real. Set by detect_steamrt.
STEAM_ROOT=""
STEAMRT_DIR=""
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
INSTALL_CONF="$LUMEN_DIR/install.conf"

# Publish the aarch64 tree in a fork and put its URL here to make the plain
# `curl ... | bash` form install everything without --slsteam-src.
SLSSTEAM_REPO_DEFAULT=""

# ----------------------------------------------------------------------------
# Options (parsed by parse_args)
# ----------------------------------------------------------------------------
OPT_HELP=0
OPT_UNINSTALL=0
OPT_PURGE=0
OPT_NOPLUGIN=0
OPT_NOLAUNCH=0
OPT_NO_GAMEMODE=0
OPT_SKIP_LIBS=0
OPT_BAD_ARG=""

SLSSTEAM_SRC="${SLSSTEAM_SRC:-}"
SLSSTEAM_BIN="${SLSSTEAM_BIN:-}"
SLSSTEAM_REPO="${SLSSTEAM_REPO:-$SLSSTEAM_REPO_DEFAULT}"
SLSSTEAM_REF="${SLSSTEAM_REF:-}"
SLSSTEAM_ARCHIVE="${SLSSTEAM_ARCHIVE:-}"
SLSSTEAM_LIBS="${SLSSTEAM_LIBS:-}"
LUMEN_SRC="${LUMEN_SRC:-}"
LUMEN_REF="${LUMEN_REF:-}"
LUMEN_ARCHIVE="${LUMEN_ARCHIVE:-}"
PLUGIN_SRC="${PLUGIN_SRC:-}"
PLUGIN_ARCHIVE="${PLUGIN_ARCHIVE:-}"
SEVENZIP="${SEVENZIP:-}"

ARCH=""
DISTRO_ID=""
DISTRO_FAMILY=""
TMP_ROOT=""
STEAM_BIN=""

# ----------------------------------------------------------------------------
# Output (English / Português)
# ----------------------------------------------------------------------------
detect_language() {
	local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	case "$l" in
		pt*|*_BR*|*_PT*) LANG_IS_PT=1 ;;
		*)               LANG_IS_PT=0 ;;
	esac
}

L() { if [ "${LANG_IS_PT:-0}" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

log_info()    { printf '  -> %s\n' "$1"; }
log_success() { printf '  ok %s\n' "$1"; }
log_warn()    { printf '  !! %s\n' "$1"; }
log_error()   { printf '  xx %s\n' "$1"; }
log_step()    { printf '  .. %s\n' "$1"; }

fail() {
	log_error "$1"
	[ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT" 2>/dev/null
	exit 1
}

print_banner() {
	echo ""
	echo "  LuaTools stack installer"
	echo "  SLSsteam (native) + Lumen + LuaTools plugin"
	echo ""
}

print_section() {
	echo ""
	echo "── $1"
}

# yes/no with a sane default when no controlling terminal exists.
prompt_yes_no() {
	local q_en="$1" q_pt="$2" def="${3:-y}" prompt hint ans
	prompt="$(L "$q_en" "$q_pt")"
	if [ "$def" = "y" ]; then hint="$(L "[Y/n]" "[S/n]")"; else hint="$(L "[y/N]" "[s/N]")"; fi
	if ! { [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; }; then
		[ "$def" = "y" ]
		return
	fi
	while :; do
		printf '%s %s ' "$prompt" "$hint" >/dev/tty
		IFS= read -r ans </dev/tty || ans=""
		ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
		case "$ans" in
			"")    [ "$def" = "y" ]; return ;;
			y*|s*) return 0 ;;
			n*)    return 1 ;;
			*) printf '%s\n' "$(L "Please answer y or n." "Responda s ou n.")" >/dev/tty ;;
		esac
	done
}

usage() {
	cat <<EOF
$(L "Usage" "Uso"): install.sh [options]

  --slsteam-src DIR       $(L "SLSsteam checkout to build (has src/arch.hpp)." "Checkout do SLSsteam para compilar (contém src/arch.hpp).")
  --slsteam-repo URL      $(L "Clone this repository when no source dir is given." "Clona este repositório quando nenhum diretório for dado.")
  --slsteam-ref REF       $(L "Branch/tag for --slsteam-repo." "Branch/tag para --slsteam-repo.")
  --slsteam-bin PATH      $(L "Prebuilt bin/ directory or .zip/.tar.gz holding SLSsteam.so." "Diretório bin/ ou .zip/.tar.gz pronto com SLSsteam.so.")
  --slsteam-archive PATH  $(L "Same as --slsteam-bin (archive only)." "Igual a --slsteam-bin (somente arquivo).")
  --slsteam-libs DIR      $(L "Prebuilt lib/arm64 (libmem, yaml-cpp, protobuf, LuaJIT)." "lib/arm64 pronto (libmem, yaml-cpp, protobuf, LuaJIT).")
  --skip-libs             $(L "Never run 'make libs-arm64'; fail if libs are missing." "Não rodar 'make libs-arm64'; falha se as libs faltarem.")
  --lumen-src DIR         $(L "Lumen checkout to build." "Checkout do Lumen para compilar.")
  --lumen-archive PATH    $(L "Prebuilt lumen zip (binary + lua/)." "Zip pronto do Lumen (binário + lua/).")
  --lumen-ref REF         $(L "Lumen commit to clone and patch (default: the pinned one)." "Commit do Lumen para clonar e aplicar o patch (padrão: o fixado).")
  --plugin-src DIR        $(L "LuaTools source tree or luatools-moon checkout." "Fonte do LuaTools ou checkout do luatools-moon.")
  --plugin-archive PATH   $(L "Plugin zip or URL (default: latest release)." "Zip ou URL do plugin (padrão: última release).")
  --sevenzip PATH         $(L "Working aarch64 7zz to bundle for .rar fixes." "7zz aarch64 funcional para fixes .rar.")
  --noplugin              $(L "Install SLSsteam + Lumen only." "Instalar apenas SLSsteam + Lumen.")
  --nolaunch              $(L "Do not start Steam at the end." "Não iniciar a Steam no final.")
  --no-gamemode           $(L "Skip the opt-in Game Mode hooks." "Pular os hooks opcionais do Game Mode.")
  --uninstall             $(L "Remove the stack (keeps ~/.config/SLSsteam)." "Remove o stack (mantém ~/.config/SLSsteam).")
  --purge                 $(L "With --uninstall: also delete the SLSsteam config." "Com --uninstall: apagar também a config do SLSsteam.")
  --slsteam-channel / --plugin-channel / --lumen-channel
                          $(L "Accepted for Lumen Update All compatibility; ignored." "Aceitos por compatibilidade com o Update All do Lumen; ignorados.")
  -h, --help              $(L "Show this help." "Mostrar esta ajuda.")

$(L "aarch64 Steam Runtime: steamrtarm64/steam is wrapped in place; the client runs as steam.real." "Steam Runtime aarch64: steamrtarm64/steam é envolvido no lugar; o cliente roda como steam.real.")
EOF
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--slsteam-src|--slsteam-repo|--slsteam-ref|--slsteam-bin|--slsteam-archive|--slsteam-libs|--lumen-src|--lumen-archive|--lumen-ref|--plugin-src|--plugin-archive|--sevenzip)
				if [ "$#" -lt 2 ]; then OPT_BAD_ARG="$1"; return 1; fi
				case "$1" in
					--slsteam-src)     SLSSTEAM_SRC="$2" ;;
					--slsteam-repo)    SLSSTEAM_REPO="$2" ;;
					--slsteam-ref)     SLSSTEAM_REF="$2" ;;
					--slsteam-bin)     SLSSTEAM_BIN="$2" ;;
					--slsteam-archive) SLSSTEAM_ARCHIVE="$2" ;;
					--slsteam-libs)    SLSSTEAM_LIBS="$2" ;;
					--lumen-src)       LUMEN_SRC="$2" ;;
					--lumen-archive)   LUMEN_ARCHIVE="$2" ;;
					--lumen-ref)       LUMEN_REF="$2" ;;
					--plugin-src)      PLUGIN_SRC="$2" ;;
					--plugin-archive)  PLUGIN_ARCHIVE="$2" ;;
					--sevenzip)        SEVENZIP="$2" ;;
				esac
				shift
				;;
			--skip-libs)     OPT_SKIP_LIBS=1 ;;
			--noplugin)      OPT_NOPLUGIN=1 ;;
			--nolaunch)      OPT_NOLAUNCH=1 ;;
			--no-gamemode)   OPT_NO_GAMEMODE=1 ;;
			--uninstall)     OPT_UNINSTALL=1 ;;
			--purge)         OPT_PURGE=1 ;;
			-h|--help)       OPT_HELP=1 ;;
			# Lumen's "Update All" forwards these upstream flags. This installer
			# always builds from the local/fork source, so they are accepted and
			# ignored instead of aborting the update.
			--slsteam-channel|--plugin-channel|--lumen-channel)
				if [ "$#" -lt 2 ]; then OPT_BAD_ARG="$1"; return 1; fi
				case "$2" in
					stable|beta) ;;
					*) OPT_BAD_ARG="$1 $2"; return 1 ;;
				esac
				shift
				;;
			*)               OPT_BAD_ARG="$1"; return 1 ;;
		esac
		shift
	done
	return 0
}

# ----------------------------------------------------------------------------
# Generic helpers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

download() {
	local url="$1" out="$2"
	curl --proto '=https' --proto-redir '=https' -fL \
		--connect-timeout 15 --retry 3 --retry-delay 2 "$url" -o "$out"
}

verify_sha256() {
	local file="$1" want got
	want="$(printf '%s' "$2" | awk '{print $1}' | tr -d '[:space:]' | tr 'A-F' 'a-f')"
	[ "${#want}" -eq 64 ] || return 1
	have sha256sum || return 1
	got="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
	[ -n "$got" ] && [ "$got" = "$want" ]
}

# Verify a downloaded release asset against its published .sha256 sidecar.
# A sidecar that is absent is fine (older releases); a mismatch is fatal.
verify_asset_sidecar() {
	local url="$1" archive="$2" sidecar="$2.sha256" want
	case "$url" in https://*) ;; *) return 0 ;; esac
	curl --proto '=https' --proto-redir '=https' -fsL \
		--connect-timeout 10 "$url.sha256" -o "$sidecar" 2>/dev/null || return 0
	want="$(cat "$sidecar" 2>/dev/null)"
	rm -f "$sidecar"
	[ -n "$want" ] || return 0
	verify_sha256 "$archive" "$want" || fail "$(L \
		"The downloaded archive does not match its published checksum." \
		"O arquivo baixado não corresponde ao checksum publicado.")"
}

extract_archive() {
	local file="$1" dest="$2"
	mkdir -p "$dest"
	case "$file" in
		*.zip)
			unzip -qo "$file" -d "$dest"
			;;
		*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar)
			tar -xf "$file" -C "$dest"
			;;
		*)
			return 1
			;;
	esac
}

# Reject zip entries that would escape the destination.
zip_is_safe() {
	local file="$1" names
	names="$(unzip -Z1 "$file" 2>/dev/null)" || return 1
	[ -n "$names" ] || return 1
	if printf '%s\n' "$names" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
		return 1
	fi
	return 0
}

# ----------------------------------------------------------------------------
# Architecture and ELF validation
# ----------------------------------------------------------------------------
detect_arch() {
	case "$(uname -m)" in
		aarch64|arm64) ARCH="aarch64" ;;
		x86_64|amd64)  ARCH="x86_64" ;;
		*)
			fail "$(L "Unsupported architecture: $(uname -m). This installer supports aarch64 and x86_64 hosts." \
			          "Arquitetura não suportada: $(uname -m). Este instalador suporta hosts aarch64 e x86_64.")"
			;;
	esac
	log_success "$(L "Architecture: $ARCH" "Arquitetura: $ARCH")"
}

# elf_machine FILE echoes the ELF e_machine field (little endian, 2 bytes).
elf_machine() { od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'; }
# elf_class FILE echoes the ELF class byte: 01 = 32-bit, 02 = 64-bit.
elf_class() { od -An -tx1 -j4 -N1 "$1" 2>/dev/null | tr -d ' \n'; }

# elf_ok FILE TARGET (aarch64 | x86_64 | x86)
elf_ok() {
	local file="$1" target="$2" want_m class
	case "$target" in
		aarch64) want_m="b700"; class="02" ;;
		x86_64)  want_m="3e00"; class="02" ;;
		x86)     want_m="0300"; class="01" ;;
		*) return 1 ;;
	esac
	[ -f "$file" ] || return 1
	[ "$(elf_machine "$file")" = "$want_m" ] || return 1
	[ "$(elf_class "$file")" = "$class" ] || return 1
	return 0
}

slssteam_elf_target() {
	# Steam is 32-bit on x86_64 and native 64-bit on aarch64.
	if [ "$ARCH" = "aarch64" ]; then printf 'aarch64'; else printf 'x86'; fi
}

verify_slssteam_bin() {
	local dir="$1" target
	target="$(slssteam_elf_target)"
	[ -f "$dir/SLSsteam.so" ] || fail "$(L "SLSsteam.so not found in $dir" "SLSsteam.so não encontrado em $dir")"
	elf_ok "$dir/SLSsteam.so" "$target" || fail "$(L \
		"$dir/SLSsteam.so is not a $target ELF. Build the right architecture or pass another --slsteam-bin." \
		"$dir/SLSsteam.so não é um ELF $target. Compile a arquitetura correta ou passe outro --slsteam-bin.")"
	[ -f "$dir/library-inject.so" ] || \
		log_warn "$(L "library-inject.so is absent; the audit list will use SLSsteam.so only" \
		             "library-inject.so ausente; a lista de auditoria usará só o SLSsteam.so")"
}

# ----------------------------------------------------------------------------
# Distro / dependencies
# ----------------------------------------------------------------------------
read_os_release() {
	[ -f /etc/os-release ] || { DISTRO_ID="unknown"; DISTRO_FAMILY="unknown"; return; }
	# shellcheck disable=SC1091
	. /etc/os-release
	DISTRO_ID="${ID:-unknown}"
	case "$DISTRO_ID" in
		ubuntu|debian|linuxmint|pop|raspbian) DISTRO_FAMILY="debian" ;;
		fedora|rhel|centos|rocky|almalinux)   DISTRO_FAMILY="fedora" ;;
		arch|manjaro|endeavouros|cachyos)     DISTRO_FAMILY="arch" ;;
		opensuse*|sles)                        DISTRO_FAMILY="opensuse" ;;
		*)                                     DISTRO_FAMILY="unknown" ;;
	esac
}

is_immutable() {
	case "$DISTRO_ID" in
		bazzite|steamos|steamdeck|holoiso|silverblue|kinoite|sericea|onyx|bluefin|aurora|ucore)
			return 0 ;;
	esac
	have rpm-ostree || have steamos-readonly
}

is_nixos() { [ "$DISTRO_ID" = "nixos" ]; }

sudo_cmd() {
	if [ "$(id -u)" -eq 0 ]; then printf ''; else printf 'sudo'; fi
}

ensure_sudo() {
	if [ "$(id -u)" -eq 0 ] || ! have sudo; then return 0; fi
	sudo -n true 2>/dev/null && return 0
	if [ -e /dev/tty ]; then
		sudo -v </dev/tty >/dev/tty 2>&1 || fail "$(L "Administrator access was not granted." "Acesso de administrador não concedido.")"
	else
		fail "$(L "Administrator access is required to install packages." \
		          "É preciso acesso de administrador para instalar pacotes.")"
	fi
}

pkg_names() {
	local kind="$1"
	case "$DISTRO_FAMILY" in
		debian)
			if [ "$kind" = "runtime" ]; then
				echo "curl ca-certificates jq tar unzip xz-utils procps"
			else
				echo "build-essential cmake git pkg-config libssl-dev libcurl4-openssl-dev liblua5.4-dev zlib1g-dev"
			fi
			;;
		fedora)
			if [ "$kind" = "runtime" ]; then
				echo "curl ca-certificates jq tar unzip xz procps-ng"
			else
				echo "gcc gcc-c++ make cmake git pkgconf-pkg-config openssl-devel libcurl-devel lua-devel zlib-devel"
			fi
			;;
		arch)
			if [ "$kind" = "runtime" ]; then
				echo "curl ca-certificates jq tar unzip xz procps-ng"
			else
				echo "base-devel cmake git pkgconf openssl libcurl lua54 zlib"
			fi
			;;
		opensuse)
			if [ "$kind" = "runtime" ]; then
				echo "curl ca-certificates jq tar unzip xz procps"
			else
				echo "gcc gcc-c++ make cmake git pkg-config libopenssl-devel libcurl-devel lua54-devel zlib-devel"
			fi
			;;
		*)
			echo ""
			;;
	esac
}

install_pkgs() {
	local pkgs="$1" sudo_c
	[ -n "$pkgs" ] || return 1
	is_immutable && return 1
	is_nixos && return 1
	ensure_sudo
	sudo_c="$(sudo_cmd)"
	case "$DISTRO_FAMILY" in
		debian)
			# shellcheck disable=SC2086
			$sudo_c env DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
			# shellcheck disable=SC2086
			$sudo_c env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
			;;
		fedora)
			# shellcheck disable=SC2086
			$sudo_c dnf install -y $pkgs
			;;
		arch)
			# shellcheck disable=SC2086
			$sudo_c pacman -S --needed --noconfirm $pkgs
			;;
		opensuse)
			# shellcheck disable=SC2086
			$sudo_c zypper install -y $pkgs
			;;
		*)
			return 1
			;;
	esac
}

manual_hint() {
	case "$DISTRO_ID" in
		steamos|steamdeck|holoiso)
			echo "sudo steamos-readonly disable && sudo pacman-key --init && sudo pacman-key --populate && sudo pacman -S $1"
			;;
		bazzite|silverblue|kinoite|sericea|onyx|bluefin|aurora|ucore)
			echo "rpm-ostree install $1   ($(L "then reboot" "depois reinicie"))"
			;;
		nixos)
			echo "nix profile install $1"
			;;
		ubuntu|debian|linuxmint|pop|raspbian)
			echo "sudo apt install $1"
			;;
		fedora|rhel|centos|rocky|almalinux)
			echo "sudo dnf install $1"
			;;
		arch|manjaro|endeavouros|cachyos)
			echo "sudo pacman -S $1"
			;;
		opensuse*|sles*)
			echo "sudo zypper install $1"
			;;
		*)
			echo "$(L "install with your package manager" "instale com o gerenciador de pacotes")"
			;;
	esac
}

check_runtime_tools() {
	local missing="" t
	for t in curl tar unzip jq od pgrep pkill sha256sum; do
		have "$t" || missing="$missing $t"
	done
	[ -z "$missing" ] && { log_success "$(L "Runtime tools present" "Ferramentas de runtime presentes")"; return 0; }

	local pkgs; pkgs="$(pkg_names runtime)"
	if install_pkgs "$pkgs"; then
		return 0
	fi
	fail "$(L "Missing tools:${missing}. Install them manually: $(manual_hint "$pkgs")" \
	          "Ferramentas ausentes:${missing}. Instale manualmente: $(manual_hint "$pkgs")")"
}

check_build_tools() {
	local missing="" t
	for t in git make cmake g++ od; do
		have "$t" || missing="$missing $t"
	done
	[ -z "$missing" ] && { log_success "$(L "Build tools present" "Ferramentas de build presentes")"; return 0; }

	local pkgs; pkgs="$(pkg_names build)"
	if install_pkgs "$pkgs" && have make && have cmake && have git && have g++; then
		return 0
	fi
	is_immutable && fail "$(L "Build tools are missing and this is an immutable system. Build the stack elsewhere and pass --slsteam-bin / --lumen-archive. Hint: $(manual_hint "$pkgs")" \
	                            "Faltam ferramentas de build e o sistema é imutável. Compile em outra máquina e passe --slsteam-bin / --lumen-archive. Dica: $(manual_hint "$pkgs")")"
	is_nixos && fail "$(L "Build tools are missing. Add them to environment.systemPackages or pass prebuilt artifacts. Hint: $(manual_hint "$pkgs")" \
	                        "Faltam ferramentas de build. Adicione em environment.systemPackages ou passe artefatos prontos. Dica: $(manual_hint "$pkgs")")"
	fail "$(L "Could not install build tools:${missing}. Install manually: $(manual_hint "$pkgs")" \
	          "Não foi possível instalar as ferramentas de build:${missing}. Instale manualmente: $(manual_hint "$pkgs")")"
}

# ----------------------------------------------------------------------------
# Steam checks
# ----------------------------------------------------------------------------
find_native_steam() {
	local c
	for c in /usr/bin/steam /usr/games/steam /usr/local/bin/steam /bin/steam; do
		case "$c" in "$SDIR"/*) continue ;; esac
		if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
	done
	if have steam; then
		c="$(command -v steam)"
		case "$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")" in
			"$SDIR"/*) return 1 ;;
		esac
		printf '%s\n' "$c"
		return 0
	fi
	# aarch64 Steam is often a self-contained bootstrap with no distro launcher.
	for c in "$HOME/.local/share/Steam/steam.sh" \
	         "$HOME/.steam/steam/steam.sh" \
	         "$HOME/.steam/debian-installation/steam.sh"; do
		if [ -x "$c" ]; then printf '%s\n' "$c"; return 0; fi
	done
	return 1
}

# aarch64 Steam ships its own Steam Runtime launcher: steamrtarm64/steam execs
# the client (steamrtarm64/steam.real). Both desktop and Game Mode start it, so
# the SLSsteam wrapper replaces that file instead of a PATH entry.
detect_steamrt() {
	local root
	STEAM_ROOT=""; STEAMRT_DIR=""
	[ "$ARCH" = "aarch64" ] || return 1
	for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.steam/debian-installation"; do
		[ -d "$root/steamrtarm64" ] || continue
		[ -f "$root/steamrtarm64/steam" ] || [ -f "$root/steamrtarm64/steam.real" ] || continue
		STEAM_ROOT="$(readlink -f "$root" 2>/dev/null || printf '%s' "$root")"
		STEAMRT_DIR="$STEAM_ROOT/steamrtarm64"
		return 0
	done
	return 1
}

check_steam() {
	STEAM_BIN="$(find_native_steam 2>/dev/null || true)"
	if [ -z "$STEAM_BIN" ] && detect_steamrt; then
		STEAM_BIN="$STEAM_ROOT/steam.sh"
		[ -x "$STEAM_BIN" ] || STEAM_BIN="$STEAMRT_DIR/steam"
	fi
	if [ -z "$STEAM_BIN" ]; then
		if have flatpak && flatpak list --app --columns=application 2>/dev/null | grep -Fxq "com.valvesoftware.Steam"; then
			fail "$(L "Only the Flatpak Steam was found. This stack needs the native package." \
			          "Só a Steam via Flatpak foi encontrada. Este stack precisa da Steam nativa.")"
		fi
		fail "$(L "Native Steam was not found. Install it from your package manager and run it once." \
		          "A Steam nativa não foi encontrada. Instale pelo gerenciador de pacotes e abra uma vez.")"
	fi
	log_success "$(L "Native Steam: $STEAM_BIN" "Steam nativa: $STEAM_BIN")"
	if detect_steamrt; then
		log_success "$(L "Steam Runtime launcher: $STEAMRT_DIR" "Launcher do Steam Runtime: $STEAMRT_DIR")"
	fi

	if [ ! -L "$HOME/.steam/steam" ] || [ ! -f "$(readlink -f "$HOME/.steam/steam" 2>/dev/null)/steam.sh" ]; then
		fail "$(L "Steam has not finished its first-run setup. Open Steam once, close it, then run this installer." \
		          "A Steam ainda não terminou a configuração inicial. Abra a Steam uma vez, feche e rode o instalador de novo.")"
	fi
	log_success "$(L "Steam data directory initialized" "Diretório de dados da Steam inicializado")"
}

# Millennium forces Steam's webhelper onto --remote-debugging-pipe, so Lumen
# cannot attach over the CEF port while it is installed.
check_millennium() {
	local hit=0
	[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/millennium" ] && hit=1
	[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/millennium" ] && hit=1
	[ -L "$HOME/.steam/steam/ubuntu12_64/libmillennium_hhx64.so" ] && hit=1
	if [ "$hit" = 1 ]; then
		log_warn "$(L "Millennium is installed and blocks Lumen's CEF endpoint. Remove Millennium before using the LuaTools plugin." \
		             "Millennium está instalado e bloqueia o endpoint CEF do Lumen. Remova o Millennium antes de usar o plugin LuaTools.")"
	fi
}

# ----------------------------------------------------------------------------
# Process control
# ----------------------------------------------------------------------------
steam_running() {
	pgrep -x steam >/dev/null 2>&1 || pgrep -x steam.real >/dev/null 2>&1 || pgrep -f 'steamwebhelper' >/dev/null 2>&1
}

stop_steam() {
	if ! steam_running; then
		log_success "$(L "Steam is not running" "A Steam não está rodando")"
		return 0
	fi
	log_info "$(L "Stopping Steam" "Parando a Steam")"
	if [ -n "$STEAM_BIN" ]; then
		if have timeout; then
			timeout -k 5 20 "$STEAM_BIN" -shutdown >/dev/null 2>&1 || true
		else
			"$STEAM_BIN" -shutdown >/dev/null 2>&1 || true
		fi
	fi
	local i
	for i in 1 2 3 4 5 6 7 8; do
		steam_running || { log_success "$(L "Steam stopped" "Steam parada")"; return 0; }
		sleep 1
	done
	pkill -TERM -x steam 2>/dev/null || true
	pkill -TERM -x steam.real 2>/dev/null || true
	pkill -TERM -f 'steamwebhelper' 2>/dev/null || true
	sleep 2
	if steam_running; then
		log_warn "$(L "Forcing Steam to stop" "Forçando o encerramento da Steam")"
		pkill -KILL -x steam 2>/dev/null || true
		pkill -KILL -x steam.real 2>/dev/null || true
		pkill -KILL -f 'steamwebhelper' 2>/dev/null || true
		sleep 1
	fi
	log_success "$(L "Steam stopped" "Steam parada")"
}

stop_lumen() {
	pgrep -f "$LUMEN_DIR/lumen" >/dev/null 2>&1 || return 0
	log_info "$(L "Stopping Lumen" "Parando o Lumen")"
	pkill -TERM -f "$LUMEN_DIR/lumen" 2>/dev/null || true
	sleep 1
	pkill -KILL -f "$LUMEN_DIR/lumen" 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# SLSsteam
# ----------------------------------------------------------------------------
autodetect_slssteam_src() {
	local self="${BASH_SOURCE[0]:-}" dir candidate
	if [ -n "$SLSSTEAM_SRC" ]; then return 0; fi
	if [ -n "$self" ] && [ -f "$self" ]; then
		dir="$(cd "$(dirname "$self")" && pwd)"
		for candidate in "$dir/SLSsteam" "$dir"; do
			if [ -f "$candidate/src/arch.hpp" ]; then SLSSTEAM_SRC="$candidate"; return 0; fi
		done
	fi
	for candidate in "$PWD/SLSsteam" "$PWD"; do
		if [ -f "$candidate/src/arch.hpp" ]; then SLSSTEAM_SRC="$candidate"; return 0; fi
	done
	return 0
}

clone_slssteam() {
	[ -n "$SLSSTEAM_REPO" ] || return 1
	local dest="$TMP_ROOT/SLSsteam"
	log_info "$(L "Cloning $SLSSTEAM_REPO" "Clonando $SLSSTEAM_REPO")"
	if [ -n "$SLSSTEAM_REF" ]; then
		git clone --depth 1 --branch "$SLSSTEAM_REF" "$SLSSTEAM_REPO" "$dest" || return 1
	else
		git clone --depth 1 "$SLSSTEAM_REPO" "$dest" || return 1
	fi
	SLSSTEAM_SRC="$dest"
}

# Copy the four static archives the aarch64 build links against.
install_prebuilt_libs() {
	local src="$1"
	[ -d "$src" ] || fail "$(L "--slsteam-libs is not a directory: $src" "--slsteam-libs não é um diretório: $src")"
	mkdir -p "$SLSSTEAM_SRC/lib/arm64"
	cp -f "$src"/*.a "$SLSSTEAM_SRC/lib/arm64/" || fail "$(L "Could not copy the static libraries" "Não foi possível copiar as bibliotecas estáticas")"
}

slssteam_libs_ok() {
	local dir="$SLSSTEAM_SRC/lib/arm64" a
	for a in liblibmem.a libyaml-cpp.a libprotobuf.a libluajit.a; do
		[ -f "$dir/$a" ] || return 1
	done
	return 0
}

build_slssteam() {
	local src="$SLSSTEAM_SRC" make_args=()
	[ -n "$src" ] || fail "$(L \
		"No SLSsteam source or binary was provided. The aarch64 port is not published as a release yet; pass --slsteam-src <checkout> (or --slsteam-bin <dir>)." \
		"Nenhuma fonte ou binário do SLSsteam foi informado. O port aarch64 ainda não é publicado como release; passe --slsteam-src <checkout> (ou --slsteam-bin <dir>).")"
	[ -f "$src/src/arch.hpp" ] || fail "$(L "$src does not look like the SLSsteam tree (src/arch.hpp missing)." "$src não parece ser a árvore do SLSsteam (falta src/arch.hpp).")"
	check_build_tools

	if [ -n "$SLSSTEAM_LIBS" ]; then
		install_prebuilt_libs "$SLSSTEAM_LIBS"
	fi

	if [ "$ARCH" = "aarch64" ]; then
		if ! slssteam_libs_ok; then
			if [ "$OPT_SKIP_LIBS" = 1 ]; then
				fail "$(L "lib/arm64 is incomplete and --skip-libs was given. Provide --slsteam-libs or run make libs-arm64." \
				          "lib/arm64 está incompleta e --skip-libs foi usado. Passe --slsteam-libs ou rode make libs-arm64.")"
			fi
			log_warn "$(L "Building the aarch64 static libraries (libmem, yaml-cpp, protobuf, LuaJIT). This takes a while." \
			             "Compilando as bibliotecas estáticas aarch64 (libmem, yaml-cpp, protobuf, LuaJIT). Isso demora.")"
			( cd "$src" && make libs-arm64 ) || fail "$(L "make libs-arm64 failed" "make libs-arm64 falhou")"
		fi
		slssteam_libs_ok || fail "$(L "lib/arm64 is still incomplete after the build." "lib/arm64 continua incompleta após o build.")"
		make_args=(ARCH=aarch64)
	else
		make_args=(ARCH=x86)
	fi

	log_info "$(L "Building SLSsteam" "Compilando o SLSsteam")"
	( cd "$src" && make "${make_args[@]}" audit-libs ) || fail "$(L \
		"SLSsteam build failed. On x86_64 the 32-bit toolchain and i386 libssl/libcurl headers are required." \
		"O build do SLSsteam falhou. No x86_64 são necessários o toolchain 32 bits e os headers i386 de libssl/libcurl.")"

	SLSSTEAM_BIN="$src/bin"
}

resolve_slssteam() {
	local dir
	if [ -n "$SLSSTEAM_BIN" ]; then
		if [ -d "$SLSSTEAM_BIN" ]; then
			verify_slssteam_bin "$SLSSTEAM_BIN"
			return 0
		fi
		if [ -f "$SLSSTEAM_BIN" ]; then
			dir="$TMP_ROOT/slssteam-bin"
			extract_archive "$SLSSTEAM_BIN" "$dir" || fail "$(L "Could not extract $SLSSTEAM_BIN" "Não foi possível extrair $SLSSTEAM_BIN")"
			dir="$(find "$dir" -maxdepth 3 -name SLSsteam.so -printf '%h\n' 2>/dev/null | head -n1)"
			[ -n "$dir" ] || fail "$(L "SLSsteam.so not found inside $SLSSTEAM_BIN" "SLSsteam.so não encontrado dentro de $SLSSTEAM_BIN")"
			SLSSTEAM_BIN="$dir"
			verify_slssteam_bin "$SLSSTEAM_BIN"
			return 0
		fi
		fail "$(L "--slsteam-bin does not exist: $SLSSTEAM_BIN" "--slsteam-bin não existe: $SLSSTEAM_BIN")"
	fi

	if [ -n "$SLSSTEAM_ARCHIVE" ]; then
		[ -f "$SLSSTEAM_ARCHIVE" ] || fail "$(L "--slsteam-archive does not exist: $SLSSTEAM_ARCHIVE" "--slsteam-archive não existe: $SLSSTEAM_ARCHIVE")"
		dir="$TMP_ROOT/slssteam-archive"
		extract_archive "$SLSSTEAM_ARCHIVE" "$dir" || fail "$(L "Could not extract $SLSSTEAM_ARCHIVE" "Não foi possível extrair $SLSSTEAM_ARCHIVE")"
		dir="$(find "$dir" -maxdepth 3 -name SLSsteam.so -printf '%h\n' 2>/dev/null | head -n1)"
		[ -n "$dir" ] || fail "$(L "SLSsteam.so not found inside $SLSSTEAM_ARCHIVE" "SLSsteam.so não encontrado dentro de $SLSSTEAM_ARCHIVE")"
		SLSSTEAM_BIN="$dir"
		verify_slssteam_bin "$SLSSTEAM_BIN"
		return 0
	fi

	autodetect_slssteam_src
	if [ -z "$SLSSTEAM_SRC" ]; then
		clone_slssteam || true
	fi
	build_slssteam
	verify_slssteam_bin "$SLSSTEAM_BIN"
}

install_slssteam() {
	log_info "$(L "Installing SLSsteam into $SLSDIR" "Instalando o SLSsteam em $SLSDIR")"
	mkdir -p "$SLSDIR" "$SDIR" || fail "$(L "Could not create $SLSDIR" "Não foi possível criar $SLSDIR")"
	# The binaries may already sit in SLSDIR (--slsteam-bin "$SLSDIR"); install(1) refuses same-file copies.
	if [ ! "$SLSSTEAM_BIN/SLSsteam.so" -ef "$SLSDIR/SLSsteam.so" ]; then
		install -m 0755 "$SLSSTEAM_BIN/SLSsteam.so" "$SLSDIR/SLSsteam.so" || fail "$(L "Could not install SLSsteam.so" "Não foi possível instalar o SLSsteam.so")"
	fi
	if [ ! "$SLSSTEAM_BIN/library-inject.so" -ef "$SLSDIR/library-inject.so" ]; then
		install -m 0755 "$SLSSTEAM_BIN/library-inject.so" "$SLSDIR/library-inject.so" 2>/dev/null || \
			: > "$SLSDIR/library-inject.so"
	fi

	# Seed the full default config before Steam's first launch so the config
	# exists with every key SLSsteam expects. The prebuilt bundle ships the same
	# file next to SLSsteam.so; without it SLSsteam falls back to defaults where
	# DisableUpdates is true, which blocks installing managed apps.
	local config_seed=""
	if [ -f "$SLSSTEAM_SRC/res/config.yaml" ]; then
		config_seed="$SLSSTEAM_SRC/res/config.yaml"
	elif [ -f "$SLSSTEAM_BIN/config.yaml" ]; then
		config_seed="$SLSSTEAM_BIN/config.yaml"
	fi
	if [ ! -f "$CONFIG_FILE" ] && [ -n "$config_seed" ]; then
		mkdir -p "$CONFIG_DIR"
		cp -f "$config_seed" "$CONFIG_FILE" || true
		log_info "$(L "Seeded the default SLSsteam config" "Config padrão do SLSsteam criada")"
	fi
	log_success "$(L "SLSsteam installed" "SLSsteam instalado")"
}

# Remove older stack pieces while keeping user config and our backups.
cleanup_previous() {
	local keep
	[ -d "$SLSDIR" ] || return 0
	while IFS= read -r -d '' keep; do
		case "${keep##*/}" in
			backup|system-launcher-backup) continue ;;
		esac
		rm -rf -- "$keep" 2>/dev/null || true
	done < <(find "$SLSDIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
	log_info "$(L "Previous binaries and wrappers removed" "Binários e wrappers anteriores removidos")"
}

# ----------------------------------------------------------------------------
# Lumen
# ----------------------------------------------------------------------------
install_lumen_files() {
	local bin="$1" lua_src="$2"
	[ -f "$bin" ] || fail "$(L "lumen binary not found at $bin" "binário lumen não encontrado em $bin")"
	[ -d "$lua_src" ] || fail "$(L "lua/ not found at $lua_src (Lumen needs its Lua runtime tree)" "lua/ não encontrado em $lua_src (o Lumen precisa da árvore Lua)")"
	elf_ok "$bin" "$ARCH" || fail "$(L \
		"$bin is not a $ARCH ELF. Rebuild Lumen on this machine or pass a matching --lumen-archive." \
		"$bin não é um ELF $ARCH. Recompile o Lumen nesta máquina ou passe um --lumen-archive compatível.")"

	mkdir -p "$LUMEN_DIR" || fail "$(L "Could not create $LUMEN_DIR" "Não foi possível criar $LUMEN_DIR")"
	install -m 0755 "$bin" "$LUMEN_DIR/lumen" || fail "$(L "Could not install the Lumen binary" "Não foi possível instalar o binário do Lumen")"
	rm -rf "$LUMEN_DIR/lua"
	cp -a "$lua_src" "$LUMEN_DIR/lua" || fail "$(L "Could not copy Lumen's lua/ tree" "Não foi possível copiar a árvore lua/ do Lumen")"

	# NixOS has no FHS loader path for a normally built ELF.
	if is_nixos; then
		if ! have steam-run; then
			log_warn "$(L "steam-run not found; Lumen may not start on NixOS" "steam-run não encontrado; o Lumen pode não iniciar no NixOS")"
		else
			mv -f "$LUMEN_DIR/lumen" "$LUMEN_DIR/lumen.bin"
			printf '%s\n' '#!/usr/bin/env bash' 'exec steam-run "$(dirname "$0")/lumen.bin" "$@"' > "$LUMEN_DIR/lumen"
			chmod +x "$LUMEN_DIR/lumen"
		fi
	fi
	log_success "$(L "Lumen installed" "Lumen instalado")"
}

# Lumen links Lua 5.4 statically. Without a system Lua 5.4 the pinned tarball is
# built into a private liblua.a and handed to Lumen's Makefile via LUMEN_MAKE_ARGS.
LUMEN_MAKE_ARGS=()
ensure_lua54() {
	local lsrc
	LUMEN_MAKE_ARGS=()
	if pkg-config --exists lua5.4 2>/dev/null || [ -f /usr/include/lua5.4/lua.h ]; then
		return 0
	fi
	log_info "$(L "Building Lua $LUA_VERSION privately (no lua5.4 development package)" \
	             "Compilando o Lua $LUA_VERSION em separado (sem o pacote de desenvolvimento lua5.4)")"
	download "$LUA_URL" "$TMP_ROOT/lua.tar.gz" || fail "$(L "Could not download Lua $LUA_VERSION" "Não foi possível baixar o Lua $LUA_VERSION")"
	verify_sha256 "$TMP_ROOT/lua.tar.gz" "$LUA_SHA256" || fail "$(L \
		"The Lua archive does not match its pinned checksum." \
		"O arquivo do Lua não corresponde ao checksum fixado.")"
	extract_archive "$TMP_ROOT/lua.tar.gz" "$TMP_ROOT/lua" || fail "$(L "Could not extract the Lua archive" "Não foi possível extrair o arquivo do Lua")"
	lsrc="$TMP_ROOT/lua/lua-$LUA_VERSION/src"
	make -C "$lsrc" a SYSCFLAGS="-DLUA_USE_LINUX" >/dev/null || fail "$(L "Building Lua $LUA_VERSION failed" "O build do Lua $LUA_VERSION falhou")"
	LUMEN_MAKE_ARGS=("LUA_CFLAGS=-I$lsrc" "LUA_A=$lsrc/liblua.a")
}

# The aarch64 patch for the pinned Lumen commit, printed byte for byte.
lumen_patch_content() {
	cat <<'LUMEN_PATCH'
diff --git a/lua/about.lua b/lua/about.lua
index 231ccef..aab418e 100644
--- a/lua/about.lua
+++ b/lua/about.lua
@@ -45,8 +45,9 @@ about.MIRROR_MANIFEST_URL =
 
 -- The public one-liner the Update All button runs in a terminal. Raw-branch URL
 -- (not a release asset) so installer fixes go live without a rebuild.
+-- aarch64 stack: run the installer copy that was left in the Lumen directory.
 about.INSTALL_URL =
-  "https://raw.githubusercontent.com/swwayps/luatools-moon/main/install.sh"
+  "file://" .. (os.getenv("HOME") or "") .. "/.local/share/Lumen/install.sh"
 
 -- Where the installer stamps the installed release tags.
 function about.versions_path()
diff --git a/lua/loop.lua b/lua/loop.lua
index 2347c91..400344c 100644
--- a/lua/loop.lua
+++ b/lua/loop.lua
@@ -67,7 +67,8 @@ function loop.run(opts)
         log("autostart entry changed/vanilla -> re-asserting desktop coverage")
         deskcover.run("--user")
       end
-      local steam_alive = proc.is_alive("steam")
+      -- aarch64 Steam runs as `steam.real` behind the SLSsteam launcher wrapper.
+      local steam_alive = proc.is_alive("steam") or proc.is_alive("steam.real")
       local should_exit, steam_returned =
         watcher:should_exit(now, steam_alive)
       if steam_returned then
diff --git a/lua/restart_steam.sh b/lua/restart_steam.sh
index d59ec3a..ec30d20 100644
--- a/lua/restart_steam.sh
+++ b/lua/restart_steam.sh
@@ -61,6 +61,19 @@ fi
 # Desktop sessions require the slsteam-moon wrapper. Never close Steam when the
 # only relaunch option would omit SLSsteam/Lumen injection.
 LAUNCHER="$HOME/.local/share/SLSsteam/path/steam"
+# The Steam Runtime launcher is already the SLSsteam wrapper, so the distro
+# launcher starts SLSsteam and Lumen when the slsteam-moon path is absent.
+if [ ! -x "$LAUNCHER" ] && [ -x /usr/bin/steam ]; then
+  for rt_launcher in \
+    "$HOME/.local/share/Steam/steamrtarm64/steam" \
+    "$HOME/.steam/steam/steamrtarm64/steam"; do
+    if [ -f "$rt_launcher" ] \
+        && head -c 200 "$rt_launcher" 2>/dev/null | grep -q 'SLSsteam launcher wrapper'; then
+      LAUNCHER=/usr/bin/steam
+      break
+    fi
+  done
+fi
 if [ ! -x "$LAUNCHER" ]; then
   if [ -n "${SLS_RESTART_DRYRUN:-}" ]; then echo "desktop:none"; fi
   exit 1
@@ -101,9 +114,9 @@ if [ -f "$BOOTSTRAP_LOG" ]; then
 fi
 
 restart_outcome="already-gone"
-if pgrep -x steam >/dev/null 2>&1; then
+if pgrep -x '(steam|steam\.real)' >/dev/null 2>&1; then
   restart_outcome="escalated"
-  pkill -TERM -x steam >/dev/null 2>&1 || true
+  pkill -TERM -x '(steam|steam\.real)' >/dev/null 2>&1 || true
 
   grace="${SLS_RESTART_GRACE_SECS:-15}"
   case "$grace" in
@@ -121,7 +134,7 @@ if pgrep -x steam >/dev/null 2>&1; then
           | grep -q 'Shutdown'; then
         restart_outcome="clean"
       fi
-      if ! pgrep -x steam >/dev/null 2>&1; then
+      if ! pgrep -x '(steam|steam\.real)' >/dev/null 2>&1; then
         [ "$restart_outcome" = "escalated" ] && restart_outcome="already-gone"
         break
       fi
@@ -129,8 +142,8 @@ if pgrep -x steam >/dev/null 2>&1; then
     done
   fi
 
-  if pgrep -x steam >/dev/null 2>&1; then
-    pkill -KILL -x steam >/dev/null 2>&1 || true
+  if pgrep -x '(steam|steam\.real)' >/dev/null 2>&1; then
+    pkill -KILL -x '(steam|steam\.real)' >/dev/null 2>&1 || true
     restart_outcome="escalated"
   fi
 fi
@@ -143,7 +156,7 @@ printf '%s %s\n' "$(date '+%F %T' 2>/dev/null || printf unknown)" \
 # This polling exists only inside an explicit restart; it is not part of
 # Lumen's steady-state loop.
 for _ in $(seq 1 75); do
-  if ! pgrep -x steam >/dev/null 2>&1 \
+  if ! pgrep -x '(steam|steam\.real)' >/dev/null 2>&1 \
       && ! pgrep -f 'steamwebhelper' >/dev/null 2>&1 \
       && ! pgrep -f '/steam.sh([[:space:]]|$)' >/dev/null 2>&1 \
       && ! pgrep -f 'srt-logger' >/dev/null 2>&1; then
@@ -152,7 +165,7 @@ for _ in $(seq 1 75); do
   sleep 0.2
 done
 
-if pgrep -x steam >/dev/null 2>&1 \
+if pgrep -x '(steam|steam\.real)' >/dev/null 2>&1 \
     || pgrep -f 'steamwebhelper' >/dev/null 2>&1 \
     || pgrep -f '/steam.sh([[:space:]]|$)' >/dev/null 2>&1 \
     || pgrep -f 'srt-logger' >/dev/null 2>&1; then
diff --git a/lua/slscheck.lua b/lua/slscheck.lua
index 2f3c8de..238fe41 100644
--- a/lua/slscheck.lua
+++ b/lua/slscheck.lua
@@ -24,13 +24,17 @@ local slscheck = {}
 -- its address space. slsteam-moon loads via LD_AUDIT at preinit, so by the time
 -- the moon button anchors it is definitely mapped if the session is injected.
 slscheck.STEAM_COMM = "steam"
+-- aarch64 Steam is exec'd as `steam.real` by the SLSsteam launcher wrapper.
+slscheck.STEAM_COMMS = { "steam", "steam.real" }
 slscheck.LIB_NEEDLE = "SLSsteam.so"
 
 -- The auto-fix script, served from the slsteam-moon repo's raw branch URL (like
 -- install.sh) so fixes go live without cutting a new release. The main line is
 -- the branch literally named `slsteam-moon`.
+-- The aarch64 stack repairs itself with the installer copy it leaves in the Lumen
+-- directory; the upstream script would install the 32-bit x86 slsteam-moon.
 slscheck.AUTOFIX_URL =
-  "https://raw.githubusercontent.com/swwayps/slsteam-moon/slsteam-moon/autofix.sh"
+  "file://" .. (os.getenv("HOME") or "") .. "/.local/share/Lumen/install.sh"
 
 -- Single-quote a token for safe POSIX-shell interpolation.
 local function shq(s)
@@ -42,7 +46,12 @@ end
 function slscheck.is_loaded(opts)
   opts = opts or {}
   local mapped = opts.mapped
-    or function() return proc.lib_mapped(slscheck.STEAM_COMM, slscheck.LIB_NEEDLE) end
+    or function()
+      for _, comm in ipairs(slscheck.STEAM_COMMS) do
+        if proc.lib_mapped(comm, slscheck.LIB_NEEDLE) then return true end
+      end
+      return false
+    end
   return mapped() and true or false
 end
 
diff --git a/lua/slsconfig.lua b/lua/slsconfig.lua
index df167f6..00a5fc9 100644
--- a/lua/slsconfig.lua
+++ b/lua/slsconfig.lua
@@ -26,14 +26,18 @@ local write_seq = 0
 -- longer disables it; the Steam wrapper crash-loop fail-safe covers that now),
 -- so exposing a switch that does nothing would only confuse.
 slsconfig.SCHEMA = {
+  -- Hidden: the native SLSsteam does not read these keys (toggles would do nothing).
   { key = "PlayNotOwnedGames",      type = "bool",   default = false, level = "info",
+    hidden = true,
     label = "Play not-owned games" },
   { key = "DisableFamilyShareLock", type = "bool",   default = true,  level = "normal",
     label = "Disable Family Share lock" },
   { key = "DisableParentalRestrictions", type = "bool", default = false, level = "normal",
     restart_on_change = true,
+    hidden = true,
     label = "Disable parental restrictions" },
   { key = "AutoFilterList",         type = "bool",   default = true,  level = "advanced",
+    hidden = true,
     label = "Auto-filter app list" },
   { key = "UseWhitelist",           type = "bool",   default = false, level = "danger",
     label = "Use whitelist (instead of blacklist)" },
@@ -41,6 +45,7 @@ slsconfig.SCHEMA = {
     hidden = true,
     label = "Safe mode (disable on unknown steamclient)" },
   { key = "Notifications",          type = "bool",   default = true,  level = "normal",
+    hidden = true,
     label = "Notifications (notify-send)" },
   { key = "NotifyInit",             type = "bool",   default = true,  level = "normal",
     label = "Notify on init" },
@@ -61,6 +66,7 @@ slsconfig.SCHEMA = {
     min = 0, max = 2147483647,
     label = "Fake wallet balance (0 = off)" },
   { key = "LogLevel",               type = "enum",   default = 2,     level = "advanced",
+    hidden = true,
     label = "Log level",
     options = { 0, 1, 2, 3, 4, 5, 6 },
     option_labels = { "Once (0)", "Debug (1)", "Info (2)", "NotifyShort (3)",
diff --git a/tools/test_restart_steam.sh b/tools/test_restart_steam.sh
index d46a5e3..10217a0 100644
--- a/tools/test_restart_steam.sh
+++ b/tools/test_restart_steam.sh
@@ -92,7 +92,7 @@ cat >"$TMP/bin/pkill" <<'SCRIPT'
 #!/usr/bin/env bash
 printf 'pkill %s\n' "$*" >>"$TEST_EVENTS"
 case "$*" in
-  '-TERM -x steam')
+  '-TERM -x (steam|steam\.real)')
     if [[ "${TEST_MODE:-}" == clean ]]; then
       printf '%s\n' Shutdown >>"$TEST_BOOTSTRAP_LOG"
       rm -f "$TEST_STATE"
@@ -100,7 +100,7 @@ case "$*" in
       printf '%s\n' Shutdown >>"$TEST_BOOTSTRAP_LOG"
     fi
     ;;
-  '-KILL -x steam')
+  '-KILL -x (steam|steam\.real)')
     [[ "${TEST_MODE:-}" != unkillable ]] && rm -f "$TEST_STATE"
     ;;
 esac
@@ -108,7 +108,7 @@ SCRIPT
 chmod +x "$TMP/bin/pkill"
 cat >"$TMP/bin/pgrep" <<'SCRIPT'
 #!/usr/bin/env bash
-if [[ "${1:-}" == -x && "${2:-}" == steam ]]; then
+if [[ "${1:-}" == -x && "${2:-}" == '(steam|steam\.real)' ]]; then
   [[ -e "$TEST_STATE" ]] && exit 0 || exit 1
 fi
 if [[ "${1:-}" == -f ]]; then
@@ -146,11 +146,11 @@ run_restart() {
 }
 
 run_restart clean 1
-grep -q '^pkill -TERM -x steam$' "$EVENTS" || {
+grep -Fxq 'pkill -TERM -x (steam|steam\.real)' "$EVENTS" || {
   echo "FAIL: clean restart did not request TERM first" >&2
   exit 1
 }
-if grep -q '^pkill -KILL -x steam$' "$EVENTS"; then
+if grep -Fxq 'pkill -KILL -x (steam|steam\.real)' "$EVENTS"; then
   echo "FAIL: clean Shutdown observation unnecessarily escalated" >&2
   exit 1
 fi
@@ -167,11 +167,11 @@ grep -q '^launcher$' "$EVENTS" || {
 printf '%s\n' before >"$BOOTSTRAP_LOG"
 printf '%s\n' alive >"$STATE"
 run_restart shutdown-stuck 1
-grep -q '^pkill -TERM -x steam$' "$EVENTS" || {
+grep -Fxq 'pkill -TERM -x (steam|steam\.real)' "$EVENTS" || {
   echo "FAIL: stuck-clean restart did not request TERM first" >&2
   exit 1
 }
-grep -q '^pkill -KILL -x steam$' "$EVENTS" || {
+grep -Fxq 'pkill -KILL -x (steam|steam\.real)' "$EVENTS" || {
   echo "FAIL: Shutdown observation with a live Steam process did not escalate" >&2
   exit 1
 }
@@ -197,11 +197,11 @@ if grep -q '^launcher$' "$EVENTS"; then
   exit 1
 fi
 
-grep -q '^pkill -TERM -x steam$' "$EVENTS" || {
+grep -Fxq 'pkill -TERM -x (steam|steam\.real)' "$EVENTS" || {
   echo "FAIL: fallback restart did not request TERM first" >&2
   exit 1
 }
-grep -q '^pkill -KILL -x steam$' "$EVENTS" || {
+grep -Fxq 'pkill -KILL -x (steam|steam\.real)' "$EVENTS" || {
   echo "FAIL: fallback restart did not escalate to KILL" >&2
   exit 1
 }
@@ -232,7 +232,7 @@ rm -f "$STEAM_SH_STATE"
 printf '%s\n' before >"$BOOTSTRAP_LOG"
 rm -f "$STATE"
 run_restart already-gone 1
-if grep -q '^pkill -TERM -x steam$\|^pkill -KILL -x steam$' "$EVENTS"; then
+if grep -Fxq -e 'pkill -TERM -x (steam|steam\.real)' -e 'pkill -KILL -x (steam|steam\.real)' "$EVENTS"; then
   echo "FAIL: already-gone restart sent a client signal" >&2
   exit 1
 fi
@@ -268,7 +268,7 @@ grep -q '^sync$' "$RESTART_SH" || {
   echo "FAIL: restart helper does not flush pending filesystem writes" >&2
   exit 1
 }
-grep -q 'pkill -TERM -x steam' "$RESTART_SH" || {
+grep -Fq "pkill -TERM -x '(steam|steam\.real)'" "$RESTART_SH" || {
   echo "FAIL: restart helper has no TERM-first client shutdown" >&2
   exit 1
 }
diff --git a/tools/test_slscheck.lua b/tools/test_slscheck.lua
index 2821d4a..1410dfb 100644
--- a/tools/test_slscheck.lua
+++ b/tools/test_slscheck.lua
@@ -74,8 +74,8 @@ do
   check("script fetches autofix url", s:find(slscheck.AUTOFIX_URL, 1, true) ~= nil)
   check("script pipes to bash", s:find("| bash", 1, true) ~= nil)
   check("script pauses only on failure", s:find('status" %-ne 0') ~= nil)
-  check("autofix url points at slsteam-moon raw branch",
-    slscheck.AUTOFIX_URL:find("swwayps/slsteam%-moon/slsteam%-moon/autofix%.sh") ~= nil)
+  check("autofix url points at the local installer copy",
+    slscheck.AUTOFIX_URL:find("/.local/share/Lumen/install.sh", 1, true) ~= nil)
 end
 
 -- ── run_autofix orchestration (injected effects) ─────────────────────────────
diff --git a/tools/test_slsconfig.lua b/tools/test_slsconfig.lua
index 49e4537..785b045 100644
--- a/tools/test_slsconfig.lua
+++ b/tools/test_slsconfig.lua
@@ -63,14 +63,14 @@ do
   assert_eq(v.LogLevel,     2,     "LogLevel read")
 end
 
--- ── parental unlock is a visible, independent bool ─────────────────────────
+-- ── parental unlock is an independent bool, hidden on aarch64 ──────────────
 do
   local entry
   for _, e in ipairs(slsconfig.SCHEMA) do
     if e.key == "DisableParentalRestrictions" then entry = e end
   end
   assert_true(entry ~= nil, "parental unlock is present in SCHEMA")
-  assert_eq(entry.hidden, nil, "parental unlock is visible")
+  assert_eq(entry.hidden, true, "parental unlock flagged hidden (native SLSsteam ignores it)")
   assert_eq(entry.type, "bool", "parental unlock is a bool")
   assert_eq(entry.default, false, "parental unlock defaults off")
 
diff --git a/tools/test_slsmenu.lua b/tools/test_slsmenu.lua
index 2930895..4841844 100644
--- a/tools/test_slsmenu.lua
+++ b/tools/test_slsmenu.lua
@@ -34,7 +34,8 @@ do
   for _, entry in ipairs(res.schema) do
     if entry.key == "DisableParentalRestrictions" then parental = entry end
   end
-  assert_true(parental ~= nil and not parental.hidden, "parental unlock is visible")
+  assert_true(parental ~= nil and parental.hidden == true,
+              "parental unlock flagged hidden (native SLSsteam ignores it)")
   assert_eq(parental.restart_on_change, true,
             "parental unlock asks for a restart after either state change")
   os.remove(p)
LUMEN_PATCH
}

# Build or unpack Lumen without touching the installed copy.
LUMEN_BIN_FILE=""
LUMEN_LUA_SRC=""
prepare_lumen() {
	local dir src patch_file
	if [ -n "$LUMEN_ARCHIVE" ]; then
		[ -f "$LUMEN_ARCHIVE" ] || fail "$(L "--lumen-archive does not exist: $LUMEN_ARCHIVE" "--lumen-archive não existe: $LUMEN_ARCHIVE")"
		dir="$TMP_ROOT/lumen-archive"
		extract_archive "$LUMEN_ARCHIVE" "$dir" || fail "$(L "Could not extract the Lumen archive" "Não foi possível extrair o arquivo do Lumen")"
		src="$(find "$dir" -maxdepth 2 -name lumen -type f -printf '%h\n' 2>/dev/null | head -n1)"
		[ -n "$src" ] || fail "$(L "lumen binary not found inside the archive" "binário lumen não encontrado no arquivo")"
		LUMEN_BIN_FILE="$src/lumen"
		LUMEN_LUA_SRC="$src/lua"
		return 0
	fi

	if [ -n "$LUMEN_SRC" ]; then
		src="$LUMEN_SRC"
	else
		src="$TMP_ROOT/lumen"
		log_info "$(L "Fetching Lumen commit $LUMEN_REF" "Baixando o commit $LUMEN_REF do Lumen")"
		mkdir -p "$src" || fail "$(L "Could not create $src" "Não foi possível criar $src")"
		git -C "$src" init -q || fail "$(L "Could not initialise the Lumen checkout" "Não foi possível iniciar o checkout do Lumen")"
		git -C "$src" remote add origin "$LUMEN_REPO" || fail "$(L "Could not configure the Lumen remote" "Não foi possível configurar o remoto do Lumen")"
		git -C "$src" fetch -q --depth 1 origin "$LUMEN_REF" || fail "$(L "Could not fetch Lumen commit $LUMEN_REF" "Não foi possível baixar o commit $LUMEN_REF do Lumen")"
		git -C "$src" checkout -q FETCH_HEAD || fail "$(L "Could not check out Lumen commit $LUMEN_REF" "Não foi possível extrair o commit $LUMEN_REF do Lumen")"
	fi
	[ -f "$src/Makefile" ] || fail "$(L "$src does not look like the Lumen tree" "$src não parece ser a árvore do Lumen")"
	check_build_tools

	# The aarch64 patch: steam.real liveness and the local installer URL.
	patch_file="$TMP_ROOT/lumen-aarch64.patch"
	lumen_patch_content > "$patch_file" || fail "$(L "Could not write the Lumen patch" "Não foi possível gravar o patch do Lumen")"
	if git -C "$src" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
		log_success "$(L "Lumen aarch64 patch already applied" "Patch aarch64 do Lumen já aplicado")"
	elif git -C "$src" apply "$patch_file" >/dev/null 2>&1; then
		log_success "$(L "Lumen aarch64 patch applied" "Patch aarch64 do Lumen aplicado")"
	else
		fail "$(L \
			"The Lumen source does not match the pinned commit $LUMEN_REF, so the aarch64 patch (steam.real liveness, local installer URL) cannot be applied." \
			"O código do Lumen não corresponde ao commit fixado $LUMEN_REF, então o patch aarch64 (liveness do steam.real, URL local do instalador) não pode ser aplicado.")"
	fi

	ensure_lua54
	log_info "$(L "Building Lumen" "Compilando o Lumen")"
	( cd "$src" && make ${LUMEN_MAKE_ARGS[@]+"${LUMEN_MAKE_ARGS[@]}"} ) || fail "$(L \
		"Lumen build failed. Install the Lua 5.4 development package (liblua5.4-dev / lua54 / lua-devel) and the libcurl/OpenSSL headers." \
		"O build do Lumen falhou. Instale o pacote de desenvolvimento do Lua 5.4 (liblua5.4-dev / lua54 / lua-devel) e os headers de libcurl/OpenSSL.")"
	LUMEN_BIN_FILE="$src/bin/lumen"
	LUMEN_LUA_SRC="$src/lua"
}

resolve_lumen() {
	install_lumen_files "$LUMEN_BIN_FILE" "$LUMEN_LUA_SRC"
}

# ----------------------------------------------------------------------------
# LuaTools plugin
# ----------------------------------------------------------------------------
latest_plugin_url() {
	local json url
	if json="$(curl -fsSL --connect-timeout 15 --retry 2 \
		-H 'Accept: application/json' \
		"https://api.github.com/repos/$PLUGIN_REPO/releases/latest" 2>/dev/null)"; then
		url="$(printf '%s' "$json" | jq -r --arg n "$PLUGIN_ASSET" \
			'.assets[] | select(.name == $n) | .browser_download_url' 2>/dev/null | head -n1)"
		[ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
	fi
	if json="$(curl -fsSL --connect-timeout 15 --retry 2 "$MIRROR_MANIFEST" 2>/dev/null)"; then
		url="$(printf '%s' "$json" | jq -r '.components.plugin.url // empty' 2>/dev/null)"
		[ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
	fi
	return 1
}

# Replace the bundled x86-64 7zz with one that runs here.
setup_sevenzip() {
	local bin_dir="$1"
	if [ "$ARCH" != "aarch64" ]; then
		return 0
	fi
	mkdir -p "$bin_dir"

	if [ -n "$SEVENZIP" ]; then
		[ -x "$SEVENZIP" ] || fail "$(L "--sevenzip is not executable: $SEVENZIP" "--sevenzip não é executável: $SEVENZIP")"
		elf_ok "$SEVENZIP" aarch64 || fail "$(L "--sevenzip is not an aarch64 ELF" "--sevenzip não é um ELF aarch64")"
		install -m 0755 "$SEVENZIP" "$bin_dir/7zz"
		log_success "$(L "Bundled the provided aarch64 7zz" "7zz aarch64 fornecido foi embutido")"
		return 0
	fi

	if elf_ok "$SEVENZIP_CACHE" aarch64; then
		install -m 0755 "$SEVENZIP_CACHE" "$bin_dir/7zz"
		log_success "$(L "Reused the cached aarch64 7zz" "7zz aarch64 do cache reaproveitado")"
		return 0
	fi

	if elf_ok "$bin_dir/7zz" aarch64; then
		chmod +x "$bin_dir/7zz"
		log_success "$(L "Bundled 7zz already matches aarch64" "O 7zz embutido já é aarch64")"
		return 0
	fi

	log_info "$(L "Fetching an aarch64 7-Zip for .rar fixes" "Baixando um 7-Zip aarch64 para fixes .rar")"
	if download "$SEVENZIP_URL" "$TMP_ROOT/7z.tar.xz" 2>/dev/null && \
	   extract_archive "$TMP_ROOT/7z.tar.xz" "$TMP_ROOT/7z" 2>/dev/null && \
	   [ -f "$TMP_ROOT/7z/7zz" ]; then
		if elf_ok "$TMP_ROOT/7z/7zz" aarch64; then
			install -m 0755 "$TMP_ROOT/7z/7zz" "$bin_dir/7zz"
			mkdir -p "${SEVENZIP_CACHE%/*}" 2>/dev/null &&
				install -m 0755 "$TMP_ROOT/7z/7zz" "$SEVENZIP_CACHE" 2>/dev/null || true
			log_success "$(L "aarch64 7zz installed" "7zz aarch64 instalado")"
			return 0
		fi
	fi

	# A non-runnable bundled binary makes the downloader reject archives, so drop
	# it and let the patched downloader use a system 7z or unzip instead.
	rm -f "$bin_dir/7zz" 2>/dev/null || true
	log_warn "$(L "No aarch64 7zz available; .rar fixes stay disabled (zip still works)" \
	             "Sem 7zz aarch64; fixes .rar ficam desativados (zip continua funcionando)")"
}

# Make the downloader prefer any working 7z binary (bundled or system) and fall
# back to unzip instead of failing on a foreign-architecture binary.
patch_downloader() {
	local f="$1/scripts/downloader.sh" line block
	[ -f "$f" ] || return 0
	grep -qF 'LUATOOLS-ARCH-7ZZ' "$f" && return 0
	line="$(grep -nF 'SEVENZ="$SCRIPT_DIR/../bin/7zz"' "$f" | head -n1 | cut -d: -f1)"
	[ -n "$line" ] || return 0
	block="$f.block.$$"
	cat > "$block" <<'BLOCK'
  # LUATOOLS-ARCH-7ZZ: a bundled binary from another architecture must not be
  # run (it would fail the archive preflight). Prefer a working system 7z.
  if [ ! -x "$SEVENZ" ] || ! "$SEVENZ" i >/dev/null 2>&1; then
    for _luatools_7z in 7zz 7z 7za; do
      if command -v "$_luatools_7z" >/dev/null 2>&1 && "$_luatools_7z" i >/dev/null 2>&1; then
        SEVENZ="$(command -v "$_luatools_7z")"
        break
      fi
    done
  fi
  if [ ! -x "$SEVENZ" ] || ! "$SEVENZ" i >/dev/null 2>&1; then
    SEVENZ=""
  fi
BLOCK
	{ head -n "$line" "$f"; cat "$block"; tail -n +"$((line + 1))" "$f"; } > "$f.new" && mv "$f.new" "$f"
	rm -f "$block"
	chmod 0755 "$f" 2>/dev/null || true
}

# The aarch64 client runs as steam.real (its process name), so the restart helper
# must match that name as well. Only the "-x steam >" matches are rewritten.
patch_restart_steam() {
	local f="$1/scripts/restart_steam.sh"
	[ -f "$f" ] || return 0
	grep -qF 'LUATOOLS-ARCH-STEAMREAL' "$f" && return 0
	grep -qF -e '-x steam >' "$f" || return 0
	sed -e "s/-x steam >/-x '(steam|steam\\\\.real)' >/g" "$f" > "$f.new" \
		&& { head -n 1 "$f.new"; printf '%s\n' '# LUATOOLS-ARCH-STEAMREAL: matches the aarch64 client process steam.real as well'; tail -n +2 "$f.new"; } > "$f.tmp" \
		&& mv "$f.tmp" "$f"
	rm -f "$f.new" "$f.tmp"
	chmod 0755 "$f" 2>/dev/null || true
}

plugin_source_dir() {
	local d="$1"
	if [ -f "$d/plugin/plugin.json" ]; then printf '%s\n' "$d/plugin"; return 0; fi
	if [ -f "$d/plugin.json" ]; then printf '%s\n' "$d"; return 0; fi
	return 1
}

# Download/unpack the plugin without touching the installed copy.
PLUGIN_STAGE=""
PLUGIN_DATA_BAK=""
prepare_plugin() {
	local src url archive
	if [ -n "$PLUGIN_SRC" ]; then
		src="$(plugin_source_dir "$PLUGIN_SRC")" || fail "$(L \
			"--plugin-src has no plugin.json: $PLUGIN_SRC" \
			"--plugin-src não tem plugin.json: $PLUGIN_SRC")"
	else
		archive="$TMP_ROOT/$PLUGIN_ASSET"
		if [ -n "$PLUGIN_ARCHIVE" ]; then
			case "$PLUGIN_ARCHIVE" in
				https://*|http://*)
					log_info "$(L "Downloading the plugin" "Baixando o plugin")"
					download "$PLUGIN_ARCHIVE" "$archive" || fail "$(L "Could not download the plugin" "Não foi possível baixar o plugin")"
					verify_asset_sidecar "$PLUGIN_ARCHIVE" "$archive"
					;;
				*)
					cp -f "$PLUGIN_ARCHIVE" "$archive" || fail "$(L "Could not read $PLUGIN_ARCHIVE" "Não foi possível ler $PLUGIN_ARCHIVE")"
					;;
			esac
		else
			url="$(latest_plugin_url)" || fail "$(L "Could not resolve the LuaTools plugin release" "Não foi possível resolver a release do plugin LuaTools")"
			log_info "$(L "Downloading the plugin" "Baixando o plugin")"
			download "$url" "$archive" || fail "$(L "Could not download the plugin" "Não foi possível baixar o plugin")"
			verify_asset_sidecar "$url" "$archive"
		fi
		zip_is_safe "$archive" || fail "$(L "The plugin archive has unsafe entries" "O arquivo do plugin tem entradas inseguras")"
		src="$TMP_ROOT/plugin"
		extract_archive "$archive" "$src" || fail "$(L "Could not extract the plugin archive" "Não foi possível extrair o arquivo do plugin")"
		src="$(find "$src" -maxdepth 2 -name plugin.json -printf '%h\n' 2>/dev/null | head -n1)"
		[ -n "$src" ] || fail "$(L "plugin.json not found in the archive" "plugin.json não encontrado no arquivo")"
	fi
	PLUGIN_STAGE="$src"

	# Preserve settings and donated apps across updates.
	if [ -d "$PLUGIN_DIR/backend/data" ] || [ -f "$PLUGIN_DIR/backend/api.json" ]; then
		PLUGIN_DATA_BAK="$TMP_ROOT/plugin-data"
		mkdir -p "$PLUGIN_DATA_BAK"
		[ -d "$PLUGIN_DIR/backend/data" ] && cp -a "$PLUGIN_DIR/backend/data/." "$PLUGIN_DATA_BAK/" 2>/dev/null
		[ ! -f "$PLUGIN_DATA_BAK/api.json" ] && [ -f "$PLUGIN_DIR/backend/api.json" ] && cp -a "$PLUGIN_DIR/backend/api.json" "$PLUGIN_DATA_BAK/api.json" 2>/dev/null
	fi
}

install_plugin() {
	local stage
	[ -n "$PLUGIN_STAGE" ] || fail "$(L "The plugin was not prepared" "O plugin não foi preparado")"
	stage="$PLUGIN_DIR.new.$$"
	rm -rf "$stage"
	mkdir -p "$stage"
	cp -a "$PLUGIN_STAGE/." "$stage/" || fail "$(L "Could not stage the plugin files" "Não foi possível preparar os arquivos do plugin")"
	rm -rf "$stage/backend/data" "$stage/backend/temp_dl" 2>/dev/null || true

	if [ -n "$PLUGIN_DATA_BAK" ]; then
		mkdir -p "$stage/backend/data"
		cp -a "$PLUGIN_DATA_BAK/." "$stage/backend/data/" || fail "$(L "Could not restore the plugin data" "Não foi possível restaurar os dados do plugin")"
	fi

	setup_sevenzip "$stage/backend/bin"
	patch_downloader "$stage/backend"
	patch_restart_steam "$stage/backend"
	chmod +x "$stage"/backend/scripts/*.sh 2>/dev/null || true

	mkdir -p "$LUMEN_DIR"
	rm -rf "$PLUGIN_DIR.old.$$"
	if [ -d "$PLUGIN_DIR" ]; then
		mv "$PLUGIN_DIR" "$PLUGIN_DIR.old.$$" || fail "$(L "Could not replace the plugin" "Não foi possível substituir o plugin")"
	fi
	if ! mv "$stage" "$PLUGIN_DIR"; then
		[ -d "$PLUGIN_DIR.old.$$" ] && mv "$PLUGIN_DIR.old.$$" "$PLUGIN_DIR"
		fail "$(L "Could not activate the plugin" "Não foi possível ativar o plugin")"
	fi
	rm -rf "$PLUGIN_DIR.old.$$" 2>/dev/null || true
	log_success "$(L "LuaTools plugin installed" "Plugin LuaTools instalado")"
}

# Release tags for Lumen's About page. Written atomically; {} when no plugin version is known.
write_versions() {
	local ver="" tmp="$LUMEN_DIR/versions.json.tmp.$$"
	mkdir -p "$LUMEN_DIR" || return 0
	if [ -f "$PLUGIN_DIR/plugin.json" ] && have jq; then
		ver="$(jq -r '.version // empty' "$PLUGIN_DIR/plugin.json" 2>/dev/null)"
	fi
	rm -f "$tmp"
	if [ -n "$ver" ]; then jq -n --arg p "v$ver" '{plugin:$p}' > "$tmp" 2>/dev/null; fi
	[ -s "$tmp" ] || printf '{}\n' > "$tmp"
	mv -f "$tmp" "$LUMEN_DIR/versions.json" 2>/dev/null || rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# Steam wrapper, desktop entries and Game Mode
# ----------------------------------------------------------------------------
# Steam Runtime layout (aarch64): steamrtarm64/steam is replaced by the SLSsteam
# wrapper and the client runs as steamrtarm64/steam.real. Desktop and Game Mode both
# start that file, so no PATH entry or .desktop rewrite is needed.
steamrt_wrapper_is_ours() {
	[ -f "$1" ] && head -c 200 "$1" 2>/dev/null | grep -q "SLSsteam launcher wrapper"
}

write_steamrt_files() {
	mkdir -p "$SLSDIR" "$UNIT_DIR" || fail "$(L "Could not create $SLSDIR" "Não foi possível criar $SLSDIR")"
	cat > "$SLSDIR/steam-wrapper" <<'STEAM_WRAPPER'
#!/usr/bin/bash
# SLSsteam launcher wrapper (re-applied after Steam updates by slssteam-wrap.path)
SLS_SO="__SLSDIR__/SLSsteam.so"
SLS_INJECT="__SLSDIR__/library-inject.so"
LUMEN_DIR="__LUMEN_DIR__"
here="$(dirname "$(readlink -f "$0")")"
real="${here}/steam.real"
if [ ! -x "$real" ]; then
    echo "SLSsteam: steam.real missing, refusing to recurse" >&2
    exit 127
fi
# Lumen attaches over Steam's CEF DevTools endpoint and injects the LuaTools UI.
case " $* " in
    *" -shutdown "*) ;;
    *)
        for _cef in "$(dirname "$here")" "$HOME/.steam/steam"; do
            [ -d "$_cef" ] && touch "$_cef/.cef-enable-remote-debugging" 2>/dev/null
        done
        if [ -x "$LUMEN_DIR/lumen" ] && ! pgrep -f "$LUMEN_DIR/lumen" >/dev/null 2>&1; then
            env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH \
                LUMEN_BACKEND_DIR="$LUMEN_DIR/luatools/backend" \
                LUMEN_LUA_DIR="$LUMEN_DIR/lua" \
                setsid "$LUMEN_DIR/lumen" >"$LUMEN_DIR/lumen.log" 2>&1 < /dev/null &
        fi
        ;;
esac
if [ -f "$SLS_SO" ]; then
    audit="$SLS_SO"
    [ -s "$SLS_INJECT" ] && audit="$SLS_INJECT:$audit"
    export LD_AUDIT="$audit${LD_AUDIT:+:$LD_AUDIT}"
fi
# Desktop mode starts the client without -noverifyfiles. The size check then sees this
# wrapper instead of the real launcher, re-downloads the client, exits with 42 and
# nothing restarts it. Game Mode already passes the flag.
case " $* " in
    *" -noverifyfiles "*) ;;
    *) set -- "$@" -noverifyfiles ;;
esac
exec "$real" "$@"
STEAM_WRAPPER
	sed -i "s|__SLSDIR__|$SLSDIR|g; s|__LUMEN_DIR__|$LUMEN_DIR|g" "$SLSDIR/steam-wrapper"
	chmod 0755 "$SLSDIR/steam-wrapper" || fail "$(L "Could not chmod the wrapper" "Não foi possível ajustar o wrapper")"

	cat > "$SLSDIR/apply-wrap.sh" <<'APPLY_WRAP'
#!/usr/bin/bash
# Re-apply the SLSsteam wrapper to the Steam launcher after client updates.
# Idempotent: only touches the launcher when it is not already our wrapper.
set -u

STEAM_DIR="__STEAMRT_DIR__"
BIN="${STEAM_DIR}/steam"
REAL="${STEAM_DIR}/steam.real"
WRAPPER_SRC="__SLSDIR__/steam-wrapper"

[ -f "$WRAPPER_SRC" ] || { echo "SLSsteam: missing ${WRAPPER_SRC}" >&2; exit 0; }

is_wrapper() {
    [ -f "$1" ] && head -c 200 "$1" | grep -q "SLSsteam launcher wrapper"
}

if is_wrapper "$BIN"; then
    exit 0
fi

if [ -f "$BIN" ]; then
    mv -f "$BIN" "$REAL"
fi

install -m 0755 "$WRAPPER_SRC" "$BIN"
echo "SLSsteam: wrapper re-applied to ${BIN}"
APPLY_WRAP
	sed -i "s|__STEAMRT_DIR__|$STEAMRT_DIR|g; s|__SLSDIR__|$SLSDIR|g" "$SLSDIR/apply-wrap.sh"
	chmod 0755 "$SLSDIR/apply-wrap.sh" || fail "$(L "Could not chmod apply-wrap.sh" "Não foi possível ajustar o apply-wrap.sh")"

	cat > "$UNIT_DIR/slssteam-wrap.path" <<'WRAP_PATH'
[Unit]
Description=Watch Steam launcher directory for updates (SLSsteam)

[Path]
PathChanged=__STEAMRT_DIR__/steam
PathModified=__STEAMRT_DIR__

[Install]
WantedBy=default.target
WRAP_PATH
	sed -i "s|__STEAMRT_DIR__|$STEAMRT_DIR|g" "$UNIT_DIR/slssteam-wrap.path"

	cat > "$UNIT_DIR/slssteam-wrap.service" <<'WRAP_SERVICE'
[Unit]
Description=Re-apply SLSsteam launcher wrapper after Steam updates

[Service]
Type=oneshot
ExecStart=__SLSDIR__/apply-wrap.sh
WRAP_SERVICE
	sed -i "s|__SLSDIR__|$SLSDIR|g" "$UNIT_DIR/slssteam-wrap.service"
	log_success "$(L "Launcher wrapper and update watcher written" "Wrapper do launcher e vigia de atualizações gravados")"
}

install_wrap_units() {
	if ! have systemctl; then
		log_warn "$(L "systemctl not found; the wrapper is re-applied only by the next install" \
		             "systemctl não encontrado; o wrapper só é reaplicado na próxima instalação")"
		return 0
	fi
	if systemctl --user daemon-reload >/dev/null 2>&1 && \
	   systemctl --user enable --now slssteam-wrap.path >/dev/null 2>&1; then
		log_success "$(L "Update watcher enabled" "Vigia de atualizações ativado")"
	else
		log_warn "$(L "Could not enable slssteam-wrap.path; a Steam update may drop the wrapper until the next install" \
		             "Não foi possível ativar o slssteam-wrap.path; uma atualização da Steam pode remover o wrapper até a próxima instalação")"
	fi
}

install_steamrt_launcher() {
	[ -e "$STEAMRT_DIR/steam" ] || [ -e "$STEAMRT_DIR/steam.real" ] || fail "$(L \
		"No Steam launcher found in $STEAMRT_DIR." \
		"Nenhum launcher da Steam encontrado em $STEAMRT_DIR.")"
	write_steamrt_files
	# apply-wrap.sh leaves a launcher that is already ours alone, so a wrapper from an
	# older install would never receive the new content. Refresh it in place.
	if steamrt_wrapper_is_ours "$STEAMRT_DIR/steam" && [ -x "$STEAMRT_DIR/steam.real" ]; then
		install -m 0755 "$SLSDIR/steam-wrapper" "$STEAMRT_DIR/steam" || fail "$(L "Could not refresh the Steam launcher wrapper" "Não foi possível atualizar o wrapper do launcher da Steam")"
	else
		"$SLSDIR/apply-wrap.sh" >/dev/null || fail "$(L "Could not wrap the Steam launcher" "Não foi possível envolver o launcher da Steam")"
	fi
	steamrt_wrapper_is_ours "$STEAMRT_DIR/steam" || fail "$(L "The Steam launcher is not wrapped" "O launcher da Steam não foi envolvido")"
	log_success "$(L "Steam launcher wrapped: $STEAMRT_DIR/steam" "Launcher da Steam envolvido: $STEAMRT_DIR/steam")"
	install_wrap_units
}

# Armada OS exposes the FEX x86 rootfs through an overlay that can come up empty
# at boot (the lower squashfs mounts raced it). FEX then rejects every x86_64
# binary with "Invalid or Unsupported elf file" and games never start. Drop in a
# check that remounts the overlay once when it is empty.
install_fex_overlay_fix() {
	[ -f /usr/lib/systemd/system/armada-guestos.service ] || return 0
	[ -f /usr/share/fex-emu/RootFS/ArchLinux.sqsh ] || return 0
	[ -f /usr/share/fex-emu/RootFS/ArmadaMesa.sqsh ] || return 0

	local dir=/etc/systemd/system/armada-guestos.service.d
	local conf="$dir/verify-overlay.conf"
	local tmp="$TMP_ROOT/fex-overlay.conf"
	mkdir -p "$TMP_ROOT" 2>/dev/null || true
	cat > "$tmp" <<'FEX_OVERLAY'
[Service]
# The overlay can come up empty when the lower squashfs mounts are not visible
# yet; FEX then rejects every binary with "Invalid or Unsupported elf file".
# Verify the merged rootfs after start and remount once when it is empty.
ExecStartPost=/bin/sh -c 'n=$(ls /usr/share/guestos/fex-mesa 2>/dev/null | wc -l); if [ "$n" -eq 0 ]; then umount /usr/share/guestos/fex-mesa 2>/dev/null || true; mount -t overlay overlay -o ro,relatime,lowerdir=/run/armada/guestos/mesa:/run/armada/guestos/rootfs,redirect_dir=on /usr/share/guestos/fex-mesa; fi'
FEX_OVERLAY

	local sudo_c; sudo_c="$(sudo_cmd)"
	if [ -n "$sudo_c" ]; then
		$sudo_c mkdir -p "$dir" 2>/dev/null || { log_warn "$(L "Could not create $dir (FEX overlay fix skipped)" "Não foi possível criar $dir (fix do overlay FEX ignorado)")"; return 0; }
		$sudo_c install -m 0644 "$tmp" "$conf" 2>/dev/null || { log_warn "$(L "Could not install the FEX overlay fix" "Não foi possível instalar o fix do overlay FEX")"; return 0; }
	else
		mkdir -p "$dir" 2>/dev/null && install -m 0644 "$tmp" "$conf" 2>/dev/null || { log_warn "$(L "Could not install the FEX overlay fix" "Não foi possível instalar o fix do overlay FEX")"; return 0; }
	fi

	if have systemctl; then
		systemctl daemon-reload >/dev/null 2>&1 || true
	fi
	log_success "$(L "FEX overlay check installed" "Verificação do overlay FEX instalada")"
}

write_wrapper() {
	local wrapper="$SDIR/steam"
	mkdir -p "$SDIR" || fail "$(L "Could not create $SDIR" "Não foi possível criar $SDIR")"
	cat > "$wrapper" <<'WRAPPER'
#!/bin/sh
# LuaTools stack wrapper: injects SLSsteam through LD_AUDIT, starts the Lumen
# sidecar and then execs the real Steam binary.
SLSDIR="__SLSDIR__"
LUMEN_DIR="__LUMEN_DIR__"

slsm_strip_own_auditors() {
	_old_ifs="$IFS"; IFS=:
	_clean=""
	for _a in ${LD_AUDIT:-}; do
		case "$_a" in
			''|*SLSsteam.so|*library-inject.so) continue ;;
			*) _clean="${_clean:+$_clean:}$_a" ;;
		esac
	done
	IFS="$_old_ifs"
	printf '%s' "$_clean"
}
SLSM_INHERITED_AUDIT="$(slsm_strip_own_auditors)"
if [ -n "$SLSM_INHERITED_AUDIT" ]; then
	export LD_AUDIT="$SLSM_INHERITED_AUDIT"
else
	unset LD_AUDIT
fi

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
STEAM_BIN=""
if [ -n "${SLSM_STEAM_BIN:-}" ] && [ -x "$SLSM_STEAM_BIN" ] && \
   [ "$(readlink -f "$SLSM_STEAM_BIN" 2>/dev/null || echo "$SLSM_STEAM_BIN")" != "$SELF" ]; then
	STEAM_BIN="$SLSM_STEAM_BIN"
fi
if [ -z "$STEAM_BIN" ]; then
	for _c in /usr/games/steam /usr/bin/steam /usr/local/bin/steam; do
		if [ -x "$_c" ] && [ "$(readlink -f "$_c" 2>/dev/null || echo "$_c")" != "$SELF" ]; then
			STEAM_BIN="$_c"; break
		fi
	done
fi
if [ -z "$STEAM_BIN" ]; then
	IFS=:; for _d in $PATH; do
		_c="$_d/steam"
		if [ -x "$_c" ] && [ "$(readlink -f "$_c" 2>/dev/null || echo "$_c")" != "$SELF" ]; then
			STEAM_BIN="$_c"; break
		fi
	done; unset IFS
fi
if [ -z "$STEAM_BIN" ]; then
	for _c in "$HOME/.local/share/Steam/steam.sh" "$HOME/.steam/steam/steam.sh" "$HOME/.steam/debian-installation/steam.sh"; do
		if [ -x "$_c" ]; then STEAM_BIN="$_c"; break; fi
	done
fi
if [ -z "$STEAM_BIN" ]; then
	echo "LuaTools stack: could not find the real Steam binary" >&2
	exit 127
fi

# Lumen attaches over Steam's CEF DevTools endpoint.
for _cef in "$HOME/.steam/steam" "$HOME/.steam/debian-installation" "$HOME/.local/share/Steam"; do
	[ -d "$_cef" ] && touch "$_cef/.cef-enable-remote-debugging" 2>/dev/null
done

if [ -x "$LUMEN_DIR/lumen" ] && ! pgrep -f "$LUMEN_DIR/lumen" >/dev/null 2>&1; then
	env -u LD_AUDIT -u LD_PRELOAD -u LD_LIBRARY_PATH \
	    LUMEN_BACKEND_DIR="$LUMEN_DIR/luatools/backend" \
	    LUMEN_LUA_DIR="$LUMEN_DIR/lua" \
	    setsid "$LUMEN_DIR/lumen" >/dev/null 2>&1 < /dev/null &
fi

# CloudRedirect is x86-only; the file only exists on x86 installs.
CR_SO="$HOME/.local/share/CloudRedirect/cloud_redirect.so"
if [ -f "$CR_SO" ]; then
	export LD_PRELOAD="$CR_SO${LD_PRELOAD:+:$LD_PRELOAD}"
fi

AUDIT="$SLSDIR/SLSsteam.so"
if [ -s "$SLSDIR/library-inject.so" ]; then
	AUDIT="$SLSDIR/library-inject.so:$AUDIT"
fi
if [ -n "$SLSM_INHERITED_AUDIT" ]; then
	export LD_AUDIT="$AUDIT:$SLSM_INHERITED_AUDIT"
else
	export LD_AUDIT="$AUDIT"
fi
exec "$STEAM_BIN" "$@"
WRAPPER
	sed -i "s|__SLSDIR__|$SLSDIR|; s|__LUMEN_DIR__|$LUMEN_DIR|" "$wrapper"
	chmod 0755 "$wrapper" || fail "$(L "Could not chmod the wrapper" "Não foi possível ajustar o wrapper")"
	log_success "$(L "Steam wrapper written" "Wrapper da Steam escrito")"
}

# Rewrite an Exec= value from a desktop entry to run the wrapper.
rewrite_exec() {
	local value="$1" token clean out="" replaced=0
	set -f
	# shellcheck disable=SC2206
	local tokens=($value)
	set +f
	for token in "${tokens[@]}"; do
		if [ "$replaced" = 0 ]; then
			clean="${token%\"}"; clean="${clean#\"}"
			clean="${clean%\'}"; clean="${clean#\'}"
			case "${clean##*/}" in
				steam|steam-native|steam-runtime|steam-jupiter)
					token="\"$SDIR/steam\""
					replaced=1
					;;
			esac
		fi
		out="${out:+$out }$token"
	done
	[ "$replaced" = 1 ] || return 1
	printf '%s\n' "$out"
}

desktop_is_ours() {
	grep -qF "$SDIR/steam" "$1" 2>/dev/null
}

desktop_is_flatpak() {
	grep -qE 'Exec=.*(flatpak|snap)' "$1" 2>/dev/null
}

manifest_has() {
	[ -f "$MANIFEST" ] && grep -qF ":$1:" "$MANIFEST" 2>/dev/null
}

manifest_add() {
	local kind="$1" path="$2" backup="${3:-}"
	manifest_has "$path" && return 0
	mkdir -p "$BACKUP_DIR"
	printf '%s:%s:%s\n' "$kind" "$path" "$backup" >> "$MANIFEST"
}

patch_desktop_file() {
	local src="$1" target="$2" tmp exec_line new_exec kind="created" backup="" backup_name
	if [ -e "$target" ] && ! desktop_is_ours "$target"; then
		kind="modified"
		backup_name="$(printf '%s' "$target" | tr '/' '_')"
		mkdir -p "$DESKTOP_BACKUP"
		backup="$DESKTOP_BACKUP/$backup_name"
		cp -a "$target" "$backup" 2>/dev/null || return 1
	fi
	exec_line="$(grep -m1 '^Exec=' "$src" 2>/dev/null | sed 's/^Exec=//')"
	[ -n "$exec_line" ] || return 1
	new_exec="$(rewrite_exec "$exec_line")" || return 1

	mkdir -p "$(dirname "$target")" || return 1
	tmp="$target.tmp.$$"
	awk -v exec_new="Exec=$new_exec" '
		BEGIN { done = 0 }
		/^Exec=/ && !done { print exec_new; done = 1; next }
		{ print }
	' "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }

	manifest_add "$kind" "$target" "$backup"
	return 0
}

install_desktop_coverage() {
	local user_apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	local system_apps="${SYSTEM_APP_DIRS:-/usr/share/applications}"
	local system_autostart="${SYSTEM_AUTOSTART:-/etc/xdg/autostart/steam.desktop}"
	local candidates=() f base target
	local -A seen=()
	mkdir -p "$user_apps" "$BACKUP_DIR"

	# User entries first so a user override wins over the system copy.
	for f in "$user_apps"/*steam*.desktop \
	         "$system_apps/steam.desktop" \
	         "$system_apps/steam-native.desktop" \
	         "$system_apps/steam-runtime.desktop"; do
		[ -f "$f" ] || continue
		base="${f##*/}"
		case "$base" in
			*flatpak*|com.valvesoftware.Steam*|steamlink*|steam-link*) continue ;;
		esac
		desktop_is_flatpak "$f" && continue
		desktop_is_ours "$f" && continue
		[ -n "${seen[$base]:-}" ] && continue
		seen[$base]=1
		candidates+=("$f")
	done

	for f in "${candidates[@]}"; do
		base="${f##*/}"
		target="$user_apps/$base"
		if [ -e "$target" ] && desktop_is_ours "$target"; then
			continue
		fi
		if patch_desktop_file "$f" "$target"; then
			log_step "$(L "Desktop entry covered: $target" "Entrada .desktop coberta: $target")"
		fi
	done

	# Session autostart: the system entry launches Steam behind our back.
	if [ -f "$system_autostart" ] && ! desktop_is_flatpak "$system_autostart"; then
		target="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/steam.desktop"
		if ! desktop_is_ours "$target"; then
			if patch_desktop_file "$system_autostart" "$target"; then
				log_step "$(L "Autostart covered" "Autostart coberto")"
			fi
		fi
	fi

	if have update-desktop-database; then
		update-desktop-database "$user_apps" >/dev/null 2>&1 || true
	fi
	log_success "$(L "Desktop coverage applied" "Cobertura de desktop aplicada")"
}

gamemode_session_base() {
	local root base
	for root in /usr/share /etc; do
		for base in gamescope-session-plus gamescope-session; do
			if [ -f "$root/$base/sessions.d/steam" ] || [ -d "$root/$base/sessions.d" ]; then
				printf '%s' "$base"; return 0
			fi
		done
	done
	return 1
}

gamemode_clients() {
	local base="$1" root f name
	{
		printf 'steam\n'
		for root in /usr/share /etc; do
			for f in "$root/$base/sessions.d/"*; do
				[ -f "$f" ] || continue
				name="${f##*/}"
				case "$name" in *.bak.*|*.rpmnew|*.rpmsave|*~) continue ;; esac
				grep -qi steam "$f" 2>/dev/null || continue
				printf '%s\n' "$name"
			done
		done
	} | awk '!seen[$0]++'
}

gamemode_hook_content() {
	cat <<EOF
# managed-by: luatools-aarch64 (game-mode launcher hook)
_lt_wrapper="\$HOME/.local/share/SLSsteam/path/steam"
if [ -x "\$_lt_wrapper" ]; then
	_lt_cmd=""
	_lt_hit=0
	set -f
	for _lt_tok in \${STEAMCMD:-\${CLIENTCMD:-}}; do
		if [ "\$_lt_hit" = 0 ] && [ "\${_lt_tok##*/}" = steam ]; then
			_lt_tok="\$_lt_wrapper"
			_lt_hit=1
		fi
		_lt_cmd="\${_lt_cmd:+\$_lt_cmd }\$_lt_tok"
	done
	set +f
	if [ "\$_lt_hit" = 1 ]; then
		export STEAMCMD="\$_lt_cmd"
	elif [ -z "\${STEAMCMD:-}\${CLIENTCMD:-}" ]; then
		export STEAMCMD="\$_lt_wrapper"
	fi
	unset _lt_cmd _lt_hit _lt_tok
fi
unset _lt_wrapper
EOF
}

install_gamemode() {
	[ "$OPT_NO_GAMEMODE" = 1 ] && return 0
	local base cfg clients client hook wrote=0 unit_dir conf
	if ! gamemode_session_base >/dev/null 2>&1 && \
	   [ ! -f /usr/lib/systemd/user/steam-launcher.service ]; then
		return 0
	fi
	mkdir -p "$BACKUP_DIR" 2>/dev/null || true
	print_section "$(L "Game Mode" "Game Mode")"
	if ! prompt_yes_no "$(L "Enable the plugin in Game Mode too?" "Ativar o plugin também no Game Mode?")" "n"; then
		log_info "$(L "Game Mode skipped" "Game Mode ignorado")"
		return 0
	fi

	base="$(gamemode_session_base || true)"
	if [ -n "$base" ]; then
		cfg="${XDG_CONFIG_HOME:-$HOME/.config}/$base/sessions.d"
		mkdir -p "$cfg" || { log_warn "$(L "Could not create $cfg" "Não foi possível criar $cfg")"; return 0; }
		clients="$(gamemode_clients "$base")"
		for client in $clients; do
			hook="$cfg/$client"
			if [ -f "$hook" ] && ! grep -qF 'managed-by: luatools-aarch64' "$hook"; then
				mv -- "$hook" "$hook.bak.$(date +%s)" 2>/dev/null || true
			fi
			if gamemode_hook_content > "$hook"; then
				wrote=1
				printf '%s\n' "$hook" >> "$GAMEMODE_MANIFEST"
			fi
		done
		[ "$wrote" = 1 ] && log_success "$(L "Game Mode hook installed" "Hook do Game Mode instalado")"
		return 0
	fi

	# SteamOS launches Steam from its own user unit.
	if [ -f /usr/lib/systemd/user/steam-launcher.service ]; then
		unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/steam-launcher.service.d"
		conf="$unit_dir/luatools-aarch64.conf"
		mkdir -p "$unit_dir" || return 0
		cat > "$conf" <<'EOF'
[Service]
# managed-by: luatools-aarch64 (game-mode launcher hook)
ExecStart=
ExecStart=/bin/sh -c 'PATH="%h/.local/share/SLSsteam/path:$$PATH" exec /usr/lib/steamos/steam-launcher'
EOF
		printf '%s\n' "$conf" >> "$GAMEMODE_MANIFEST"
		have systemctl && systemctl --user daemon-reload >/dev/null 2>&1 || true
		log_success "$(L "Game Mode drop-in installed" "Drop-in do Game Mode instalado")"
	fi
}

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
uninstall_stack() {
	print_section "$(L "Uninstalling" "Desinstalando")"
	if [ -z "$ARCH" ]; then
		case "$(uname -m)" in aarch64|arm64) ARCH="aarch64" ;; esac
	fi
	detect_steamrt || true
	STEAM_BIN="$(find_native_steam 2>/dev/null || true)"
	stop_steam
	stop_lumen

	# Put the original Steam launcher back before SLSDIR (which holds the wrapper) is removed.
	if [ -n "$STEAMRT_DIR" ]; then
		if have systemctl; then
			systemctl --user disable --now slssteam-wrap.path >/dev/null 2>&1 || true
		fi
		rm -f "$UNIT_DIR/slssteam-wrap.path" "$UNIT_DIR/slssteam-wrap.service" 2>/dev/null || true
		if have systemctl; then
			systemctl --user daemon-reload >/dev/null 2>&1 || true
		fi
		if steamrt_wrapper_is_ours "$STEAMRT_DIR/steam" && [ -f "$STEAMRT_DIR/steam.real" ]; then
			mv -f "$STEAMRT_DIR/steam.real" "$STEAMRT_DIR/steam" || log_warn "$(L "Could not restore the Steam launcher from steam.real" "Não foi possível restaurar o launcher da Steam a partir do steam.real")"
		fi
	fi

	local kind path backup
	if [ -f "$MANIFEST" ]; then
		while IFS=: read -r kind path backup; do
			[ -n "$path" ] || continue
			case "$kind" in
				modified)
					if [ -n "$backup" ] && [ -f "$backup" ]; then
						cp -a "$backup" "$path" 2>/dev/null || true
					fi
					;;
				created) rm -f "$path" 2>/dev/null || true ;;
			esac
		done < "$MANIFEST"
	fi
	if [ -f "$GAMEMODE_MANIFEST" ]; then
		while IFS= read -r path; do
			[ -n "$path" ] && rm -f "$path" 2>/dev/null
		done < "$GAMEMODE_MANIFEST"
	fi

	rm -rf "$SLSDIR" 2>/dev/null || true
	rm -rf "$LUMEN_DIR" 2>/dev/null || true
	if [ "$OPT_PURGE" = 1 ]; then
		rm -rf "$CONFIG_DIR" 2>/dev/null || true
		log_info "$(L "SLSsteam config removed" "Config do SLSsteam removida")"
	fi
	log_success "$(L "Uninstall done" "Desinstalação concluída")"
}

# ----------------------------------------------------------------------------
# Final steps
# ----------------------------------------------------------------------------
# Lumen's Update All runs `curl file://.../install.sh | bash -s -- <flags>`, so the
# settings of the last install are read back from this file (only the keys below).
save_install_conf() {
	local tmp="$INSTALL_CONF.tmp.$$" key val
	mkdir -p "$LUMEN_DIR" 2>/dev/null || return 0
	{
		for key in SLSSTEAM_SRC SLSSTEAM_BIN SLSSTEAM_LIBS LUMEN_SRC PLUGIN_SRC LUMEN_REF LUMEN_ARCHIVE PLUGIN_ARCHIVE SEVENZIP; do
			val="${!key:-}"
			[ -n "$val" ] || continue
			case "$val" in *$'\n'*) continue ;; esac
			# SLSSTEAM_BIN is derived from SLSSTEAM_SRC by the build; the default ref is not a choice.
			[ "$key" = SLSSTEAM_BIN ] && [ -n "${SLSSTEAM_SRC:-}" ] && [ "$val" = "$SLSSTEAM_SRC/bin" ] && continue
			[ "$key" = LUMEN_REF ] && [ "$val" = "$LUMEN_REF_DEFAULT" ] && continue
			[ -n "$TMP_ROOT" ] && case "$val" in "$TMP_ROOT"*) continue ;; esac
			printf '%s=%s\n' "$key" "$val"
		done
	} > "$tmp" || { rm -f "$tmp"; return 0; }
	mv -f "$tmp" "$INSTALL_CONF" 2>/dev/null || rm -f "$tmp"
}

# Fills only the empty variables, so options given on this command line win.
load_install_conf() {
	local key val
	[ -f "$INSTALL_CONF" ] || return 0
	while IFS='=' read -r key val || [ -n "${key:-}" ]; do
		case "$key" in
			SLSSTEAM_SRC|SLSSTEAM_BIN|SLSSTEAM_LIBS|LUMEN_SRC|PLUGIN_SRC|LUMEN_REF|LUMEN_ARCHIVE|PLUGIN_ARCHIVE|SEVENZIP) ;;
			*) continue ;;
		esac
		[ -n "$val" ] || continue
		case "$val" in *$'\n'*) continue ;; esac
		[ -z "${!key:-}" ] || continue
		printf -v "$key" '%s' "$val"
	done < "$INSTALL_CONF"
}

# Offline bundle: the prebuilt artifacts may sit next to this script in
# artifacts/ (bundle folder) or in bundle/artifacts (copied under the Lumen dir).
detect_bundle_artifacts() {
	local self="${BASH_SOURCE[0]:-}" dir candidate
	[ -n "$self" ] && [ -f "$self" ] || return 0
	dir="$(cd "$(dirname "$self")" 2>/dev/null && pwd)" || return 0
	for candidate in "$dir/artifacts" "$dir/bundle/artifacts"; do
		[ -d "$candidate" ] || continue
		if [ -z "$SLSSTEAM_BIN" ] && [ -f "$candidate/slsteam/SLSsteam.so" ]; then
			SLSSTEAM_BIN="$candidate/slsteam"
		fi
		if [ -z "$LUMEN_ARCHIVE" ] && [ -f "$candidate/lumen.zip" ]; then
			LUMEN_ARCHIVE="$candidate/lumen.zip"
		fi
		if [ -z "$PLUGIN_ARCHIVE" ] && [ -f "$candidate/luatools-linux.zip" ]; then
			PLUGIN_ARCHIVE="$candidate/luatools-linux.zip"
		fi
		if [ -z "$SEVENZIP" ] && [ -x "$candidate/7zz" ]; then
			SEVENZIP="$candidate/7zz"
		fi
	done
}

# Lumen's Update All needs a local copy of this script in the Lumen directory.
install_self_copy() {
	local self="${BASH_SOURCE[0]:-}" dest="$LUMEN_DIR/install.sh" self_real dest_real
	if [ -n "$self" ] && [ -f "$self" ]; then
		self_real="$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")"
		dest_real="$(readlink -f "$dest" 2>/dev/null || printf '%s' "$dest")"
		if [ "$self_real" != "$dest_real" ]; then
			install -m 0755 "$self" "$dest" || log_warn "$(L "Could not copy the installer to $dest" "Não foi possível copiar o instalador para $dest")"
		fi
		return 0
	fi
	if [ ! -f "$dest" ]; then
		log_warn "$(L "Update All needs a copy of install.sh: run the installer from a file once, so $dest exists" \
		             "O Update All precisa de uma cópia do install.sh: rode o instalador a partir de um arquivo uma vez, para que $dest exista")"
	fi
}

print_complete() {
	echo ""
	echo "  ✓ $(L "Installation complete" "Instalação concluída")"
	echo ""
	echo "    SLSsteam: $SLSDIR  ($ARCH build)"
	echo "    Lumen:    $LUMEN_DIR"
	[ "$OPT_NOPLUGIN" = 1 ] || echo "    LuaTools: $PLUGIN_DIR"
	echo ""
	if [ "$ARCH" = "aarch64" ]; then
		echo "    $(L "CloudRedirect was skipped: it hooks the 32-bit x86 Steam client, which does not exist on aarch64." \
		                "CloudRedirect foi ignorado: ele injeta no cliente Steam x86 de 32 bits, que não existe no aarch64.")"
		echo ""
	fi
	if [ -n "$STEAMRT_DIR" ]; then
		echo "    $(L "Steam launcher wrapped: $STEAMRT_DIR/steam" "Launcher da Steam envolvido: $STEAMRT_DIR/steam")"
	else
		echo "    $(L "Start Steam through the wrapper: $SDIR/steam" "Inicie a Steam pelo wrapper: $SDIR/steam")"
	fi
	echo ""
}

autolaunch() {
	local launcher="$SDIR/steam"
	[ -n "$STEAMRT_DIR" ] && launcher="${STEAM_BIN:-$STEAMRT_DIR/steam}"
	[ "$OPT_NOLAUNCH" = 1 ] && return 0
	[ -n "${SLS_NO_LAUNCH:-}" ] && return 0
	[ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && return 0
	[ -x "$launcher" ] || return 0
	setsid nohup "$launcher" >/dev/null 2>&1 < /dev/null &
	log_info "$(L "Steam started" "Steam iniciada")"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
	detect_language
	load_install_conf
	if ! parse_args "$@"; then
		log_error "$(L "Unknown option: $OPT_BAD_ARG" "Opção desconhecida: $OPT_BAD_ARG")"
		usage
		exit 1
	fi
	if [ "$OPT_HELP" = 1 ]; then usage; exit 0; fi
	detect_bundle_artifacts
	LUMEN_REF="${LUMEN_REF:-$LUMEN_REF_DEFAULT}"
	if [ -z "${HOME:-}" ]; then fail "$(L "HOME is not set" "HOME não definida")"; fi

	print_banner
	read_os_release

	if [ "$(id -u)" -eq 0 ]; then
		fail "$(L "Do not run this installer as root." "Não rode este instalador como root.")"
	fi

	if [ "$OPT_UNINSTALL" = 1 ]; then
		uninstall_stack
		exit 0
	fi

	print_section "$(L "Pre-flight" "Verificações iniciais")"
	detect_arch
	check_runtime_tools
	check_steam
	check_millennium

	TMP_ROOT="$(mktemp -d)" || fail "$(L "Could not create a temporary directory" "Não foi possível criar um diretório temporário")"
	trap 'rm -rf "${TMP_ROOT:-}"' EXIT

	# Build/download everything BEFORE stopping Steam or deleting the working
	# install, so a compiler or network failure leaves the previous stack intact.
	print_section "$(L "Preparing SLSsteam" "Preparando o SLSsteam")"
	resolve_slssteam

	print_section "$(L "Preparing Lumen" "Preparando o Lumen")"
	prepare_lumen

	if [ "$OPT_NOPLUGIN" != 1 ]; then
		print_section "$(L "Preparing the LuaTools plugin" "Preparando o plugin LuaTools")"
		prepare_plugin
	fi

	print_section "$(L "Stopping Steam" "Parando a Steam")"
	stop_steam
	stop_lumen

	print_section "$(L "Cleaning up old files" "Limpando arquivos antigos")"
	# cleanup_previous wipes SLSDIR; in the Steam Runtime layout SLSDIR holds the launcher wrapper.
	if [ -z "$STEAMRT_DIR" ]; then
		cleanup_previous
	fi

	print_section "$(L "Installing SLSsteam" "Instalando o SLSsteam")"
	install_slssteam

	print_section "$(L "Installing Lumen" "Instalando o Lumen")"
	resolve_lumen

	if [ "$OPT_NOPLUGIN" = 1 ]; then
		print_section "$(L "LuaTools plugin (skipped)" "Plugin LuaTools (ignorado)")"
		rm -rf "$PLUGIN_DIR" 2>/dev/null || true
	else
		print_section "$(L "Installing the LuaTools plugin" "Instalando o plugin LuaTools")"
		install_plugin
	fi

	write_versions

	print_section "$(L "Wiring the Steam launcher" "Configurando o launcher da Steam")"
	if [ -n "$STEAMRT_DIR" ]; then
		install_steamrt_launcher
	else
		write_wrapper
		install_desktop_coverage
		install_gamemode
	fi

	install_fex_overlay_fix

	save_install_conf
	install_self_copy

	print_complete
	autolaunch
}

# Run the installer unless the file is sourced for tests.
if [ -z "${LUATOOLS_INSTALL_LIB_ONLY:-}" ]; then
	main "$@"
fi
