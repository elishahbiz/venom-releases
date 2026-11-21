#!/bin/sh
# Install the Petawork daemon (`petawork-daemon`, with `venom-daemon` as an alias) on macOS or Linux
# from its public releases, then start it and open its dashboard:
#
#   curl -fsSL https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-daemon.sh | sh
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the archive
# against the release's SHA256SUMS before unpacking anything, and needs no root. The archive holds
# the launcher, the orchestrator, the dashboard and the Node.js runtime the dashboard runs on;
# nothing else is installed. Local models need Ollama, which the dashboard links to (you install it
# yourself).
#
#   PETAWORK_VERSION=0.2.0          install that version instead of the latest
#   PETAWORK_INSTALL_DIR            where releases are unpacked (default ~/.venom; they go in releases/)
#   PETAWORK_BIN_DIR                where the `petawork-daemon` and `venom-daemon` links go
#                                   (default $PETAWORK_INSTALL_DIR/bin)
#   PETAWORK_DAEMON_NO_START=1      install only: don't start the daemon
#   PETAWORK_DAEMON_NO_OPEN=1       start it, but don't open a browser
#   PETAWORK_DAEMON_NO_AUTOSTART=1  don't turn on start at login
#   PETAWORK_DAEMON_NO_COMPUTERS=1  don't turn on Petawork Computers
#   PETAWORK_DAEMON_ARCHIVE=<file>  install this petawork-daemon-<v>-<os>-<arch>.tar.gz instead of
#                                   downloading (make daemon-install builds one from a checkout)
# Each also works under its older VENOM_ name (VENOM_VERSION, VENOM_DAEMON_NO_START, …); the
# PETAWORK_ one wins when both are set.
#
# Run it again to update: the same command installs the latest release over the old one and keeps
# the data. It also adds the desktop launch entry (macOS: ~/Applications/Petawork Daemon.app; Linux:
# an app launcher entry), turns on start at login (on Linux a systemd user service, which also starts
# the daemon at boot) and, on Linux with Docker, Petawork Computers. The daemon keeps its data in
# ~/.venom/daemon. A daemon installed before the rename (venom-daemon) is stopped and replaced, and
# its old launch entries removed. On Windows, use install-daemon.ps1.
set -eu

RELEASES="https://github.com/elishahbiz/venom-releases/releases"

say() { printf '%s\n' "$*"; }
err() {
	printf 'petawork-daemon install: %s\n' "$*" >&2
	exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || err "this installer needs '$1'"; }

# setting NAME: $PETAWORK_NAME when set, else $VENOM_NAME (the older spelling), else empty.
setting() {
	eval "printf '%s' \"\${PETAWORK_$1:-\${VENOM_$1:-}}\""
}

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

	install_dir="$(setting INSTALL_DIR)"
	install_dir="${install_dir:-$HOME/.venom}"
	bin_dir="$(setting BIN_DIR)"
	bin_dir="${bin_dir:-$install_dir/bin}"
	want_version="$(setting VERSION)"
	local_archive="$(setting DAEMON_ARCHIVE)"
	want=""
	if [ -n "$want_version" ]; then
		want="${want_version#v}"
		printf '%s' "$want" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || err "PETAWORK_VERSION '$want_version' is not a version like 0.2.0"
		base="$RELEASES/download/v$want"
	else
		base="$RELEASES/latest/download"
	fi

	tmp="$(mktemp -d "${TMPDIR:-/tmp}/petawork-daemon-install.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT INT TERM

	# Releases since the rename ship petawork-daemon-<v>-<os>-<arch>.tar.gz; older ones venom-daemon-….
	if [ -n "$local_archive" ]; then
		# A daemon archive built on this machine (make daemon-install): nothing is downloaded.
		asset="$(basename "$local_archive")"
		printf '%s' "$asset" | grep -Eq "^(petawork|venom)-daemon-[0-9][0-9A-Za-z.-]*-$os-$arch\.tar\.gz\$" ||
			err "PETAWORK_DAEMON_ARCHIVE must name a petawork-daemon-<version>-$os-$arch.tar.gz"
		[ -f "$local_archive" ] || err "no such file: $local_archive"
		cp "$local_archive" "$tmp/$asset"
		say "petawork-daemon: installing $asset from this machine"
	else
		say "petawork-daemon: finding the ${want:+v}${want:-latest} release for $os-$arch"
		fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
		line="$(grep -E "^[0-9a-f]{64}  petawork-daemon-[0-9][0-9A-Za-z.-]*-$os-$arch\.tar\.gz\$" "$tmp/SHA256SUMS" | head -n 1 || true)"
		[ -n "$line" ] || line="$(grep -E "^[0-9a-f]{64}  venom-daemon-[0-9][0-9A-Za-z.-]*-$os-$arch\.tar\.gz\$" "$tmp/SHA256SUMS" | head -n 1 || true)"
		[ -n "$line" ] || err "the release has no daemon archive for $os-$arch"
		sum="${line%% *}"
		asset="${line##* }"
	fi
	name="${asset%.tar.gz}"
	case "$name" in
	petawork-daemon-*) version="${name#petawork-daemon-}" ;;
	*) version="${name#venom-daemon-}" ;;
	esac
	version="${version%-"$os"-"$arch"}"
	if [ -z "$local_archive" ]; then
		say "petawork-daemon: downloading $asset"
		fetch "$RELEASES/download/v$version/$asset" "$tmp/$asset"
		got="$(sha256_of "$tmp/$asset")"
		[ "$got" = "$sum" ] || err "checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed"
		say "petawork-daemon: SHA256 verified ($sum)"
	fi

	mkdir -p "$tmp/unpack"
	tar -xzf "$tmp/$asset" -C "$tmp/unpack"
	# The tree: petawork-daemon/ (bin/petawork-daemon, with bin/venom-daemon beside it) since the
	# rename, venom-daemon/ (bin/venom-daemon) before it.
	tree="" launcher=""
	for top in petawork-daemon venom-daemon; do
		for exe in petawork-daemon venom-daemon; do
			if [ -z "$tree" ] && [ -x "$tmp/unpack/$top/bin/$exe" ] && [ -x "$tmp/unpack/$top/bin/orchestrator" ]; then
				tree="$top" launcher="$exe"
			fi
		done
	done
	[ -n "$tree" ] || err "$asset does not hold petawork-daemon/bin/petawork-daemon"

	# A running daemon (an older version, under either name) stops first; its data stays in ~/.venom/daemon.
	for old in "$bin_dir/petawork-daemon" "$bin_dir/venom-daemon"; do
		if [ -x "$old" ]; then
			"$old" stop >/dev/null 2>&1 || true
			break
		fi
	done

	mkdir -p "$install_dir/releases" "$bin_dir"
	dest="$install_dir/releases/$name"
	rm -rf "$dest"
	mv "$tmp/unpack/$tree" "$dest"
	if [ "$os" = darwin ] && command -v xattr >/dev/null 2>&1; then
		xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
	fi
	run="$dest/bin/$launcher"
	# petawork-daemon is the command; venom-daemon the same one under its old name.
	ln -sf "$run" "$bin_dir/petawork-daemon"
	ln -sf "$run" "$bin_dir/venom-daemon"
	# Older daemon releases go (either name); this one stays.
	for old in "$install_dir"/releases/petawork-daemon-* "$install_dir"/releases/venom-daemon-*; do
		[ -d "$old" ] && [ "$old" != "$dest" ] && [ -f "$old/.venom-daemon-home" ] && rm -rf "$old"
	done

	installed="$("$run" version 2>&1)" || err "the installed petawork-daemon did not run: $installed"
	"$run" shortcut || say "petawork-daemon: no desktop launch entry (start it with $bin_dir/petawork-daemon)"
	# Start at login (on Linux a systemd user service, which starts it at boot), pointed at this release.
	if [ "$(setting DAEMON_NO_AUTOSTART)" != 1 ]; then
		"$run" autostart on || say "petawork-daemon: could not turn on start at login (petawork-daemon autostart on)"
	fi
	say ""
	say "Petawork daemon $installed installed: $bin_dir/petawork-daemon -> $dest (venom-daemon works too)"
	case "$os" in
	darwin) say "Launch it any time from Applications: Petawork Daemon." ;;
	linux) say "Launch it any time from your app launcher: Petawork Daemon." ;;
	esac

	if [ "$(setting DAEMON_NO_START)" = 1 ]; then
		say "Start it with: $bin_dir/petawork-daemon"
		return
	fi
	open_flag=""
	if [ "$(setting DAEMON_NO_OPEN)" = 1 ] || { [ "$os" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }; then
		open_flag="--no-open"
	fi
	say ""
	"$run" start $open_flag || err "the daemon did not start; see $bin_dir/petawork-daemon logs"
	# Petawork Computers (Linux with Docker): on by default. The first time builds the computer image here
	# (a few minutes); an update keeps the setting and rebuilds the image only when it changed.
	if [ "$os" = linux ] && [ "$(setting DAEMON_NO_COMPUTERS)" != 1 ]; then
		say ""
		if docker info >/dev/null 2>&1; then
			say "petawork-daemon: turning on Petawork Computers"
			"$run" computers on || say "petawork-daemon: Computers did not turn on; see the dashboard's Computers card, then run: $bin_dir/petawork-daemon computers on"
		else
			say "Petawork Computers needs Docker that this user can use (docs.docker.com/engine/install; then"
			say "sudo usermod -aG docker \$USER and log in again). Then run: $bin_dir/petawork-daemon computers on"
		fi
	fi
	say ""
	if "$run" status 2>/dev/null | grep -q 'connected to'; then
		say "Docs: https://cloud.petawork.ai/daemon"
		return
	fi
	say "Next, in the dashboard: install Ollama if it asks, then Connect to Petawork Cloud with a join token"
	say "from https://cloud.petawork.ai (Daemons, Connect a daemon). Docs: https://cloud.petawork.ai/daemon"
}

main "$@"
