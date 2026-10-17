#!/bin/sh
# Install the venom CLI on macOS or Linux from its public releases:
#
#   curl -fsSL https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install.sh | sh
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the archive
# against the release's SHA256SUMS before unpacking anything, and needs no root. The archive carries
# its own Node.js runtime, so nothing else is installed.
#
#   VENOM_VERSION=0.1.0   install that version instead of the latest
#   VENOM_INSTALL_DIR     where releases are unpacked (default ~/.venom; they go in releases/)
#   VENOM_BIN_DIR         where the `venom` link goes (default $VENOM_INSTALL_DIR/bin; for example
#                         /usr/local/bin, if you can write there)
#
# On Windows, use install.ps1 from the same repository.
set -eu

RELEASES="https://github.com/elishahbiz/venom-releases/releases"

say() { printf '%s\n' "$*"; }
err() {
	printf 'venom install: %s\n' "$*" >&2
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
	MINGW* | MSYS* | CYGWIN*) err "on Windows, run this in PowerShell instead: irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install.ps1 | iex" ;;
	*) err "no venom build for $(uname -s); there are builds for macOS, Linux and Windows" ;;
	esac
	case "$(uname -m)" in
	x86_64 | amd64) arch=x64 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) err "no venom build for $(uname -m) on $os; there are builds for x64 and arm64" ;;
	esac
	# An x64 shell under Rosetta on an Apple silicon Mac: install the native build.
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
		printf '%s' "$want" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || err "VENOM_VERSION '$VENOM_VERSION' is not a version like 0.1.0"
		base="$RELEASES/download/v$want"
	else
		base="$RELEASES/latest/download"
	fi

	tmp="$(mktemp -d "${TMPDIR:-/tmp}/venom-install.XXXXXX")"
	trap 'rm -rf "$tmp"' EXIT INT TERM

	say "venom: finding the ${want:+v}${want:-latest} release for $os-$arch"
	fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS"
	line="$(grep -E "^[0-9a-f]{64}  venom-[0-9][0-9A-Za-z.-]*-$os-$arch\.tar\.gz\$" "$tmp/SHA256SUMS" | head -n 1 || true)"
	[ -n "$line" ] || err "the release has no archive for $os-$arch"
	sum="${line%% *}"
	asset="${line##* }"
	name="${asset%.tar.gz}"
	version="${name#venom-}"
	version="${version%-"$os"-"$arch"}"
	# Fetch the archive from its version's own URL, so it matches the SHA256SUMS just read.
	say "venom: downloading $asset"
	fetch "$RELEASES/download/v$version/$asset" "$tmp/$asset"
	got="$(sha256_of "$tmp/$asset")"
	[ "$got" = "$sum" ] || err "checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed"
	say "venom: SHA256 verified ($sum)"

	mkdir -p "$tmp/unpack"
	tar -xzf "$tmp/$asset" -C "$tmp/unpack"
	[ -x "$tmp/unpack/$name/bin/venom" ] && [ -x "$tmp/unpack/$name/runtime/node" ] || err "$asset does not hold $name/bin/venom"
	mkdir -p "$install_dir/releases" "$bin_dir"
	dest="$install_dir/releases/$name"
	rm -rf "$dest"
	mv "$tmp/unpack/$name" "$dest"
	if [ "$os" = darwin ] && command -v xattr >/dev/null 2>&1; then
		xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
	fi
	ln -sf "$dest/bin/venom" "$bin_dir/venom"

	installed="$("$bin_dir/venom" --version 2>&1)" || err "the installed venom did not run: $installed"
	say ""
	say "venom $installed installed: $bin_dir/venom -> $dest"

	case ":$PATH:" in
	*":$bin_dir:"*) ;;
	*)
		say ""
		say "$bin_dir is not on your PATH. Add it:"
		case "$(basename "${SHELL:-sh}")" in
		zsh) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
		bash) say "  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.bashrc && exec bash" ;;
		fish) say "  fish_add_path $bin_dir" ;;
		*) say "  export PATH=\"$bin_dir:\$PATH\"   (in your shell's startup file)" ;;
		esac
		;;
	esac
	say ""
	say "Next: point venom at a model (Venom Cloud, or any OpenAI-compatible endpoint) and start it:"
	say "  export VENOM_BASE_URL=https://cloud.usevenom.dev/v1"
	say "  export VENOM_API_KEY=vck_...        # from https://cloud.usevenom.dev"
	say "  venom                               # venom doctor checks the setup"
	say "Docs: https://cloud.usevenom.dev/cli"
}

main "$@"
