#!/bin/sh
# Install the Venom daemon on macOS or Linux from its public releases, then start it and open its
# dashboard:
#
#   curl -fsSL https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-daemon.sh | sh
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the archive
# against the release's SHA256SUMS before unpacking anything, and needs no root. The archive holds
# the launcher, the orchestrator, the dashboard and the Node.js runtime the dashboard runs on;
# nothing else is installed. Local models need Ollama, which the dashboard links to (you install it
# yourself).
#
#   VENOM_VERSION=0.2.0          install that version instead of the latest
#   VENOM_INSTALL_DIR            where releases are unpacked (default ~/.venom; they go in releases/)
#   VENOM_BIN_DIR                where the `venom-daemon` link goes (default $VENOM_INSTALL_DIR/bin)
#   VENOM_DAEMON_NO_START=1      install only: don't start the daemon
#   VENOM_DAEMON_NO_OPEN=1       start it, but don't open a browser
#
# It also adds the desktop launch entry (macOS: ~/Applications/Venom Daemon.app; Linux: an app
# launcher entry). The daemon keeps its data in ~/.venom/daemon. On Windows, use install-daemon.ps1.
set -eu

RELEASES="https://github.com/elishahbiz/venom-releases/releases"

say() { printf '%s\n' "$*"; }
err() {
	printf 'venom-daemon install: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || err "this installer needs '$1'"; }

fetch() { # url file
	curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$2" "$1" || err "download failed: $1"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		err "this installer needs sha256sum or shasum to check the download"
	fi
}

main() {
	need curl
	need tar
	need uname
	need mktemp

	case "$(uname -s)" in
	Darwin) os=darwin ;;
	Linux) os=linux ;;
	MINGW* | MSYS* | CYGWIN*) err "on Windows, run this in PowerShell instead: irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-daemon.ps1 | iex" ;;
	*) err "no daemon build for $(uname -s); there are builds for macOS, Linux and Windows" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) err "no daemon build for $(uname -m) on $os; there are builds for x64 and arm64" ;;
	esac
	if [ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
		arch=arm64
	fi
	if [ "$os" = linux ] && { [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; }; then
		err "the Linux builds need glibc; musl systems such as Alpine are not supported yet"
	fi

	install_dir="${VENOM_INSTALL_DIR:-$HOME/.venom}"
	bin_dir="${VENOM_BIN_DIR:-$install_dir/bin}"
	want=""
	if [ -n "${VENOM_VERSION:-}" ]; then
		want="${VENOM_VERSION#v}"
		printf '%s' "$want" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || err "VENOM_VERSION '$VENOM_VERSION' is not a version like 0.2.0"
		base="$RELEASES/download/v$want"
	else
		base="$RELEASES/latest/download"
	fi

	tmp="$(mktemp -d "${TMPDIR:-/tmp}/venom-daemon-install.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT INT TERM

	say "venom-daemon: finding the ${want:+v}${want:-latest} release for $os-$arch"
	fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
	line="$(grep -E "^[0-9a-f]{64}  venom-daemon-[0-9][0-9A-Za-z.-]*-$os-$arch\.tar\.gz\$" "$tmp/SHA256SUMS" | head -n 1 || true)"
	[ -n "$line" ] || err "the release has no daemon archive for $os-$arch"
	sum="${line%% *}"
	asset="${line##* }"
	name="${asset%.tar.gz}"
	version="${name#venom-daemon-}"
	version="${version%-"$os"-"$arch"}"
	say "venom-daemon: downloading $asset"
	fetch "$RELEASES/download/v$version/$asset" "$tmp/$asset"
	got="$(sha256_of "$tmp/$asset")"
	[ "$got" = "$sum" ] || err "checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed"
	say "venom-daemon: SHA256 verified ($sum)"

	mkdir -p "$tmp/unpack"
	tar -xzf "$tmp/$asset" -C "$tmp/unpack"
	[ -x "$tmp/unpack/venom-daemon/bin/venom-daemon" ] && [ -x "$tmp/unpack/venom-daemon/bin/orchestrator" ] ||
		err "$asset does not hold venom-daemon/bin/venom-daemon"

	# A running daemon (an older version) stops first; its data stays in ~/.venom/daemon.
	if [ -x "$bin_dir/venom-daemon" ]; then
		"$bin_dir/venom-daemon" stop >/dev/null 2>&1 || true
	fi

	mkdir -p "$install_dir/releases" "$bin_dir"
	dest="$install_dir/releases/$name"
	rm -rf "$dest"
	mv "$tmp/unpack/venom-daemon" "$dest"
	if [ "$os" = darwin ] && command -v xattr >/dev/null 2>&1; then
		xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
	fi
	ln -sf "$dest/bin/venom-daemon" "$bin_dir/venom-daemon"
	# Older daemon releases go; this one stays.
	for old in "$install_dir"/releases/venom-daemon-*; do
		[ -d "$old" ] && [ "$old" != "$dest" ] && [ -f "$old/.venom-daemon-home" ] && rm -rf "$old"
	done

	installed="$("$dest/bin/venom-daemon" version 2>&1)" || err "the installed venom-daemon did not run: $installed"
	"$dest/bin/venom-daemon" shortcut || say "venom-daemon: no desktop launch entry (start it with $bin_dir/venom-daemon)"
	# Start at login, if it was on, now points at this release.
	if "$dest/bin/venom-daemon" autostart status 2>/dev/null | grep -q 'true'; then
		"$dest/bin/venom-daemon" autostart on >/dev/null || true
	fi
	say ""
	say "Venom daemon $installed installed: $bin_dir/venom-daemon -> $dest"
	case "$os" in
	darwin) say "Launch it any time from Applications: Venom Daemon." ;;
	linux) say "Launch it any time from your app launcher: Venom Daemon." ;;
	esac

	if [ "${VENOM_DAEMON_NO_START:-}" = 1 ]; then
		say "Start it with: $bin_dir/venom-daemon"
		return
	fi
	open_flag=""
	if [ "${VENOM_DAEMON_NO_OPEN:-}" = 1 ] || { [ "$os" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }; then
		open_flag="--no-open"
	fi
	say ""
	"$dest/bin/venom-daemon" start $open_flag || err "the daemon did not start; see $bin_dir/venom-daemon logs"
	say ""
	say "Next, in the dashboard: install Ollama if it asks, then Connect to Venom Cloud with a join token"
	say "from https://cloud.usevenom.dev (Daemons, Connect a daemon). Docs: https://cloud.usevenom.dev/daemon"
}

main "$@"
