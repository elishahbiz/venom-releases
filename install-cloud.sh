#!/bin/sh
# Install Venom Cloud on a Linux server you own (VEN-284, VEN-319, docs/public/deploy/install-server.md).
#
#   curl -fsSL https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-cloud.sh | sh
#   sh install-cloud.sh --domain cloud.example.com --email you@example.com --yes
#
# It checks the machine first, downloads the release's SHA256SUMS (and checks its minisign signature when
# minisign and the signing key are there), pulls the venom-cloud image by the digest the release lists,
# generates every secret on this host into DIR/.env (mode 600), writes a compose stack (Postgres or your own
# database server, venom-cloud, optionally Ollama, and Caddy with Let's Encrypt, or a self-signed certificate
# for an IP), starts it, checks it, prints the URL and the one-time setup code, and leaves a `venom-cloud`
# command (status, logs, backup, restore, upgrade, rollback, models, uninstall). Nothing is sent anywhere
# except the downloads from the releases repo, the image registry, the Ollama model you name and, when you
# agree to it, Docker's own installer. Backups stay on this server's disk.
#
#   --dir DIR             install here (default /opt/venom; /opt/venom-db with --database-host)
#   --domain HOST         public host name (DNS must point here); without it the server's IP and a self-signed certificate
#   --email ADDR          the admin's email (shown again at the end; the setup screen asks for it)
#   --profile P           standard (Postgres on this server) or production (your own database server, daily backups)
#   --database-url URL    production: the database (better: VENOM_DATABASE_URL in the environment, out of shell history;
#                         VENOM_DATABASE_URL_UNPOOLED too when a pooler such as RDS Proxy sits in front of it)
#   --database-ca FILE    production: the database server's CA bundle (Amazon RDS's); the URL then verifies the certificate
#   --shared-database     production: other app servers use this database too (an Auto Scaling group): one of them
#                         takes each day's scheduled backup, and a failed upgrade never restores the database by itself
#   --behind-proxy        a load balancer in front terminates HTTPS (AWS ALB): Caddy serves plain HTTP on port 80
#   --backup-s3 URL       s3://bucket/prefix kept in .env for the off-site copy of the scheduled backups
#   --secrets-only        only generate the secrets into DIR/.env and stop (seeds the secrets every app server shares)
#   --backups daily|off   a daily database backup from cron (default: daily for production, off for standard)
#   --backup-keep N       scheduled backups to keep (default 14)
#   --backup-dir DIR      where backups go (default DIR/backups)
#   --models M            where models come from: ollama (on this server), key (a provider API key) or later
#   --provider P          with --models key: openai, qwen or zai (the key: VENOM_PROVIDER_KEY, else asked, never shown)
#   --ollama-url URL      with --models ollama: an Ollama you already run (default: an Ollama container in the stack)
#   --ollama-model NAME   with --models ollama: the model to pull now (default qwen3:4b; none: pull later)
#   --database-host       set up only Postgres here, for a production install on another server
#   --listen ADDR         with --database-host: the address Postgres listens on (default: this server's first IP)
#   --version X.Y.Z       a release (default: the latest)
#   --image REF           use this image instead of the release's (a local registry in tests)
#   --auto-update yes|no  switch automatic updates on (Settings, Updates in the console: the maintenance window,
#                         patch or minor releases); the console is where they are changed later (default: ask, else no)
#   --channel C           stable (default) or preview (pre-releases too); without --version the channel's newest
#   --yes                 never ask: take the defaults
#   --dry-run             everything except starting Docker
#   --no-docker-install   never offer to install Docker
#   --skip-dns-check      do not require the domain to resolve
#   --upgrade             an existing install: preflight, backup, switch to the release's image, health check, rollback on failure
set -eu

REPO="elishahbiz/venom-releases"
RELEASES="${VENOM_RELEASES_URL:-https://github.com/$REPO/releases}"
RAW="${VENOM_RAW_URL:-https://raw.githubusercontent.com/$REPO/main}"
IMAGE_REPO="${VENOM_CLOUD_IMAGE_REPO:-ghcr.io/elishahbiz/venom-cloud}"
PG_IMAGE="pgvector/pgvector:pg17"
OLLAMA_IMAGE="ollama/ollama:latest"
DEFAULT_OLLAMA_MODEL="qwen3:4b"
# The release signing key (a minisign public key string); empty until the first signed release.
RELEASE_PUBKEY=""

min_from="" dir="" domain="" email="" version="" image="" auto="" yes=0 dry=0 docker_install=1 skip_dns=0 upgrade=0
profile="" dburl="${VENOM_DATABASE_URL:-}" backups="" keep="" bdir="" models="" provider="" pkey="${VENOM_PROVIDER_KEY:-}"
ollama_url="" ollama_model="" ollama_service="" private_urls="" dbhost=0 listen=""
dburl_unpooled="${VENOM_DATABASE_URL_UNPOOLED:-}" dbca="" shared="" proxy="" s3="" secrets_only=0 channel=""
DB_CA_PATH="/etc/venom/database-ca.pem" # where the CA bundle is mounted in the containers

say() { printf '%s\n' "$*"; }
warn() { printf 'install-cloud: %s\n' "$*" >&2; }
die() { printf 'install-cloud: %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" 2>/dev/null; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--dir) dir="${2:?--dir needs a directory}"; shift 2 ;;
	--domain) domain="${2:?--domain needs a host name}"; shift 2 ;;
	--email) email="${2:?--email needs an address}"; shift 2 ;;
	--profile) profile="${2:?--profile needs standard or production}"; shift 2 ;;
	--database-url) dburl="${2:?--database-url needs a postgres:// URL}"; shift 2 ;;
	--backups) backups="${2:?--backups needs daily or off}"; shift 2 ;;
	--backup-keep) keep="${2:?--backup-keep needs a number}"; shift 2 ;;
	--backup-dir) bdir="${2:?--backup-dir needs a directory}"; shift 2 ;;
	--models) models="${2:?--models needs ollama, key or later}"; shift 2 ;;
	--provider) provider="${2:?--provider needs openai, qwen or zai}"; shift 2 ;;
	--ollama-url) ollama_url="${2:?--ollama-url needs a URL}"; shift 2 ;;
	--ollama-model) ollama_model="${2:?--ollama-model needs a model name or none}"; shift 2 ;;
	--database-ca) dbca="${2:?--database-ca needs a PEM file}"; shift 2 ;;
	--shared-database) shared=1; shift ;;
	--behind-proxy) proxy=1; shift ;;
	--backup-s3) s3="${2:?--backup-s3 needs an s3://bucket/prefix URL}"; shift 2 ;;
	--secrets-only) secrets_only=1; shift ;;
	--database-host) dbhost=1; shift ;;
	--listen) listen="${2:?--listen needs an address}"; shift 2 ;;
	--version) version="${2:?--version needs X.Y.Z}"; shift 2 ;;
	--image) image="${2:?--image needs a reference}"; shift 2 ;;
	--auto-update) auto="${2:?--auto-update needs yes or no}"; shift 2 ;;
	--channel) channel="${2:?--channel needs stable or preview}"; shift 2 ;;
	--yes | -y) yes=1; shift ;;
	--dry-run) dry=1; shift ;;
	--no-docker-install) docker_install=0; shift ;;
	--skip-dns-check) skip_dns=1; shift ;;
	--upgrade) upgrade=1; yes=1; shift ;;
	-h | --help) usage 0 ;;
	*) warn "unknown argument: $1"; usage 2 ;;
	esac
done
if [ -z "$dir" ]; then if [ "$dbhost" = 1 ]; then dir="/opt/venom-db"; else dir="/opt/venom"; fi; fi
case "$channel" in '' | stable | preview) ;; *) die "--channel is stable or preview, not $channel" ;; esac

# --- questions ----------------------------------------------------------------
# Asked on the terminal even when the script itself comes down a pipe (curl | sh). No terminal, or --yes: the default.
ask() { # prompt default -> answer on stdout
	if [ "$yes" = 1 ] || ! { : </dev/tty; } 2>/dev/null; then printf '%s\n' "$2"; return; fi
	printf '%s [%s]: ' "$1" "$2" >/dev/tty
	read -r a </dev/tty || a=""
	printf '%s\n' "${a:-$2}"
}
ask_secret() { # prompt -> answer on stdout, typed without echo; empty with --yes or no terminal
	if [ "$yes" = 1 ] || ! { : </dev/tty; } 2>/dev/null; then printf '\n'; return; fi
	printf '%s: ' "$1" >/dev/tty
	stty -echo </dev/tty 2>/dev/null || true
	read -r a </dev/tty || a=""
	stty echo </dev/tty 2>/dev/null || true
	printf '\n' >/dev/tty
	printf '%s\n' "$a"
}
confirm() { # prompt -> 0 for yes (default no)
	[ "$yes" = 1 ] && return 1
	{ : </dev/tty; } 2>/dev/null || return 1
	printf '%s [y/N]: ' "$1" >/dev/tty
	read -r a </dev/tty || a=""
	case "$a" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}
# A value an earlier run of this installer kept in DIR/.env: the default when it runs again.
prev() { sed -n "s/^$1=//p" "$dir/.env" 2>/dev/null | tail -1; }
prevor() { v="$(prev "$1")"; printf "%s\n" "${v:-$2}"; }

# --- preflight: nothing is touched until it passes ------------------------------
problems=""
problem() { problems="$problems
  - $*"; }

preflight() {
	[ "$(uname -s)" = Linux ] || problem "this installer is for Linux servers (this is $(uname -s)). Use the compose stack from the docs on other systems."
	case "$(uname -m)" in x86_64 | amd64 | aarch64 | arm64) ;; *) problem "unsupported CPU architecture $(uname -m): the image is built for amd64 and arm64." ;; esac
	cpus="${VENOM_PREFLIGHT_CPUS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
	[ "$cpus" -ge 2 ] || problem "needs at least 2 CPU cores (found $cpus). Pick a larger server size."
	mem="${VENOM_PREFLIGHT_MEM_MB:-$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)}"
	[ "$mem" -ge 1800 ] || problem "needs at least 2 GB of memory (found ${mem} MB). Pick a larger server size."
	mkdir -p "$dir" 2>/dev/null || true
	disk="${VENOM_PREFLIGHT_DISK_MB:-$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)}"
	[ "${disk:-0}" -ge 10000 ] || problem "needs at least 10 GB free in $dir (found ${disk:-0} MB). Free some disk or add a volume."
	if [ "$upgrade" = 0 ] && [ "${VENOM_PREFLIGHT_PORTS_FREE:-0}" != 1 ]; then
		if [ "$dbhost" = 1 ]; then ports=5432; else ports="80 443"; fi
		for p in $ports; do
			if port_busy "$p"; then problem "port $p is already in use. Stop what listens there (for example another web server or database) and run this again."; fi
		done
	fi
	if [ -n "$domain" ] && [ "$skip_dns" = 0 ]; then
		if ! getent hosts "$domain" >/dev/null 2>&1; then
			problem "$domain does not resolve yet. Point its A (or AAAA) record at this server, wait for DNS, and run this again (or --skip-dns-check)."
		fi
	fi
	if [ -n "$problems" ]; then
		warn "the server is not ready:$problems"
		exit 1
	fi
}

port_busy() {
	if command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {f=1} END {exit !f}'
	elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {f=1} END {exit !f}'
	else return 1; fi
}

ensure_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		[ "$docker_install" = 1 ] || die "Docker is not installed. Install Docker Engine with the compose plugin (https://docs.docker.com/engine/install/), then run this again."
		confirm "Docker is not installed. Install it now with Docker's own script (https://get.docker.com)?" ||
			die "Docker is not installed. Install Docker Engine with the compose plugin (https://docs.docker.com/engine/install/), or run this with a terminal to let it do that."
		curl -fsSL https://get.docker.com | sh || die "Docker's installer failed. Install Docker by hand and run this again."
	fi
	docker compose version >/dev/null 2>&1 || die "Docker is installed but has no compose plugin (docker compose). Install docker-compose-plugin and run this again."
	docker info >/dev/null 2>&1 || die "Docker is installed but not running, or this user cannot use it. Start it (systemctl start docker) or run this as root."
}

first_ip() { ip="${VENOM_PUBLIC_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || true)}"; printf '%s\n' "${ip:-127.0.0.1}"; }

# --- the answers: size profile, database, backups, model source -------------------------
dbhost_of() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^@/]*@)?([^/?]+).*#\2#'; } # never the password
origin_of() { printf '%s' "$1" | sed -E 's#^(https?://[^/?]+).*#\1#'; }
is_loopback() { case "$1" in localhost | localhost:* | 127.* | "[::1]"* | ::1) return 0 ;; *) return 1 ;; esac; }
# with_ca URL: verify the server's certificate against the mounted CA bundle (psql and node-postgres both read these).
with_ca() {
	u="$1"
	case "$u" in *\?*) sep='&' ;; *) sep='?' ;; esac
	case "$u" in *sslmode=*) ;; *) u="${u}${sep}sslmode=verify-full"; sep='&' ;; esac
	case "$u" in *sslrootcert=*) ;; *) u="${u}${sep}sslrootcert=$DB_CA_PATH" ;; esac
	printf '%s\n' "$u"
}

answers() {
	[ -n "$profile" ] || profile="$(ask 'Size profile: standard (one server) or production (your own database server and daily backups)' "$(prevor VENOM_CLOUD_PROFILE standard)")"
	case "$profile" in standard | production) ;; *) die "--profile is standard or production, not $profile" ;; esac
	if [ "$profile" = production ]; then
		[ -n "$dburl" ] || dburl="$(prev VENOM_DATABASE_URL)"
		[ -n "$dburl" ] || dburl="$(ask_secret 'Database URL, postgres://user:password@host:5432/database (not shown)')"
		[ -n "$dburl" ] || die "the production profile needs your database server: set VENOM_DATABASE_URL=postgres://user:password@host:5432/database (or --database-url). To set one up, run this installer with --database-host on that server."
		case "$dburl" in postgres://* | postgresql://*) ;; *) die "the database URL must start with postgres:// or postgresql://" ;; esac
		is_loopback "$(dbhost_of "$dburl")" && die "the database URL points at this machine's loopback, which inside a container is the container itself: use the database server's network address."
		[ -n "$dburl_unpooled" ] || dburl_unpooled="$(prev VENOM_DATABASE_URL_UNPOOLED)"
		[ "$dburl_unpooled" != "$dburl" ] || dburl_unpooled=""
		case "$dburl_unpooled" in '' | postgres://* | postgresql://*) ;; *) die "VENOM_DATABASE_URL_UNPOOLED must start with postgres:// or postgresql://" ;; esac
		# A rerun keeps the CA bundle an earlier run copied here.
		[ -n "$dbca" ] || [ -z "$(prev VENOM_DATABASE_CA)" ] || [ ! -f "$dir/database-ca.pem" ] || dbca="$dir/database-ca.pem"
		if [ -n "$dbca" ]; then
			[ -f "$dbca" ] && grep -q 'BEGIN CERTIFICATE' "$dbca" || die "--database-ca needs a PEM file of CA certificates (for RDS: https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem)"
			dbca="$(cd "$(dirname "$dbca")" && pwd)/$(basename "$dbca")"
			dburl="$(with_ca "$dburl")"
			[ -z "$dburl_unpooled" ] || dburl_unpooled="$(with_ca "$dburl_unpooled")"
		fi
		[ -n "$shared" ] || shared="$(prev VENOM_SHARED_DATABASE)"
	else
		[ -z "$shared$dbca" ] || die "--shared-database and --database-ca are for the production profile (your own database server)"
	fi
	[ -n "$proxy" ] || { [ "$(prev VENOM_TLS_MODE)" != proxy ] || proxy=1; }
	[ -z "$proxy" ] || [ -n "$domain" ] || die "--behind-proxy needs --domain: the load balancer serves that name over HTTPS"
	[ -n "$s3" ] || s3="$(prev VENOM_BACKUP_S3)"
	case "$s3" in '' | s3://?*) ;; *) die "--backup-s3 is an s3://bucket/prefix URL, not $s3" ;; esac
	[ -n "$backups" ] || backups="$(prev VENOM_BACKUPS)"
	[ -n "$backups" ] || { if [ "$profile" = production ]; then backups=daily; else backups=off; fi; }
	case "$backups" in daily | off) ;; *) die "--backups is daily or off, not $backups" ;; esac
	[ -n "$keep" ] || keep="$(prev VENOM_BACKUP_KEEP)"
	keep="${keep:-14}"
	case "$keep" in '' | *[!0-9]* | 0) die "--backup-keep needs a whole number of backups, 1 or more (not $keep)" ;; esac
	[ -n "$bdir" ] || bdir="$(prev VENOM_BACKUP_DIR)"
	bdir="${bdir:-$dir/backups}"

	[ -n "$models" ] || models="$(ask 'Where do models come from? ollama (runs on this server), key (a provider API key) or later (add them in the console)' "$(prevor VENOM_MODELS later)")"
	case "$models" in
	ollama)
		if [ -n "$ollama_url" ]; then
			case "$ollama_url" in http://* | https://*) ;; *) die "--ollama-url must be an http:// or https:// URL" ;; esac
			private_urls="$(origin_of "$ollama_url")"
			is_loopback "${private_urls#*://}" && die "--ollama-url points at loopback, which inside a container is the container itself: use this server's network address, or leave --ollama-url out to run Ollama in the stack."
			ollama_service=""
		else
			private_urls="http://ollama:11434"
			ollama_service=1
			[ -n "$ollama_model" ] || ollama_model="$(ask 'Ollama model to pull now (none: pull one later with venom-cloud models pull)' "$DEFAULT_OLLAMA_MODEL")"
		fi
		;;
	key)
		[ -n "$provider" ] || provider="$(ask 'Provider for that key: openai, qwen or zai' openai)"
		case "$provider" in openai | qwen | zai) ;; *) die "--provider is openai, qwen or zai (other providers are added in the console after setup)" ;; esac
		[ -n "$pkey" ] || pkey="$(ask_secret "$provider API key (not shown)")"
		[ -n "$pkey" ] || die "no API key: set VENOM_PROVIDER_KEY in the environment, type it at the prompt, or choose --models later"
		;;
	later) ;;
	*) die "--models is ollama, key or later, not $models" ;;
	esac
}

# The production database answers and has pgvector. The URL travels in the environment, never on a command line.
check_database() {
	h="$(dbhost_of "$dburl")"
	set --
	[ -z "$dbca" ] || set -- -v "$dbca:$DB_CA_PATH:ro"
	out="$(DB="$dburl" docker run --rm -e DB "$@" "$PG_IMAGE" sh -c 'psql -d "$DB" -tAc "SELECT count(*) FROM pg_available_extensions WHERE name = '"'vector'"'"' 2>&1)" ||
		die "cannot reach the database at $h: $(printf '%s' "$out" | tail -1). Check the address, the password and that this server may connect (the database server's firewall and pg_hba.conf)."
	[ "$(printf '%s' "$out" | tr -d '[:space:]')" = 1 ] ||
		die "the database at $h has no pgvector extension. Use the $PG_IMAGE image (install-cloud.sh --database-host does), or turn on the vector extension of your managed Postgres."
	say "database at $h answers and has pgvector"
}

# --- the release: SHA256SUMS, its signature, the image digest ----------------------
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

resolve_release() {
	work="$(mktemp -d "${TMPDIR:-/tmp}/venom-cloud-install.XXXXXX")"
	trap 'rm -rf "$work"' EXIT
	if [ -n "$image" ]; then
		say "using image $image"
		return
	fi
	[ -n "$channel" ] || channel="$(prevor VENOM_CHANNEL stable)"
	if [ -z "$version" ] && [ "$channel" = preview ]; then
		# The preview channel: the newest release, pre-releases included, named by the releases repo's CHANNELS file.
		version="$(curl -fsSL "$RAW/CHANNELS" 2>/dev/null | sed -n 's/^preview[[:space:]][[:space:]]*\([0-9][0-9A-Za-z.-]*\)[[:space:]]*$/\1/p' | head -1 || true)"
		[ -n "$version" ] || warn "the preview channel names no release yet; using the latest stable one"
	fi
	if [ -z "$version" ]; then
		url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest")" || die "could not reach $RELEASES/latest"
		version="${url##*/v}"
	fi
	case "$version" in [0-9]*.[0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*-[0-9A-Za-z]*) ;; *) die "not a version: $version" ;; esac
	base="$RELEASES/download/v$version"
	curl -fsSL -o "$work/SHA256SUMS" "$base/SHA256SUMS" || die "no release v$version at $RELEASES"
	if curl -fsSL -o "$work/SHA256SUMS.minisig" "$base/SHA256SUMS.minisig" 2>/dev/null; then
		if [ -n "${VENOM_RELEASE_PUBKEY:-$RELEASE_PUBKEY}" ] && command -v minisign >/dev/null 2>&1; then
			minisign -V -q -P "${VENOM_RELEASE_PUBKEY:-$RELEASE_PUBKEY}" -m "$work/SHA256SUMS" -x "$work/SHA256SUMS.minisig" >/dev/null 2>&1 ||
				die "SHA256SUMS.minisig does not verify against the release signing key: do not install this"
			say "verified the SHA256SUMS signature (minisign)"
		else
			warn "the release is signed, but minisign or the signing key is not here, so the signature is not checked"
		fi
	else
		warn "this release has no signature (SHA256SUMS.minisig); trusting SHA256SUMS over HTTPS"
	fi
	name="venom-cloud-$version.image"
	if curl -fsSL -o "$work/$name" "$base/$name" 2>/dev/null; then
		want="$(grep -E "^[0-9a-f]{64}  $name\$" "$work/SHA256SUMS" | cut -d' ' -f1 || true)"
		[ -n "$want" ] || die "$name is not listed in SHA256SUMS"
		[ "$(sha "$work/$name")" = "$want" ] || die "$name does not match SHA256SUMS: do not install this"
		image="$(tr -d '[:space:]' <"$work/$name")"
		case "$image" in *@sha256:????????????????????????????????????????????????????????????????) ;; *) die "$name does not hold an image digest" ;; esac
		say "venom-cloud $version, image $image"
		# The optional release manifest (venom-cloud-X.Y.Z.json): the oldest version this release upgrades from.
		mname="venom-cloud-$version.json"
		if grep -Eq "^[0-9a-f]{64}  $mname\$" "$work/SHA256SUMS" && curl -fsSL -o "$work/$mname" "$base/$mname" 2>/dev/null; then
			want="$(grep -E "^[0-9a-f]{64}  $mname\$" "$work/SHA256SUMS" | cut -d' ' -f1)"
			[ "$(sha "$work/$mname")" = "$want" ] || die "$mname does not match SHA256SUMS: do not install this"
			min_from="$(sed -n 's/.*"min_from"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$work/$mname" | head -1)"
		fi
	else
		warn "release v$version lists no image digest; using the tag $IMAGE_REPO:$version"
		image="$IMAGE_REPO:$version"
	fi
}

# --- secrets and the stack ---------------------------------------------------------
envf=""
has() { grep -Eq "^$1=.+" "$envf" 2>/dev/null; }
put() { if has "$1"; then :; else printf '%s=%s\n' "$1" "$2" >>"$envf"; fi; }
setkey() { # replace or append KEY=VALUE
	if grep -Eq "^$1=" "$envf" 2>/dev/null; then
		grep -Ev "^$1=" "$envf" >"$envf.new" || true
		cat "$envf.new" >"$envf"
		rm -f "$envf.new"
	fi
	printf '%s=%s\n' "$1" "$2" >>"$envf"
}
ev() { sed -n "s/^$1=//p" "$envf" 2>/dev/null | tail -1; }
b64() { openssl rand -base64 "$1" | tr -d '\n'; }
ed25519() { openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\n'; }

open_env() {
	command -v openssl >/dev/null 2>&1 || die "needs openssl to generate secrets (apt-get install openssl)"
	umask 077
	mkdir -p "$dir"
	envf="$dir/.env"
	touch "$envf"
	chmod 600 "$envf"
}

# The secrets. put() keeps a value already in .env, so a .env seeded with the shared secrets (every app server of an
# Auto Scaling group must hold the same VENOM_VAULT_KEYS) keeps them.
gen_secrets() {
	kid="k$(date -u +%Y%m%d)"
	put CLOUD_DB_PASSWORD "$(openssl rand -hex 24)"
	put VENOM_CLOUD_ADMIN_TOKEN "$(b64 48)"
	put VENOM_VAULT_KEYS "$kid:$(b64 32)"
	put VENOM_MESH_SIGNING_KEYS "[{\"kid\":\"$kid\",\"pkcs8_b64\":\"$(ed25519)\"}]"
	put VENOM_POLICY_SIGNING_KEY "{\"kid\":\"policy-$kid\",\"pkcs8_b64\":\"$(ed25519)\"}"
	put CRON_SECRET "$(openssl rand -hex 32)"
	put AUTH_SECRET "$(b64 32)"
}

write_env() {
	open_env
	gen_secrets
	if [ -n "$proxy" ]; then
		setkey CLOUD_ADDRESS ":80"
		setkey VENOM_CLOUD_ORIGIN "https://$domain"
		setkey CLOUD_TLS ""
	elif [ -n "$domain" ]; then
		setkey CLOUD_ADDRESS "$domain"
		setkey VENOM_CLOUD_ORIGIN "https://$domain"
		setkey CLOUD_TLS ""
	else
		ip="$(first_ip)" # VENOM_PUBLIC_IP: behind NAT (AWS)
		setkey CLOUD_ADDRESS "$ip"
		setkey VENOM_CLOUD_ORIGIN "https://$ip"
		setkey CLOUD_TLS "tls internal"
	fi
	[ -z "$email" ] || setkey VENOM_CLOUD_ADMIN_EMAIL "$email"
	setkey VENOM_CLOUD_IMAGE "$image"
	[ -z "$version" ] || setkey VENOM_CLOUD_VERSION "$version"
	setkey VENOM_CLOUD_PROFILE "$profile"
	if [ "$profile" = production ]; then
		setkey VENOM_DATABASE_URL "$dburl"
		setkey VENOM_DATABASE_URL_UNPOOLED "${dburl_unpooled:-$dburl}"
	else
		setkey VENOM_DATABASE_URL ""
		setkey VENOM_DATABASE_URL_UNPOOLED ""
	fi
	if [ -n "$dbca" ]; then
		cmp -s "$dbca" "$dir/database-ca.pem" 2>/dev/null || cp "$dbca" "$dir/database-ca.pem"
		chmod 644 "$dir/database-ca.pem"
		setkey VENOM_DATABASE_CA "$DB_CA_PATH"
	elif [ "$profile" != production ]; then
		setkey VENOM_DATABASE_CA ""
	fi
	setkey VENOM_SHARED_DATABASE "$shared"
	if [ -n "$proxy" ]; then setkey VENOM_TLS_MODE proxy; else setkey VENOM_TLS_MODE auto; fi
	setkey VENOM_BACKUP_S3 "$s3"
	setkey VENOM_BACKUPS "$backups"
	setkey VENOM_BACKUP_KEEP "$keep"
	setkey VENOM_BACKUP_DIR "$bdir"
	case "$auto" in y | yes | YES | Yes) setkey VENOM_AUTO_UPDATE yes ;; *) setkey VENOM_AUTO_UPDATE no ;; esac
	setkey VENOM_CHANNEL "${channel:-stable}"
	setkey VENOM_MODELS "$models"
	setkey VENOM_OLLAMA_SERVICE "$ollama_service"
	setkey VENOM_PRIVATE_BASE_URLS "$private_urls"
	if [ "$models" = key ]; then
		case "$provider" in openai) setkey OPENAI_API_KEY "$pkey" ;; qwen) setkey QWEN_API_KEY "$pkey" ;; zai) setkey ZAI_API_KEY "$pkey" ;; esac
	fi
}

# The compose stack follows .env: the profile decides where Postgres is, VENOM_OLLAMA_SERVICE adds Ollama. An upgrade
# rewrites it from the same .env, so the stack a release ships stays the one the answers chose.
write_stack() {
	p="$(ev VENOM_CLOUD_PROFILE)"
	o="$(ev VENOM_OLLAMA_SERVICE)"
	tls="$(ev VENOM_TLS_MODE)"
	ca="$(ev VENOM_DATABASE_CA)"
	# An install from before VENOM_DATABASE_URL_UNPOOLED existed: the same database, as it was.
	[ "$p" != production ] || [ -n "$(ev VENOM_DATABASE_URL_UNPOOLED)" ] || setkey VENOM_DATABASE_URL_UNPOOLED "$(ev VENOM_DATABASE_URL)"
	{
		cat <<'EOF'
# Venom Cloud (written by install-cloud.sh). Secrets and the image come from .env.
name: venom-cloud
services:
EOF
		if [ "$p" != production ]; then
			cat <<EOF
  postgres:
    image: $PG_IMAGE
    environment:
      POSTGRES_USER: venom
      POSTGRES_PASSWORD: \${CLOUD_DB_PASSWORD}
      POSTGRES_DB: venom_cloud
    volumes: [db:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "venom", "-d", "venom_cloud"]
      interval: 2s
      timeout: 2s
      retries: 30
    restart: unless-stopped
EOF
		fi
		cat <<'EOF'
  venom-cloud:
    image: ${VENOM_CLOUD_IMAGE}
EOF
		if [ "$p" = production ]; then
			cat <<'EOF'
    environment:
      DATABASE_URL: ${VENOM_DATABASE_URL}
      DATABASE_URL_UNPOOLED: ${VENOM_DATABASE_URL_UNPOOLED}
EOF
		else
			cat <<'EOF'
    depends_on:
      postgres: { condition: service_healthy }
    environment:
      DATABASE_URL: postgres://venom:${CLOUD_DB_PASSWORD}@postgres:5432/venom_cloud
      DATABASE_URL_UNPOOLED: postgres://venom:${CLOUD_DB_PASSWORD}@postgres:5432/venom_cloud
EOF
		fi
		cat <<'EOF'
      VENOM_CLOUD_ADMIN_TOKEN: ${VENOM_CLOUD_ADMIN_TOKEN}
      VENOM_VAULT_KEYS: ${VENOM_VAULT_KEYS}
      VENOM_MESH_SIGNING_KEYS: ${VENOM_MESH_SIGNING_KEYS}
      VENOM_POLICY_SIGNING_KEY: ${VENOM_POLICY_SIGNING_KEY}
      CRON_SECRET: ${CRON_SECRET}
      AUTH_SECRET: ${AUTH_SECRET}
      VENOM_CLOUD_ORIGIN: ${VENOM_CLOUD_ORIGIN}
      VENOM_CLOUD_VERSION: ${VENOM_CLOUD_VERSION:-}
      VENOM_RELEASE_PUBKEY: ${VENOM_RELEASE_PUBKEY:-}
      VENOM_PRIVATE_BASE_URLS: ${VENOM_PRIVATE_BASE_URLS:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      QWEN_API_KEY: ${QWEN_API_KEY:-}
      ZAI_API_KEY: ${ZAI_API_KEY:-}
    read_only: true
    tmpfs: ["/tmp"]
    restart: unless-stopped
EOF
		# The database server's CA bundle, named by the URL's sslrootcert (install-cloud.sh --database-ca).
		[ -z "$ca" ] || printf '    volumes: ["./database-ca.pem:%s:ro"]\n' "$ca"
		if [ "$p" = production ]; then
			# Postgres' client tools for backups and restores (venom-cloud backup / restore); never started by `up`.
			# The direct (unpooled) URL: pg_dump and a restore must not go through a pooler.
			cat <<EOF
  pgtools:
    image: $PG_IMAGE
    profiles: [tools]
    environment:
      DB: \${VENOM_DATABASE_URL_UNPOOLED}
EOF
			[ -z "$ca" ] || printf '    volumes: ["./database-ca.pem:%s:ro"]\n' "$ca"
		fi
		if [ "$o" = 1 ]; then
			cat <<EOF
  ollama:
    image: $OLLAMA_IMAGE
    volumes: [ollama:/root/.ollama]
    restart: unless-stopped
EOF
		fi
		cat <<'EOF'
  caddy:
    image: caddy:2-alpine
    depends_on: [venom-cloud]
EOF
		if [ "$tls" = proxy ]; then echo '    ports: ["80:80"]'; else echo '    ports: ["80:80", "443:443"]'; fi
		cat <<'EOF'
    environment:
      CLOUD_ADDRESS: ${CLOUD_ADDRESS}
      CLOUD_TLS: ${CLOUD_TLS:-}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy:/data
    restart: unless-stopped
volumes:
  caddy:
EOF
		[ "$p" = production ] || echo "  db:"
		[ "$o" != 1 ] || echo "  ollama:"
	} >"$dir/docker-compose.yml"
	if [ "$tls" = proxy ]; then
		cat >"$dir/Caddyfile" <<'EOF'
# Behind a load balancer that terminates HTTPS (install-cloud.sh --behind-proxy): plain HTTP on port 80, any host name.
# The load balancer's X-Forwarded-* headers are kept (it reaches this server from a private address).
{
	auto_https off
	servers {
		trusted_proxies static private_ranges
	}
}

:80 {
	encode zstd gzip
	reverse_proxy venom-cloud:3100 {
		flush_interval -1
	}
}
EOF
		return
	fi
	cat >"$dir/Caddyfile" <<'EOF'
# A public host name gets a Let's Encrypt certificate by itself; an IP gets Caddy's own CA (CLOUD_TLS="tls internal").
# default_sni: a client that sends no server name (curl to an IP, health checks) still gets this site's certificate.
{
	default_sni {$CLOUD_ADDRESS}
}

{$CLOUD_ADDRESS} {
	{$CLOUD_TLS}
	encode zstd gzip
	reverse_proxy venom-cloud:3100 {
		flush_interval -1
	}
}
EOF
}

# The cron entries: `venom-cloud tick` every five minutes (it carries out what the console asks for: automatic updates
# in their window, scheduled backups, Upgrade now, Roll back, Verify restore, the export) and the installer's daily
# backup (the production default; it steps aside once the console sets a backup schedule).
write_cron() {
	crond="${VENOM_CRON_DIR:-/etc/cron.d}"
	lines="*/5 * * * * root $dir/bin/venom-cloud tick >>/var/log/venom-cloud-tick.log 2>&1"
	if [ "$backups" = daily ]; then
		lines="$lines
27 3 * * * root $dir/bin/venom-cloud backup --scheduled >>/var/log/venom-cloud-backup.log 2>&1"
	fi
	if [ -d "$crond" ] && [ -w "$crond" ]; then
		printf '%s\n' "$lines" >"$crond/venom-cloud"
		case "$auto" in y | yes | YES | Yes) say "automatic updates: on (change the window in the console: Settings, Updates)" ;; esac
		[ "$backups" != daily ] || say "backups: daily at 03:27 into $bdir, the newest $keep kept"
	else
		warn "cannot write $crond (not root): the console cannot reach this server's updates and backups. Run venom-cloud tick every five minutes from your own scheduler."
	fi
}

# --- a database server for a production install elsewhere (--database-host) ------------------
database_host() {
	open_env
	put CLOUD_DB_PASSWORD "$(openssl rand -hex 24)"
	[ -n "$listen" ] || listen="$(first_ip)"
	setkey DB_LISTEN "$listen"
	cat >"$dir/docker-compose.yml" <<EOF
# Postgres for a Venom Cloud on another server (written by install-cloud.sh --database-host).
name: venom-db
services:
  postgres:
    image: $PG_IMAGE
    environment:
      POSTGRES_USER: venom
      POSTGRES_PASSWORD: \${CLOUD_DB_PASSWORD}
      POSTGRES_DB: venom_cloud
    ports: ["\${DB_LISTEN}:5432:5432"]
    volumes: [db:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "venom", "-d", "venom_cloud"]
      interval: 2s
      timeout: 2s
      retries: 30
    restart: unless-stopped
volumes:
  db:
EOF
	host="$listen"
	[ "$host" != 0.0.0.0 ] || host="$(first_ip)"
	printf 'postgres://venom:%s@%s:5432/venom_cloud\n' "$(ev CLOUD_DB_PASSWORD)" "$host" >"$dir/database-url"
	chmod 600 "$dir/database-url"
	if [ "$dry" = 1 ]; then
		say "dry run: wrote $dir (.env, docker-compose.yml, database-url); Docker was not started"
		exit 0
	fi
	(cd "$dir" && { docker compose pull --quiet || true; } && docker compose up -d --wait) || die "Postgres did not become healthy. Look at: cd $dir && docker compose logs postgres"
	say ""
	say "Postgres for Venom Cloud is running on $listen:5432."
	say "  On the app server: VENOM_DATABASE_URL=\"\$(cat database-url)\" sh install-cloud.sh --profile production"
	say "  The URL, with its password, is in $dir/database-url (mode 600). Copy it over a channel you trust."
	say "  Let only the app server reach port 5432 (a private network or a firewall rule): the traffic is not encrypted."
	exit 0
}

# --- the venom-cloud command ---------------------------------------------------------
write_helper() {
	mkdir -p "$dir/bin"
	cat >"$dir/bin/venom-cloud.new" <<'HELPER_EOF'
#!/bin/sh
# venom-cloud: manage a Venom Cloud installed by install-cloud.sh.
#   venom-cloud status
#   venom-cloud logs [SERVICE]       follow the logs (venom-cloud, postgres, ollama, caddy)
#   venom-cloud backup [FILE]        a gzip'd SQL dump of the database (default BACKUP_DIR/venom-cloud-<time>.sql.gz)
#   venom-cloud backup --scheduled   the same, then keep only the newest VENOM_BACKUP_KEEP (what cron runs)
#   venom-cloud backup --list        the backups, newest first
#   venom-cloud restore FILE --yes   replace the database with a backup (a safety backup of the current one first)
#   venom-cloud upgrade [--yes] [--version X.Y.Z]
#                                    preflight, back up, pull by digest, migrate, health check; rolls back by itself
#   venom-cloud upgrade --bundle FILE [--allow-unsigned]
#                                    the same from an offline bundle (scripts/release/cloud-bundle.sh): no network
#   venom-cloud rollback [--restore] [--yes]
#                                    back to the previous release's image; --restore also restores the pre-upgrade backup
#   venom-cloud models [list | pull NAME]
#                                    the models of the Ollama in this stack (install-cloud.sh --models ollama)
#   venom-cloud uninstall [--keep-data] [--yes]
#   venom-cloud tick                 what cron runs every five minutes: reports this server to the console, carries out
#                                    what an admin asked for there (upgrade, roll back, back up, verify restore, export),
#                                    and runs the automatic update and the scheduled backup when they are due
#   venom-cloud verify-restore [FILE] restore a backup (default: the newest) into a scratch database, check it, drop it
#   venom-cloud backup s3-key        the access key the S3 copies are signed with, kept in .env (else the instance role)
set -eu
here="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
dir="${VENOM_CLOUD_DIR:-$here}"
[ -f "$dir/docker-compose.yml" ] || { echo "venom-cloud: no install in $dir" >&2; exit 1; }
cd "$dir"
# The release signing key (a minisign public key string); empty until the first signed release.
RELEASE_PUBKEY=""
RELEASES="${VENOM_RELEASES_URL:-https://github.com/elishahbiz/venom-releases/releases}"
RAW="${VENOM_RAW_URL:-https://raw.githubusercontent.com/elishahbiz/venom-releases/main}"
self="$(readlink -f "$0")"
say() { printf '%s\n' "$*"; }
die() { printf 'venom-cloud: %s\n' "$*" >&2; exit 1; }

envget() { sed -n "s/^$1=//p" .env | tail -1; }
envset() { # KEY VALUE: replace or append, keeping .env's mode
	{ grep -Ev "^$1=" .env || true; printf '%s=%s\n' "$1" "$2"; } >.env.new
	cat .env.new >.env
	rm -f .env.new
}
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
older() { # A B: true when version A is older than B. X.Y.Z[-pre]: a pre-release sorts before its release (semver)
	awk -v a="$1" -v b="$2" 'BEGIN {
		pa = index(a, "-"); pb = index(b, "-")
		ma = pa ? substr(a, 1, pa - 1) : a; ra = pa ? substr(a, pa + 1) : ""
		mb = pb ? substr(b, 1, pb - 1) : b; rb = pb ? substr(b, pb + 1) : ""
		split(ma, x, "."); split(mb, y, ".")
		for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
		if (ra == rb || ra == "") exit 1
		if (rb == "") exit 0
		na = split(ra, p, "."); nb = split(rb, q, ".")
		for (i = 1; i <= na && i <= nb; i++) {
			if (p[i] == q[i]) continue
			if (p[i] ~ /^[0-9]+$/ && q[i] ~ /^[0-9]+$/) exit (p[i] + 0 < q[i] + 0) ? 0 : 1
			exit (p[i] < q[i]) ? 0 : 1
		}
		exit (na < nb) ? 0 : 1
	}'
}
is_version() { case "$1" in [0-9]*.[0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*-[0-9A-Za-z]*) case "$1" in *[!0-9A-Za-z.-]*) return 1 ;; esac; return 0 ;; *) return 1 ;; esac; }
stamp() { date -u +%Y%m%dT%H%M%SZ; }
prod() { [ "$(envget VENOM_CLOUD_PROFILE)" = production ]; }
backup_dir() { d="$(envget VENOM_BACKUP_DIR)"; printf '%s\n' "${d:-$dir/backups}"; }

probe() { # one request to /api/status through this server's Caddy
	# Behind a load balancer (VENOM_TLS_MODE=proxy) Caddy serves plain HTTP; the load balancer holds the certificate.
	if [ "$(envget VENOM_TLS_MODE)" = proxy ]; then curl -fsS -o /dev/null "http://127.0.0.1/api/status" 2>/dev/null; return; fi
	origin="$(envget VENOM_CLOUD_ORIGIN)"
	host="${origin#https://}"
	# A name is resolved to this machine; an IP is asked directly (Caddy's default_sni serves its certificate).
	case "$host" in *[!0-9.:]*) set -- --resolve "$host:443:127.0.0.1" "$origin/api/status" ;; *) set -- "https://127.0.0.1/api/status" ;; esac
	curl -fsSk -o /dev/null "$@" 2>/dev/null
}

healthy() { # the app answers through the proxy, within VENOM_HEALTH_TRIES x VENOM_HEALTH_SLEEP seconds
	i=0
	while [ "$i" -lt "${VENOM_HEALTH_TRIES:-60}" ]; do
		if probe; then return 0; fi
		i=$((i + 1))
		sleep "${VENOM_HEALTH_SLEEP:-2}"
	done
	return 1
}

# dbsh SCRIPT: a shell line run where Postgres' client tools are, with $DB naming the database. Standard: inside the
# postgres container over its socket. Production: a throwaway pgtools container that reaches your database server
# (its URL comes from .env through the compose file, never a command line).
dbsh() { # SCRIPT [-e NAME=VALUE ...]
	s="$1"
	shift
	if prod; then docker compose run --rm -T "$@" pgtools sh -c "$s"
	else docker compose exec -T -e 'DB=postgresql:///venom_cloud?user=venom' "$@" postgres sh -c "$s"; fi
}

# sqlq [NAME=VALUE ...] < SQL: run SQL in one psql session; every value reaches it as a psql variable (:'NAME' in the
# SQL), passed in the container's environment, never spliced into the SQL. Prints the rows, fields joined by |.
sqlq() {
	v=""
	n=$#
	while [ "$n" -gt 0 ]; do
		kv="$1"
		shift
		k="${kv%%=*}"
		v="$v -v $k=\"\$VQ_$k\""
		set -- "$@" -e "VQ_$kv"
		n=$((n - 1))
	done
	dbsh "psql -d \"\$DB\" -X -tAq -v ON_ERROR_STOP=1 -F '|'$v" "$@"
}
hostname_() { printf '%s\n' "${VENOM_HOST_NAME:-$(hostname 2>/dev/null || uname -n)}"; }

backup_to() { # FILE
	mkdir -p "$(dirname "$1")"
	umask 077
	rm -f "$1.failed"
	{ dbsh 'pg_dump --no-owner --no-privileges -d "$DB"' || : >"$1.failed"; } | gzip >"$1"
	if [ -f "$1.failed" ]; then rm -f "$1" "$1.failed"; die "the database dump failed, so no backup was written"; fi
	gzip -t "$1" || die "the backup $1 is not a valid gzip file"
}

restore_from() { # FILE: replace the database with a dump (the app is stopped meanwhile)
	docker compose stop venom-cloud
	if prod; then
		dbsh 'psql -d "$DB" -v ON_ERROR_STOP=1 -q -c "DROP SCHEMA IF EXISTS public CASCADE" -c "CREATE SCHEMA public"'
	else
		docker compose exec -T postgres psql -U venom -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS venom_cloud WITH (FORCE)" -c "CREATE DATABASE venom_cloud"
	fi
	gunzip -c "$1" | dbsh 'psql -d "$DB" -v ON_ERROR_STOP=1 -q' >/dev/null
}

prune() { # [KEEP]: keep the newest KEEP (else VENOM_BACKUP_KEEP) scheduled backups and files archives; pre-upgrade,
	# pre-restore and manual ones stay
	keep="${1:-$(envget VENOM_BACKUP_KEEP)}"
	keep="${keep:-14}"
	# shellcheck disable=SC2012 # our own names: venom-cloud-<UTC time>.sql.gz sort by time
	ls -1 "$(backup_dir)"/venom-cloud-*.sql.gz 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while read -r f; do rm -f "$f"; done
	# shellcheck disable=SC2012 # our own names
	ls -1 "$(backup_dir)"/venom-cloud-files-*.tar.gz 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while read -r f; do rm -f "$f"; done
}

shared() { [ "$(envget VENOM_SHARED_DATABASE)" = 1 ]; }

# claim_day NAME: with a shared database, true for exactly one app server per UTC day. It uses the table the app's
# own scheduler claims its minutes in (cron_runs), so it needs nothing else. Before the app has migrated (no table
# yet) every server goes ahead.
claim_day() {
	shared || return 0
	got="$(dbsh "psql -d \"\$DB\" -tAq -v ON_ERROR_STOP=1 -c \"INSERT INTO cron_runs (path, slot) VALUES ('host:$1', date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC') ON CONFLICT DO NOTHING RETURNING 1\"" 2>/dev/null)" || return 0
	[ "$(printf '%s' "$got" | tr -d '[:space:]')" = 1 ]
}

# log_history ACTION FROM TO OK DETAIL: a line in state/history.log ("upgrade 1.2.3 -> 1.2.4 ok", "backup FILE ok")
# and, best effort, a selfhost_history row the console shows.
log_history() {
	line="$1"
	[ -z "$3" ] || line="$line ${2:-unknown} -> $3"
	[ -z "$5" ] || line="$line $5"
	[ "$4" != t ] || line="$line ok"
	mkdir -p state
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >>state/history.log
	printf '%s\n' "INSERT INTO selfhost_history (host, action, from_version, to_version, ok, detail) VALUES (:'host', :'action', nullif(:'from', ''), nullif(:'to', ''), :'ok' = 't', left(nullif(:'detail', ''), 500));" |
		sqlq host="$(hostname_)" action="$1" from="$2" to="$3" ok="$4" detail="$5" >/dev/null 2>&1 || true
}

# Preflight: nothing is touched until it passes. VENOM_PREFLIGHT_DISK_MB overrides the measurement (tests).
preflight() { # [MIN_FROM]
	problems=""
	docker info >/dev/null 2>&1 || problems="$problems
  - Docker is not running, or this user cannot use it."
	disk="${VENOM_PREFLIGHT_DISK_MB:-$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print int($4/1024)}' || echo 0)}"
	[ "${disk:-0}" -ge "${VENOM_UPGRADE_MIN_DISK_MB:-2048}" ] || problems="$problems
  - needs ${VENOM_UPGRADE_MIN_DISK_MB:-2048} MB free in $dir for the backup and the new image (found ${disk:-0} MB)."
	dbsh 'pg_isready -d "$DB"' >/dev/null 2>&1 || problems="$problems
  - the database is not reachable (docker compose ps; docker compose logs postgres, or your database server)."
	cur="$(envget VENOM_CLOUD_VERSION)"
	if [ -n "${1:-}" ] && [ -n "$cur" ] && older "$cur" "$1"; then problems="$problems
  - this release upgrades only from $1 or newer (you run $cur): upgrade to $1 first, so no migration is skipped."; fi
	if [ -n "$problems" ]; then printf 'venom-cloud: not ready to upgrade:%s\n' "$problems" >&2; exit 1; fi
}

# apply IMAGE VERSION MIN_FROM NOPULL: the upgrade proper. The running release keeps serving until the new image is here.
apply() {
	new="$1" newver="$2" minfrom="${3:-}" nopull="${4:-}"
	old="$(envget VENOM_CLOUD_IMAGE)"
	oldver="$(envget VENOM_CLOUD_VERSION)"
	[ "$new" != "$old" ] || { say "already running $new"; return 0; }
	preflight "$minfrom"
	say "preflight ok"
	if [ -z "$nopull" ]; then
		VENOM_CLOUD_IMAGE="$new" docker compose pull venom-cloud || die "could not pull $new. Nothing was changed."
	else
		docker image inspect "$new" >/dev/null 2>&1 || die "the image $new is not loaded. Nothing was changed."
	fi
	bk="$(backup_dir)/pre-upgrade-$(stamp).sql.gz"
	backup_to "$bk"
	say "backup: $bk"
	mkdir -p state
	# A failed upgrade must leave the earlier record as it was.
	rm -f state/previous.env.keep
	[ ! -f state/previous.env ] || cp state/previous.env state/previous.env.keep
	{ printf 'IMAGE=%s\n' "$old"; printf 'VERSION=%s\n' "$oldver"; printf 'BACKUP=%s\n' "$bk"; } >state/previous.env
	envset VENOM_CLOUD_IMAGE "$new"
	[ -z "$newver" ] || envset VENOM_CLOUD_VERSION "$newver"
	say "starting $new (the first start applies the migrations)..."
	if docker compose up -d --wait --pull never >/dev/null 2>&1 || docker compose up -d --wait >/dev/null 2>&1; then
		if healthy; then
			rm -f state/previous.env.keep
			log_history upgrade "$oldver" "${newver:-$new}" t ""
			say "upgraded to ${newver:-$new}. The previous release stays one command away: venom-cloud rollback"
			return 0
		fi
	fi
	printf 'venom-cloud: %s did not become healthy; rolling back\n' "$new" >&2
	if [ -f state/previous.env.keep ]; then mv state/previous.env.keep state/previous.env; else rm -f state/previous.env; fi
	envset VENOM_CLOUD_IMAGE "$old"
	envset VENOM_CLOUD_VERSION "$oldver"
	if docker compose up -d --wait >/dev/null 2>&1 && healthy; then
		log_history upgrade "$oldver" "${newver:-$new}" f "failed, rolled back"
		die "rolled back to ${oldver:-$old}. The backup is kept: $bk"
	fi
	if shared; then
		# Other app servers are running on this database: replacing it under them is a decision for a person.
		log_history upgrade "$oldver" "${newver:-$new}" f "failed, rollback failed, database shared (not restored)"
		die "the previous image does not run on the migrated database. Other app servers share it, so it is not restored by itself: stop them, then venom-cloud restore $bk --yes"
	fi
	printf 'venom-cloud: the previous image does not run on the migrated database; restoring %s\n' "$bk" >&2
	restore_from "$bk"
	if docker compose up -d --wait >/dev/null 2>&1 && healthy; then
		log_history upgrade "$oldver" "${newver:-$new}" f "failed, rolled back and restored"
		die "rolled back to ${oldver:-$old} and restored the database from $bk"
	fi
	log_history upgrade "$oldver" "${newver:-$new}" f "failed, rollback failed"
	die "the rollback did not come up either. The backup is $bk. Look at: docker compose logs venom-cloud"
}

# An offline bundle (scripts/release/cloud-bundle.sh): a tar of the release's SHA256SUMS (+ .minisig), the image
# digest file, the image as `docker save` and BUNDLE.sha256. Nothing is fetched.
bundle() { # FILE ALLOW_UNSIGNED
	[ -f "$1" ] || die "no such bundle: $1"
	work="$(mktemp -d "${TMPDIR:-/tmp}/venom-cloud-bundle.XXXXXX")"
	trap 'rm -rf "$work"' EXIT
	tar -xf "$1" -C "$work" || die "$1 is not a tar file"
	[ -f "$work/SHA256SUMS" ] || die "the bundle has no SHA256SUMS"
	if [ -f "$work/SHA256SUMS.minisig" ] && command -v minisign >/dev/null 2>&1 && [ -n "${VENOM_RELEASE_PUBKEY:-$RELEASE_PUBKEY}" ]; then
		minisign -V -q -P "${VENOM_RELEASE_PUBKEY:-$RELEASE_PUBKEY}" -m "$work/SHA256SUMS" -x "$work/SHA256SUMS.minisig" >/dev/null 2>&1 ||
			die "the bundle's SHA256SUMS signature does not verify against the release signing key: do not use this bundle"
		say "verified the release signature (minisign)"
	elif [ "$2" = 1 ]; then
		printf 'venom-cloud: warning: the bundle signature is not checked (--allow-unsigned)\n' >&2
	else
		die "cannot verify the bundle's signature (needs SHA256SUMS.minisig, minisign and the release key). If you checked the bundle another way, add --allow-unsigned."
	fi
	imgfile="$(cd "$work" && ls venom-cloud-*.image 2>/dev/null | head -1)"
	[ -n "$imgfile" ] || die "the bundle has no venom-cloud-X.Y.Z.image"
	ver="${imgfile#venom-cloud-}"
	ver="${ver%.image}"
	want="$(grep -E "^[0-9a-f]{64}  $imgfile\$" "$work/SHA256SUMS" | cut -d' ' -f1 || true)"
	[ -n "$want" ] && [ "$(sha "$work/$imgfile")" = "$want" ] || die "$imgfile does not match the signed SHA256SUMS"
	[ -f "$work/BUNDLE.sha256" ] || die "the bundle has no BUNDLE.sha256"
	tarname="venom-cloud-$ver.image.tar"
	want="$(grep -E "^[0-9a-f]{64}  $tarname\$" "$work/BUNDLE.sha256" | cut -d' ' -f1 || true)"
	[ -n "$want" ] && [ "$(sha "$work/$tarname")" = "$want" ] || die "$tarname does not match BUNDLE.sha256: the bundle was damaged in transit"
	minfrom=""
	[ ! -f "$work/venom-cloud-$ver.min-from" ] || minfrom="$(tr -d '[:space:]' <"$work/venom-cloud-$ver.min-from")"
	local_ref="$(sed -n 's/^REF=//p' "$work/BUNDLE.sha256")"
	[ -n "$local_ref" ] || die "BUNDLE.sha256 names no image reference"
	docker load -i "$work/$tarname" >/dev/null || die "docker could not load the image"
	apply "$local_ref" "$ver" "$minfrom" 1
}


# --- the console's requests and schedules (VEN-323) -------------------------------------------------------------
# The app writes selfhost_settings and selfhost_requests; `venom-cloud tick` reads them through psql here and writes
# selfhost_hosts and selfhost_history back. Before the app has migrated (no tables yet) every query fails quietly.

# load_settings: S_* from the selfhost_settings row (S_row=1), or the defaults (S_row=0).
load_settings() {
	S_row=0 S_auto=f S_level=patch S_channel=stable S_wday=0 S_whour=4 S_tz=UTC S_bsched="" S_bday=0 S_bhour=3
	S_keep="" S_files=t S_target=local S_s3url="" S_s3ep="" S_s3region="" S_s3path=f
	row="$(printf '%s\n' "SELECT auto_update, update_level, channel, window_day, window_hour, time_zone, coalesce(backup_schedule, ''), backup_day, backup_hour, backup_keep, backup_files, backup_target, coalesce(s3_url, ''), coalesce(s3_endpoint, ''), coalesce(s3_region, ''), s3_path_style FROM selfhost_settings WHERE id;" | sqlq 2>/dev/null | head -1)" || row=""
	[ -n "$row" ] || return 0
	# shellcheck disable=SC2034 # read by the callers
	IFS='|' read -r S_auto S_level S_channel S_wday S_whour S_tz S_bsched S_bday S_bhour S_keep S_files S_target S_s3url S_s3ep S_s3region S_s3path <<EOF
$row
EOF
	S_row=1
}

# The bucket the backups are copied to, or nothing. The console's choice when it set one; while the console leaves the
# schedule as installed, the installer's VENOM_BACKUP_S3 (the AWS profile's bucket).
s3_target() {
	if [ "$S_target" = s3 ]; then printf '%s\n' "${S_s3url:-$(envget VENOM_BACKUP_S3)}"; return; fi
	[ -n "$S_bsched" ] || envget VENOM_BACKUP_S3
}

# local_now: "weekday hour date" in the console's time zone (0 is Sunday). VENOM_NOW_LOCAL overrides it (tests).
local_now() { if [ -n "${VENOM_NOW_LOCAL:-}" ]; then printf '%s\n' "$VENOM_NOW_LOCAL"; else TZ="${S_tz:-UTC}" date +'%w %H %Y-%m-%d'; fi; }
num() { n_="${1#0}"; printf '%s\n' "${n_:-0}"; }

# --- S3: a SigV4-signed PUT with openssl and curl (AWS Signature Version 4, the same maths as the app's lib/export/sigv4.ts)
sha_str() { printf '%s' "$1" | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1; }
hmac_hex() { printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | sed 's/^.*= *//'; }
hexof() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }
# s3_auth METHOD PATH PAYLOAD_HASH AMZDATE REGION ACCESS_KEY HEADERS [QUERY]: the Authorization header's value. HEADERS
# are "name:value" lines (lower-case names, every one signed); QUERY the canonical query string (sorted by name, values
# uri_enc'd); the secret key comes in S3_SECRET, never an argument.
s3_auth() {
	hdrs="$(printf '%s\n' "$7" | LC_ALL=C sort)"
	signed="$(printf '%s\n' "$hdrs" | cut -d: -f1 | paste -sd';' -)"
	creq="$(printf '%s\n%s\n%s\n%s\n\n%s\n%s' "$1" "$2" "${8:-}" "$hdrs" "$signed" "$3")"
	day="$(printf '%s' "$4" | cut -c1-8)"
	scope="$day/$5/s3/aws4_request"
	sts="$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' "$4" "$scope" "$(sha_str "$creq")")"
	k="$(hmac_hex "$(hexof "AWS4$S3_SECRET")" "$day")"
	k="$(hmac_hex "$k" "$5")"
	k="$(hmac_hex "$k" s3)"
	k="$(hmac_hex "$k" aws4_request)"
	printf 'AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s\n' "$6" "$scope" "$signed" "$(hmac_hex "$k" "$sts")"
}

IMDS="${VENOM_IMDS_URL:-http://169.254.169.254}"
# s3_creds: S3_KEY, S3_SECRET, S3_TOKEN and S3_SOURCE (keys | instance-role | none): the keys in .env, else the EC2
# instance role through IMDSv2 (the AWS profile's servers may write to their bucket).
s3_creds() {
	S3_KEY="$(envget VENOM_BACKUP_S3_ACCESS_KEY_ID)" S3_SECRET="$(envget VENOM_BACKUP_S3_SECRET_ACCESS_KEY)" S3_TOKEN="" S3_IMDS_REGION=""
	if [ -n "$S3_KEY" ] && [ -n "$S3_SECRET" ]; then S3_SOURCE=keys; return 0; fi
	S3_SOURCE=none S3_KEY="" S3_SECRET=""
	t="$(curl -fsS -m 2 -X PUT "$IMDS/latest/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null)" || return 1
	role="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/latest/meta-data/iam/security-credentials/" 2>/dev/null | head -1)" || return 1
	[ -n "$role" ] || return 1
	j="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/latest/meta-data/iam/security-credentials/$role" 2>/dev/null)" || return 1
	S3_KEY="$(printf '%s\n' "$j" | sed -n 's/.*"AccessKeyId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	S3_SECRET="$(printf '%s\n' "$j" | sed -n 's/.*"SecretAccessKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	S3_TOKEN="$(printf '%s\n' "$j" | sed -n 's/.*"Token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	S3_IMDS_REGION="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $t" "$IMDS/latest/meta-data/placement/region" 2>/dev/null || true)"
	[ -n "$S3_KEY" ] && [ -n "$S3_SECRET" ] || return 1
	S3_SOURCE=instance-role
}

# s3_put FILE BUCKET_URL: copy FILE to s3://bucket/prefix/<its name>; prints the object key. Outbound only to that bucket.
s3_put() {
	rest="${2#s3://}"
	bucket="${rest%%/*}"
	prefix="${rest#"$bucket"}"
	prefix="${prefix#/}"
	prefix="${prefix%/}"
	key="${prefix:+$prefix/}$(basename "$1")"
	case "$bucket$key" in *[!A-Za-z0-9._/-]*) echo "the bucket or prefix has characters a backup key cannot use: $2" >&2; return 1 ;; esac
	[ -n "$bucket" ] || { echo "no bucket in $2" >&2; return 1; }
	s3_creds || true
	[ "$S3_SOURCE" != none ] || { echo "no credentials for the bucket: run venom-cloud backup s3-key, or give the server an instance role that may write to it" >&2; return 1; }
	region="${S_s3region:-$(envget VENOM_BACKUP_S3_REGION)}"
	region="${region:-${S3_IMDS_REGION:-us-east-1}}"
	ep="${S_s3ep:-$(envget VENOM_BACKUP_S3_ENDPOINT)}"
	ep="${ep%/}"
	path_style="$S_s3path"
	[ "$S_s3path" = t ] || [ "$(envget VENOM_BACKUP_S3_PATH_STYLE)" != 1 ] || path_style=t
	if [ -z "$ep" ]; then ep="https://s3.$region.amazonaws.com"; fi
	case "$ep" in https://* | http://*) ;; *) echo "the S3 endpoint must be an https:// URL: $ep" >&2; return 1 ;; esac
	scheme="${ep%%://*}"
	h="${ep#*://}"
	h="${h%%/*}"
	if [ "$path_style" = t ]; then path="/$bucket/$key"; else h="$bucket.$h"; path="/$key"; fi
	url="$scheme://$h$path"
	f="$1"
	size="$(wc -c <"$f" | tr -d ' ')"
	pmb="${VENOM_BACKUP_S3_PART_MB:-$(envget VENOM_BACKUP_S3_PART_MB)}"
	case "$pmb" in '' | *[!0-9]*) pmb=256 ;; esac
	[ "$pmb" -ge 5 ] || pmb=5
	if [ "$size" -gt $((pmb * 1048576)) ]; then
		s3_multipart "$f" "$size" "$pmb" || return 1
	else
		s3_req PUT "" "$f" -o /dev/null || { echo "the bucket refused the upload of $(basename "$f") ($url)" >&2; return 1; }
	fi
	printf '%s\n' "$key"
}

# s3_req METHOD QUERY BODY [CURL_ARGS...]: one SigV4-signed request for the object s3_put resolved (h, path, url, region,
# S3_*). QUERY is canonical already (uploads=, partNumber=N&uploadId=ID); BODY a file, or "" for none.
s3_req() {
	m_="$1" q_="$2" b_="$3"
	shift 3
	when="$(stamp)"
	if [ -n "$b_" ]; then ph="$(sha "$b_")"; else ph=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855; fi
	hdrs="host:$h
x-amz-content-sha256:$ph
x-amz-date:$when"
	[ -z "$S3_TOKEN" ] || hdrs="$hdrs
x-amz-security-token:$S3_TOKEN"
	auth="$(S3_SECRET="$S3_SECRET" s3_auth "$m_" "$path" "$ph" "$when" "$region" "$S3_KEY" "$hdrs" "$q_")"
	set -- "$@" -H "Authorization: $auth" -H "x-amz-content-sha256: $ph" -H "x-amz-date: $when"
	[ -z "$S3_TOKEN" ] || set -- "$@" -H "x-amz-security-token: $S3_TOKEN"
	if [ "$m_" = PUT ]; then set -- "$@" -T "$b_"
	elif [ -n "$b_" ]; then set -- "$@" --data-binary "@$b_"
	elif [ "$m_" = POST ]; then set -- "$@" --data-binary ''; fi
	curl -fsS -X "$m_" "$@" "$url${q_:+?$q_}"
}

# uri_enc STRING: percent-encoded as SigV4 wants (everything but A-Z a-z 0-9 - . _ ~).
uri_enc() {
	printf '%s' "$1" | od -An -v -tx1 | tr -s ' ' '\n' | while read -r x; do
		[ -n "$x" ] || continue
		case "$x" in
		2d | 2e | 5f | 7e | 3[0-9] | 4[1-9a-f] | 5[0-9a] | 6[1-9a-f] | 7[0-9a]) printf "\\$(printf '%03o' "$((0x$x))")" ;;
		*) printf '%%%s' "$(printf '%s' "$x" | tr a-f A-F)" ;;
		esac
	done
}

# s3_multipart FILE BYTES PART_MB: S3's multipart upload, for backups past one PUT's 5 GB limit. Parts of PART_MB
# (VENOM_BACKUP_S3_PART_MB, default 256; more when 10,000 parts would not hold the file), each cut to a temporary file
# next to the backup, then completed. A part that fails (after curl's retries) aborts the upload, so the bucket keeps
# no half-uploaded parts to bill for.
s3_multipart() {
	pmb="$3"
	while [ "$2" -gt $((pmb * 1048576 * 10000)) ]; do pmb=$((pmb * 2)); done
	pd="$(mktemp -d "$(dirname "$1")/.s3-parts.XXXXXX")" || return 1
	if ! s3_req POST uploads= "" -o "$pd/r"; then
		rm -rf "$pd"
		echo "the bucket refused to start a multipart upload of $(basename "$1") ($url)" >&2
		return 1
	fi
	uid="$(tr -d '\r\n' <"$pd/r" | sed -n 's:.*<UploadId>\([^<]*\)</UploadId>.*:\1:p')"
	[ -n "$uid" ] || { rm -rf "$pd"; echo "the bucket started no multipart upload of $(basename "$1") ($url)" >&2; return 1; }
	qid="$(uri_enc "$uid")"
	n=1 err=""
	: >"$pd/parts"
	while [ $(((n - 1) * pmb)) -lt $((($2 + 1048575) / 1048576)) ]; do
		if ! dd if="$1" of="$pd/part" bs=1048576 skip=$(((n - 1) * pmb)) count="$pmb" 2>/dev/null; then err="could not read part $n"; break; fi
		if ! s3_req PUT "partNumber=$n&uploadId=$qid" "$pd/part" --retry 2 -D "$pd/h" -o /dev/null; then err="the bucket refused part $n"; break; fi
		etag="$(sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' "$pd/h" | tr -d '\r' | tail -1)"
		[ -n "$etag" ] || { err="the bucket gave part $n no ETag"; break; }
		printf '<Part><PartNumber>%s</PartNumber><ETag>%s</ETag></Part>' "$n" "$etag" >>"$pd/parts"
		n=$((n + 1))
	done
	if [ -z "$err" ]; then
		{ printf '<CompleteMultipartUpload>'; cat "$pd/parts"; printf '</CompleteMultipartUpload>'; } >"$pd/done.xml"
		# S3 can answer 200 and still put an <Error> in the body of a complete.
		if ! s3_req POST "uploadId=$qid" "$pd/done.xml" -H 'Content-Type: application/xml' -o "$pd/r" || grep -q '<Error>' "$pd/r"; then
			err="the bucket did not complete the upload"
		fi
	fi
	if [ -n "$err" ]; then
		if s3_req DELETE "uploadId=$qid" "" -o /dev/null; then ab="the multipart upload was aborted"; else ab="aborting the multipart upload failed too (upload id $uid)"; fi
		rm -rf "$pd"
		echo "$err of $(basename "$1") after $((n - 1)) parts; $ab" >&2
		return 1
	fi
	rm -rf "$pd"
}

# --- backups: the database, the install's files, retention, the copy to the bucket --------------------------------
files_archive() { # FILE: .env, the Caddyfile, the compose file, the CA bundle and state/ (it holds the secrets: mode 600)
	set -- "$1" .env docker-compose.yml
	for x in Caddyfile database-ca.pem state; do [ ! -e "$x" ] || set -- "$@" "$x"; done
	out_="$1"
	shift
	mkdir -p "$(dirname "$out_")"
	(umask 077 && tar -czf "$out_" "$@")
}

record_backup() { # OK FILE BYTES S3KEY MESSAGE
	printf '%s\n' "UPDATE selfhost_hosts SET last_backup_at = now(), last_backup_ok = :'ok' = 't', last_backup_file = nullif(:'file', ''), last_backup_bytes = nullif(:'bytes', '')::bigint, last_backup_s3 = nullif(:'s3key', ''), last_backup_message = left(nullif(:'msg', ''), 500) WHERE host = :'host';" |
		sqlq host="$(hostname_)" ok="$1" file="$2" bytes="$3" s3key="$4" msg="$5" >/dev/null 2>&1 || true
}

# full_backup scheduled|manual: the dump, the files archive (unless the console turned it off), retention for the
# scheduled ones, then the copy to the bucket when one is set. Needs load_settings first.
full_backup() {
	bd="$(backup_dir)"
	if [ "$1" = scheduled ]; then base=venom-cloud; else base=manual; fi
	ts="$(stamp)"
	while [ -e "$bd/$base-$ts.sql.gz" ]; do sleep 1; ts="$(stamp)"; done
	db="$bd/$base-$ts.sql.gz" fa="$bd/$base-files-$ts.tar.gz"
	if ! (backup_to "$db"); then
		record_backup f "" "" "" "the database dump failed"
		log_history backup "" "" f "the database dump failed"
		return 1
	fi
	[ "$S_files" = f ] || files_archive "$fa"
	if [ "$1" = scheduled ]; then prune "$S_keep"; fi
	bytes="$(wc -c <"$db" | tr -d ' ')"
	bucket="$(s3_target)"
	s3key=""
	if [ -n "$bucket" ]; then
		if ! s3key="$(s3_put "$db" "$bucket" 2>"$bd/.s3.err")" || { [ ! -f "$fa" ] || ! (s3_put "$fa" "$bucket") >/dev/null 2>>"$bd/.s3.err"; }; then
			msg="kept on this server; the copy to $bucket failed: $(tail -1 "$bd/.s3.err")"
			rm -f "$bd/.s3.err"
			record_backup f "$(basename "$db")" "$bytes" "" "$msg"
			log_history backup "" "" f "$db: $msg"
			echo "backup: $db ($msg)" >&2
			return 1
		fi
		rm -f "$bd/.s3.err"
	fi
	record_backup t "$(basename "$db")" "$bytes" "$s3key" "${s3key:+copied to $bucket}"
	log_history backup "" "" t "$db"
	echo "backup: $db${s3key:+, copied to $bucket}"
}

# shellcheck disable=SC2012 # our own names
newest_dump() { ls -1t "$(backup_dir)"/*.sql.gz 2>/dev/null | head -1; }

# verify_restore [NAME]: load a backup into a scratch database, check it holds the app's schema, drop it. The live
# database is never touched. NAME is a backup's file name in the backup directory (the console sends only names).
verify_restore() {
	if [ -n "${1:-}" ]; then
		case "$1" in */*) f="$1" ;; *) f="$(backup_dir)/$1" ;; esac
	else
		f="$(newest_dump)"
	fi
	why=""
	if [ -z "$f" ] || [ ! -f "$f" ]; then why="no backup to verify${1:+ ($1)}"
	elif ! gzip -t "$f" 2>/dev/null; then why="$(basename "$f") is not a valid gzip file"; fi
	if [ -z "$why" ]; then
		scratch="venom_verify_$(date -u +%Y%m%d%H%M%S)"
		err="$(dbsh "psql -d \"\$DB\" -X -q -v ON_ERROR_STOP=1 -c 'CREATE DATABASE $scratch'" 2>&1 >/dev/null)" || {
			case "$err" in *"permission denied"*) why="the database role may not create a scratch database (grant it CREATEDB, or verify on a copy)" ;; *) why="could not create a scratch database: $(printf '%s' "$err" | tail -1)" ;; esac
			scratch=""
		}
	fi
	if [ -z "$why" ]; then
		if ! { printf '\\connect %s\n' "$scratch"; gunzip -c "$f"; } | dbsh 'psql -d "$DB" -X -q -v ON_ERROR_STOP=1' >/dev/null 2>"$dir/state/.verify.err"; then
			why="the backup did not load: $(tail -1 "$dir/state/.verify.err" 2>/dev/null)"
		else
			got="$(printf '\\connect %s\nSELECT (SELECT count(*) FROM schema_migrations), (SELECT count(*) FROM tenants);\n' "$scratch" | sqlq 2>/dev/null | tail -1)" || got=""
			migs="${got%%|*}" orgs="${got#*|}"
			case "$migs" in '' | 0 | *[!0-9]*) why="the restored database has no migrations recorded (schema_migrations)" ;; esac
		fi
		rm -f "$dir/state/.verify.err"
	fi
	[ -z "${scratch:-}" ] || dbsh "psql -d \"\$DB\" -X -q -c 'DROP DATABASE IF EXISTS $scratch WITH (FORCE)'" >/dev/null 2>&1 || true
	name="$(basename "${f:-none}")"
	if [ -n "$why" ]; then msg="$why"; ok=f; else msg="$name restored into a scratch database: $migs migrations, $orgs organisations"; ok=t; fi
	printf '%s\n' "UPDATE selfhost_hosts SET last_verify_at = now(), last_verify_ok = :'ok' = 't', last_verify_message = left(:'msg', 500) WHERE host = :'host';" |
		sqlq host="$(hostname_)" ok="$ok" msg="$msg" >/dev/null 2>&1 || true
	if [ "$ok" = t ]; then log_history verify "" "" t "$name"; say "$msg"; return 0; fi
	log_history verify "" "" f "$name failed: $why"
	echo "venom-cloud: verify restore failed: $why" >&2
	return 1
}

# export_to RID: a fresh dump and the files in one tar.gz, handed to the console as a large object for 24 hours.
export_to() {
	work="$(mktemp -d "${TMPDIR:-/tmp}/venom-cloud-export.XXXXXX")"
	ts="$(stamp)"
	name="venom-cloud-export-$ts.tar.gz"
	mkdir -p "$work/x"
	(backup_to "$work/x/venom-cloud-$ts.sql.gz") || { rm -rf "$work"; echo "the database dump failed" >&2; return 1; }
	files_archive "$work/x/venom-cloud-files-$ts.tar.gz"
	(umask 077 && tar -czf "$work/$name" -C "$work/x" .)
	bytes="$(wc -c <"$work/$name" | tr -d ' ')"
	max=$(( ${VENOM_EXPORT_MAX_MB:-2048} * 1048576 ))
	if [ "$bytes" -gt "$max" ]; then rm -rf "$work"; echo "the export is larger than ${VENOM_EXPORT_MAX_MB:-2048} MB: on the server, run venom-cloud backup and copy the file" >&2; return 1; fi
	# The archive goes to the psql container's /tmp, then psql's client-side \lo_import stores it and :LASTOID names it.
	# shellcheck disable=SC2016 # expanded inside the container
	dbsh 'cat >/tmp/venom-export.tgz && printf "%s\n" "\\lo_import /tmp/venom-export.tgz" "UPDATE selfhost_requests SET artifact_oid = :LASTOID, artifact_name = :'"'"'name'"'"', artifact_bytes = :'"'"'bytes'"'"'::bigint, expires_at = now() + interval '"'"'24 hours'"'"' WHERE id = :'"'"'rid'"'"';" | psql -d "$DB" -X -q -v ON_ERROR_STOP=1 -v rid="$VQ_rid" -v name="$VQ_name" -v bytes="$VQ_bytes" >/dev/null; rc=$?; rm -f /tmp/venom-export.tgz; exit $rc' \
		-e "VQ_rid=$1" -e "VQ_name=$name" -e "VQ_bytes=$bytes" <"$work/$name" || { rm -rf "$work"; echo "could not hand the export to the console (large object import failed)" >&2; return 1; }
	bucket="$(s3_target)"
	[ -z "$bucket" ] || s3_put "$work/$name" "$bucket" >/dev/null || true
	rm -rf "$work"
	log_history export "" "" t "$name"
	echo "export ready: $name ($bytes bytes, for 24 hours)"
}

# --- updates: the channel's newest release, and which one an automatic update may take ----------------------------
latest_on() { # CHANNEL
	if [ "$1" = preview ]; then
		curl -fsSL "$RAW/CHANNELS" 2>/dev/null | sed -n 's/^preview[[:space:]][[:space:]]*\([0-9][0-9A-Za-z.-]*\)[[:space:]]*$/\1/p' | head -1
	else
		u="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES/latest" 2>/dev/null)" && printf '%s\n' "${u##*/v}"
	fi
}
# newest_patch X.Y.Z[-pre]: the highest X.Y.n released after it (each probed in turn, at most 50), or nothing.
newest_patch() {
	b="${1%%-*}"
	mm="${b%.*}"
	p="${b##*.}"
	case "$1" in *-*) n_=$p ;; *) n_=$((p + 1)) ;; esac
	best="" i=0
	while [ "$i" -lt 50 ] && curl -fsSLI -o /dev/null "$RELEASES/download/v$mm.$n_/SHA256SUMS" 2>/dev/null; do
		best="$mm.$n_"
		n_=$((n_ + 1))
		i=$((i + 1))
	done
	printf '%s\n' "$best"
}
# pick_target CURRENT LEVEL CHANNEL LATEST: the release an automatic update moves to (never a major; patch: the same
# major.minor; pre-releases only on preview), or nothing.
pick_target() {
	cur="$1" lat="$4"
	is_version "$lat" && is_version "$cur" || return 0
	case "$lat" in *-*) [ "$3" = preview ] || return 0 ;; esac
	older "$cur" "$lat" || return 0
	cb="${cur%%-*}" lb="${lat%%-*}"
	if [ "${cb%%.*}" != "${lb%%.*}" ] || { [ "$2" != minor ] && [ "${cb%.*}" != "${lb%.*}" ]; }; then
		newest_patch "$cur"
		return 0
	fi
	printf '%s\n' "$lat"
}

record_check() { # AVAILABLE
	printf '%s\n' "UPDATE selfhost_hosts SET last_check_at = now(), available_version = nullif(:'v', '') WHERE host = :'host';" |
		sqlq host="$(hostname_)" v="$1" >/dev/null 2>&1 || true
}

# auto_update: in the window, once, the newest release the console's level allows.
auto_update() {
	[ "$S_auto" = t ] || return 0
	# shellcheck disable=SC2046 # three words
	set -- $(local_now)
	wday="$1" hour="$(num "$2")" today="$3"
	{ [ "$S_wday" = 7 ] || [ "$wday" = "$S_wday" ]; } && [ "$hour" = "$S_whour" ] || return 0
	wkey="$today-$hour"
	[ "$(cat state/last-auto-update 2>/dev/null)" != "$wkey" ] || return 0
	mkdir -p state
	printf '%s\n' "$wkey" >state/last-auto-update
	cur="$(envget VENOM_CLOUD_VERSION)"
	lat="$(latest_on "$S_channel" || true)"
	target="$(pick_target "${cur:-0.0.0}" "$S_level" "$S_channel" "$lat")"
	record_check "${lat:-}"
	[ -n "$target" ] || { say "automatic update: nothing newer allowed (running ${cur:-unknown}, newest ${lat:-unknown})"; return 0; }
	say "automatic update: $cur -> $target"
	"$self" upgrade --yes --version "$target" || true
}

# scheduled: the console's backup schedule, once a day (one server a day with a shared database).
scheduled() {
	case "$S_bsched" in daily | weekly) ;; *) return 0 ;; esac
	# shellcheck disable=SC2046 # three words
	set -- $(local_now)
	wday="$1" hour="$(num "$2")" today="$3"
	[ "$hour" = "$S_bhour" ] || return 0
	[ "$S_bsched" = daily ] || [ "$wday" = "$S_bday" ] || return 0
	[ "$(cat state/last-scheduled-backup 2>/dev/null)" != "$today" ] || return 0
	mkdir -p state
	printf '%s\n' "$today" >state/last-scheduled-backup
	claim_day backup || { say "another app server took today's scheduled backup"; return 0; }
	full_backup scheduled || true
}

# run_request ID KIND VERSION FILE: carry out one console request; prints its outcome's last line.
run_request() {
	case "$2" in
	upgrade)
		if [ -n "$3" ]; then is_version "$3" || { echo "not a version: $3"; return 1; }; "$self" upgrade --yes --version "$3"
		else "$self" upgrade --yes; fi ;;
	rollback) "$self" rollback --yes ;;
	backup) (full_backup manual) ;;
	verify_restore)
		# The console sends a backup's name, never a path: it is looked up in this server's backup directory only.
		if [ -n "$4" ] && ! printf '%s\n' "$4" | grep -Eqx '[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.sql\.gz'; then echo "not a backup name: $4"; return 1; fi
		(verify_restore "$4") ;;
	export) (export_to "$1") ;;
	*) echo "unknown request $2"; return 1 ;;
	esac
}

tick() {
	mkdir -p state
	# One tick at a time: an upgrade outlasts the five minutes. A lock older than two hours is a crashed tick's.
	if ! mkdir state/tick.lock 2>/dev/null; then
		[ -n "$(find state/tick.lock -prune -mmin +120 2>/dev/null)" ] || { say "another tick is running"; return 0; }
		rm -rf state/tick.lock
		mkdir state/tick.lock
	fi
	trap 'rmdir "$dir/state/tick.lock" 2>/dev/null || true' EXIT
	host="$(hostname_)"
	load_settings
	# The console's channel is the one `venom-cloud upgrade` resolves.
	[ "$S_row" = 0 ] || [ "$(envget VENOM_CHANNEL)" = "$S_channel" ] || envset VENOM_CHANNEL "$S_channel"
	# `install-cloud.sh --auto-update yes`: switched on in the console's settings once (they decide from then on).
	if [ "$(envget VENOM_AUTO_UPDATE)" = yes ] && [ ! -f state/auto-update-seeded ]; then
		printf '%s\n' "INSERT INTO selfhost_settings (id, auto_update) VALUES (true, true) ON CONFLICT DO NOTHING;" | sqlq >/dev/null 2>&1 &&
			{ : >state/auto-update-seeded; load_settings; }
	fi
	pimg="" pver=""
	if [ -f state/previous.env ]; then pimg="$(sed -n 's/^IMAGE=//p' state/previous.env)"; pver="$(sed -n 's/^VERSION=//p' state/previous.env)"; fi
	bucket="$(s3_target)"
	creds=none
	if [ -n "$(envget VENOM_BACKUP_S3_ACCESS_KEY_ID)" ] && [ -n "$(envget VENOM_BACKUP_S3_SECRET_ACCESS_KEY)" ]; then creds=keys
	elif [ -n "$bucket" ] && s3_creds; then creds="$S3_SOURCE"; fi
	printf '%s\n' "INSERT INTO selfhost_hosts (host, version, image, previous_version, previous_image, profile, shared_database, backup_dir, backup_s3, s3_credentials, seen_at) VALUES (:'host', nullif(:'version', ''), nullif(:'image', ''), nullif(:'pver', ''), nullif(:'pimg', ''), nullif(:'profile', ''), :'shared' = '1', :'bdir', nullif(:'s3', ''), :'creds', now()) ON CONFLICT (host) DO UPDATE SET version = EXCLUDED.version, image = EXCLUDED.image, previous_version = EXCLUDED.previous_version, previous_image = EXCLUDED.previous_image, profile = EXCLUDED.profile, shared_database = EXCLUDED.shared_database, backup_dir = EXCLUDED.backup_dir, backup_s3 = EXCLUDED.backup_s3, s3_credentials = EXCLUDED.s3_credentials, seen_at = now();" |
		sqlq host="$host" version="$(envget VENOM_CLOUD_VERSION)" image="$(envget VENOM_CLOUD_IMAGE)" pver="$pver" pimg="$pimg" \
			profile="$(envget VENOM_CLOUD_PROFILE)" shared="$(envget VENOM_SHARED_DATABASE)" bdir="$(backup_dir)" s3="$bucket" creds="$creds" >/dev/null 2>&1 || true
	# The console's requests, oldest first, one at a time (at most five a tick).
	i=0
	while [ "$i" -lt 5 ]; do
		i=$((i + 1))
		req="$(printf '%s\n' "UPDATE selfhost_requests SET host = :'host', claimed_at = now() WHERE id = (SELECT id FROM selfhost_requests WHERE claimed_at IS NULL AND (target_host IS NULL OR target_host = :'host') ORDER BY requested_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING id, kind, coalesce(args->>'version', ''), coalesce(args->>'file', '');" | sqlq host="$host" 2>/dev/null | head -1)" || req=""
		[ -n "$req" ] || break
		IFS='|' read -r rid kind rver rfile <<EOF
$req
EOF
		say "request $kind ($rid)"
		if out="$(run_request "$rid" "$kind" "$rver" "$rfile" 2>&1)"; then rok=t; else rok=f; fi
		printf '%s\n' "$out"
		msg="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -1 | sed 's/^venom-cloud: //' | cut -c1-300)"
		printf '%s\n' "UPDATE selfhost_requests SET finished_at = now(), ok = :'ok' = 't', message = left(nullif(:'msg', ''), 500) WHERE id = :'rid';" |
			sqlq rid="$rid" ok="$rok" msg="$msg" >/dev/null 2>&1 || true
		load_settings
	done
	scheduled
	auto_update
	# Exports past their 24 hours.
	printf '%s\n' "BEGIN;" "SELECT lo_unlink(artifact_oid) FROM selfhost_requests WHERE artifact_oid IS NOT NULL AND expires_at < now();" \
		"UPDATE selfhost_requests SET artifact_oid = NULL WHERE artifact_oid IS NOT NULL AND expires_at < now();" "COMMIT;" | sqlq >/dev/null 2>&1 || true
}

main() {
cmd="${1:-status}"
[ $# -eq 0 ] || shift
case "$cmd" in
status)
	docker compose ps
	origin="$(envget VENOM_CLOUD_ORIGIN)"
	if [ "$(envget VENOM_BACKUPS)" = daily ]; then
		# shellcheck disable=SC2012 # our own names
		last="$(ls -1 "$(backup_dir)"/venom-cloud-*.sql.gz 2>/dev/null | sort -r | head -1)"
		echo "backups: daily into $(backup_dir), newest ${last:-none yet}"
	fi
	[ "$(envget VENOM_SHARED_DATABASE)" != 1 ] || echo "database: shared with other app servers (one of them takes each day's scheduled backup)"
	if probe; then echo "$origin: up (version $(envget VENOM_CLOUD_VERSION))"; else echo "$origin: not answering"; exit 1; fi
	;;
logs) exec docker compose logs -f --tail=200 "$@" ;;
backup)
	case "${1:-}" in
	--list)
		# shellcheck disable=SC2012 # our own names
		ls -1t "$(backup_dir)"/*.sql.gz 2>/dev/null || echo "no backups in $(backup_dir)"
		;;
	--scheduled)
		load_settings
		if [ -n "$S_bsched" ]; then
			echo "the console sets the backup schedule (Settings, Server backups): venom-cloud tick takes them"
			exit 0
		fi
		if ! claim_day backup; then
			echo "another app server took today's scheduled backup"
			exit 0
		fi
		full_backup scheduled
		;;
	s3-key)
		# The key the S3 copies are signed with (else the instance role). From the environment, or asked; never shown.
		id="${VENOM_BACKUP_S3_ACCESS_KEY_ID:-}" secret="${VENOM_BACKUP_S3_SECRET_ACCESS_KEY:-}"
		if [ -z "$id" ] && { : </dev/tty; } 2>/dev/null; then printf 'Access key id: ' >/dev/tty; read -r id </dev/tty || id=""; fi
		if [ -z "$secret" ] && { : </dev/tty; } 2>/dev/null; then
			printf 'Secret access key (not shown): ' >/dev/tty
			stty -echo </dev/tty 2>/dev/null || true
			read -r secret </dev/tty || secret=""
			stty echo </dev/tty 2>/dev/null || true
			printf '\n' >/dev/tty
		fi
		[ -n "$id" ] && [ -n "$secret" ] || die "needs both: VENOM_BACKUP_S3_ACCESS_KEY_ID and VENOM_BACKUP_S3_SECRET_ACCESS_KEY in the environment, or typed at the prompts"
		envset VENOM_BACKUP_S3_ACCESS_KEY_ID "$id"
		envset VENOM_BACKUP_S3_SECRET_ACCESS_KEY "$secret"
		say "kept the access key in $dir/.env (mode 600). The next backup copies to the bucket with it."
		;;
	*)
		out="${1:-$(backup_dir)/venom-cloud-$(stamp).sql.gz}"
		backup_to "$out"
		echo "backup: $out (the secrets are in $dir/.env: keep a copy of it too)"
		;;
	esac
	;;
restore)
	file="" yes=0
	for a in "$@"; do
		case "$a" in --yes | -y) yes=1 ;; -*) echo "venom-cloud: unknown argument $a" >&2; exit 2 ;; *) file="$a" ;; esac
	done
	[ -n "$file" ] || die "usage: venom-cloud restore FILE --yes (venom-cloud backup --list shows the backups)"
	[ -f "$file" ] || die "no such backup: $file"
	gzip -t "$file" 2>/dev/null || die "$file is not a gzip'd SQL dump from venom-cloud backup"
	[ "$yes" = 1 ] || die "restore replaces the database with $file: everything written since it was taken is lost. Add --yes to confirm."
	safety="$(backup_dir)/pre-restore-$(stamp).sql.gz"
	backup_to "$safety"
	say "the database as it was: $safety"
	restore_from "$file"
	docker compose up -d --wait >/dev/null 2>&1 && healthy || die "restored $file, but the app did not become healthy. The database as it was before is in $safety. Look at: docker compose logs venom-cloud"
	log_history restore "" "" t "$file"
	say "restored $file"
	;;
upgrade)
	file="" allow=0
	rest=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--bundle) file="${2:?--bundle needs a file}"; shift 2 ;;
		--allow-unsigned) allow=1; shift ;;
		*) rest="$rest $1"; shift ;;
		esac
	done
	if [ -n "$file" ]; then
		bundle "$file" "$allow"
	else
		# The installer resolves the release (SHA256SUMS, signature, digest), then calls `venom-cloud apply`.
		inst="$(mktemp "${TMPDIR:-/tmp}/venom-cloud-installer.XXXXXX")"
		curl -fsSL -o "$inst" "$RAW/install-cloud.sh" || { rm -f "$inst"; die "could not download the installer from $RAW"; }
		rc=0
		# shellcheck disable=SC2086
		sh "$inst" --upgrade --dir "$dir" $rest || rc=$?
		rm -f "$inst"
		return "$rc"
	fi
	;;
apply) apply "${1:?image}" "${2:-}" "${3:-}" "" ;; # called by install-cloud.sh --upgrade
rollback)
	restore=0 yes=0
	for a in "$@"; do
		case "$a" in --restore) restore=1 ;; --yes | -y) yes=1 ;; *) echo "venom-cloud: unknown argument $a" >&2; exit 2 ;; esac
	done
	[ -f state/previous.env ] || die "there is no previous release recorded: nothing to roll back to."
	pimg="$(sed -n 's/^IMAGE=//p' state/previous.env)"
	pver="$(sed -n 's/^VERSION=//p' state/previous.env)"
	pbk="$(sed -n 's/^BACKUP=//p' state/previous.env)"
	[ -n "$pimg" ] || die "the recorded previous release has no image: nothing to roll back to."
	if [ "$restore" = 1 ]; then
		[ -f "$pbk" ] || die "the pre-upgrade backup $pbk is gone."
		[ "$yes" = 1 ] || die "--restore replaces the database with the pre-upgrade backup: everything written since is lost. Add --yes to confirm."
	fi
	docker image inspect "$pimg" >/dev/null 2>&1 || VENOM_CLOUD_IMAGE="$pimg" docker compose pull venom-cloud || die "the previous image $pimg is neither here nor pullable."
	cur="$(envget VENOM_CLOUD_VERSION)"
	curimg="$(envget VENOM_CLOUD_IMAGE)"
	# Migrations are expand/contract: the previous release runs on the newer schema, so the image alone is enough.
	[ "$restore" = 0 ] || { backup_to "$(backup_dir)/pre-rollback-$(stamp).sql.gz"; restore_from "$pbk"; }
	envset VENOM_CLOUD_IMAGE "$pimg"
	envset VENOM_CLOUD_VERSION "$pver"
	docker compose up -d --wait >/dev/null 2>&1 && healthy || die "the previous release did not become healthy. Look at: docker compose logs venom-cloud"
	{ printf 'IMAGE=%s\n' "$curimg"; printf 'VERSION=%s\n' "$cur"; printf 'BACKUP=%s\n' "$pbk"; } >state/previous.env
	log_history rollback "$cur" "${pver:-$pimg}" t ""
	say "rolled back to ${pver:-$pimg}. Run venom-cloud rollback again to go forward."
	;;
models)
	[ "$(envget VENOM_OLLAMA_SERVICE)" = 1 ] || die "this install runs no Ollama of its own (install-cloud.sh --models ollama adds one). Providers are managed in the console."
	case "${1:-list}" in
	list) docker compose exec -T ollama ollama list ;;
	pull) docker compose exec -T ollama ollama pull "${2:?usage: venom-cloud models pull NAME}" ;;
	*) die "usage: venom-cloud models [list | pull NAME]" ;;
	esac
	;;
uninstall)
	keep=0 yes=0
	for a in "$@"; do
		case "$a" in --keep-data) keep=1 ;; --yes | -y) yes=1 ;; *) echo "venom-cloud: unknown argument $a" >&2; exit 2 ;; esac
	done
	if [ "$keep" = 0 ] && [ "$yes" = 0 ]; then
		if prod; then echo "This deletes the certificates (your database server is not touched). Run with --keep-data to keep them, or --yes to confirm." >&2
		else echo "This deletes the database and the certificates. Run with --keep-data to keep them, or --yes to confirm." >&2; fi
		exit 2
	fi
	if [ "$keep" = 1 ]; then docker compose down; else docker compose down -v; fi
	rm -f "${VENOM_CRON_DIR:-/etc/cron.d}/venom-cloud" "${VENOM_CLOUD_BIN_DIR:-/usr/local/bin}/venom-cloud"
	echo "stopped. $dir stays (your .env and backups)."
	;;
	tick) tick ;;
verify-restore) verify_restore "${1:-}" ;;
s3-sign) # s3-sign METHOD PATH PAYLOAD_HASH AMZDATE REGION ACCESS_KEY HEADERS [QUERY] (the secret in S3_SECRET): the SigV4 self-check
		[ -n "${S3_SECRET:-}" ] || die "s3-sign needs S3_SECRET in the environment"
		s3_auth "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}" ;;
*) echo "usage: venom-cloud status | logs [service] | backup [file | --scheduled | --list | s3-key] | restore file --yes | upgrade [--yes] [--version X.Y.Z] [--bundle file] | rollback [--restore] [--yes] | verify-restore [file] | tick | models [list | pull name] | uninstall [--keep-data] [--yes]" >&2; exit 2 ;;
esac
}
# main is parsed whole before it runs, so an upgrade that rewrites this file under it never runs half of the new one.
main "$@"
exit $?
HELPER_EOF
	chmod 755 "$dir/bin/venom-cloud.new"
	# A new file, not the running one rewritten: a tick that started an upgrade keeps reading the copy it opened.
	mv -f "$dir/bin/venom-cloud.new" "$dir/bin/venom-cloud"
	bindir="${VENOM_CLOUD_BIN_DIR:-/usr/local/bin}"
	if [ -d "$bindir" ] && [ -w "$bindir" ]; then ln -sf "$dir/bin/venom-cloud" "$bindir/venom-cloud"; fi
}

# --- run ---------------------------------------------------------------------------
if [ "$secrets_only" = 1 ]; then
	open_env
	gen_secrets
	say "wrote the generated secrets to $envf"
	exit 0
fi
preflight
[ "$dry" = 1 ] || ensure_docker

if [ "$dbhost" = 1 ]; then database_host; fi

if [ "$upgrade" = 0 ]; then
	[ -n "$domain" ] || domain="$(ask 'Domain for this install (empty: this server'"'"'s IP with a self-signed certificate)' '')"
	[ -n "$email" ] || email="$(ask 'Admin email' '')"
	answers
	[ -n "$auto" ] || auto="$(ask 'Turn on automatic updates (patch releases, Sundays 04:00 UTC until you change it in the console)? (yes/no)' 'no')"
fi
if [ -n "$domain" ] && [ "$skip_dns" = 0 ] && ! getent hosts "$domain" >/dev/null 2>&1; then die "$domain does not resolve yet: point its DNS record at this server and run this again."; fi
if [ "$upgrade" = 0 ] && [ "$profile" = production ] && [ "$dry" = 0 ]; then check_database; fi
resolve_release
if [ "$upgrade" = 1 ]; then
	[ -f "$dir/.env" ] || die "no install in $dir (no .env)"
	envf="$dir/.env"
	write_stack # the compose file and Caddyfile belong to the release; .env stays yours
else
	write_env
	write_stack
fi
write_helper

if [ "$upgrade" = 1 ] && [ -n "$channel" ]; then setkey VENOM_CHANNEL "$channel"; fi
if [ "$upgrade" = 1 ] && [ "$dry" = 0 ]; then
	# Preflight, backup, pull by digest, migrate, health check and the automatic rollback live in the helper, which
	# an offline bundle uses too.
	rc=0
	"$dir/bin/venom-cloud" apply "$image" "$version" "$min_from" || rc=$?
	# An install from before `venom-cloud tick` gets its cron entries now (its weekly upgrade line meant automatic updates).
	backups="$(prev VENOM_BACKUPS)" bdir="$(prevor VENOM_BACKUP_DIR "$dir/backups")" keep="$(prevor VENOM_BACKUP_KEEP 14)" auto="$(prev VENOM_AUTO_UPDATE)"
	if [ -z "$auto" ] && grep -q 'upgrade --yes' "${VENOM_CRON_DIR:-/etc/cron.d}/venom-cloud" 2>/dev/null; then auto=yes; setkey VENOM_AUTO_UPDATE yes; fi
	[ "$rc" != 0 ] || write_cron >/dev/null
	exit "$rc"
fi

if [ "$dry" = 1 ]; then
	say "dry run: wrote $dir (.env, docker-compose.yml, Caddyfile, bin/venom-cloud); Docker was not started"
	exit 0
fi

say "pulling images and starting the stack (the first start applies the migrations)..."
(cd "$dir" && { docker compose pull --quiet || true; } && docker compose up -d --wait) || die "the stack did not become healthy. Look at: cd $dir && docker compose logs venom-cloud"

origin="$(sed -n 's/^VENOM_CLOUD_ORIGIN=//p' "$dir/.env")"
host="${origin#https://}"
ok=0
i=0
while [ "$i" -lt "${VENOM_HEALTH_TRIES:-60}" ]; do
	if [ -n "$proxy" ]; then set -- "http://127.0.0.1/api/status"
	else case "$host" in *[!0-9.:]*) set -- --resolve "$host:443:127.0.0.1" "$origin/api/status" ;; *) set -- "https://127.0.0.1/api/status" ;; esac; fi
	if curl -fsSk -o /dev/null "$@" 2>/dev/null; then ok=1; break; fi
	i=$((i + 1))
	sleep "${VENOM_HEALTH_SLEEP:-2}"
done
[ "$ok" = 1 ] || warn "the app is up but $origin/api/status does not answer through HTTPS yet (a new certificate can take a minute). Check: venom-cloud status"

write_cron
if [ "$ollama_service" = 1 ] && [ -n "$ollama_model" ] && [ "$ollama_model" != none ]; then
	say "pulling the Ollama model $ollama_model (this can take a few minutes)..."
	(cd "$dir" && docker compose exec -T ollama ollama pull "$ollama_model" >/dev/null) || warn "could not pull $ollama_model now. Later: venom-cloud models pull $ollama_model"
fi
code="$(cd "$dir" && docker compose logs --no-log-prefix venom-cloud 2>&1 | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}' | head -1 || true)"
say ""
say "Venom Cloud is running."
say "  Open:        $origin/setup"
[ -z "$code" ] || say "  Setup code:  $code   (once; it stops working when the organisation exists)"
[ -z "$email" ] || say "  Admin email: $email (enter it on the setup screen)"
[ -n "$domain" ] || say "  The certificate is self-signed: your browser will warn once."
case "$models" in
ollama) say "  Models:      Ollama at $private_urls. In the console: Providers, Add, Other (OpenAI-compatible), base URL $private_urls/v1, any key (for example ollama)." ;;
key) say "  Models:      your $provider key is in .env; its models serve as soon as the organisation exists." ;;
*) say "  Models:      add a provider key in the console (Providers), or connect a daemon." ;;
esac
[ "$profile" != production ] || say "  Database:    $(dbhost_of "$dburl") (your database server${shared:+, shared with the other app servers})"
[ -z "$proxy" ] || say "  HTTPS:       at your load balancer; this server answers plain HTTP on port 80"
[ "$backups" != daily ] || say "  Backups:     daily into $bdir, the newest $keep kept. Restore: venom-cloud restore FILE --yes"
say "  Secrets:     $dir/.env (mode 600). Back it up: VENOM_VAULT_KEYS opens what the vault sealed."
say "  Manage:      venom-cloud status | logs | backup | restore | upgrade | rollback | uninstall --keep-data"
exit 0
