#!/usr/bin/env bash
# docker-entrypoint.sh — one-shot supervisor for this image's services.
#
# Starts, in order:
#   1. Xvfb            virtual X11 display (Selkies captures it)
#   2. PulseAudio      audio server (Selkies captures it via pcmflux)
#   3. Selkies         HTML5 remote desktop on 127.0.0.1:${SELKIES_INTERNAL_PORT:-8081}
#   4. Chromium        playwright-built browser with a CDP endpoint on loopback
#   5. nginx           the public front door, on FIXED container ports:
#                       - 0.0.0.0:80    -> Selkies web UI over HTTP (always)
#                       - 0.0.0.0:443   -> Selkies web UI over TLS (only when
#                         ENABLE_HTTPS=true; nginx does not even listen on 443
#                         otherwise)
#                       - 0.0.0.0:9222  -> chromium CDP gateway
#                     These ports are not configurable: NGINX_HTTP_PORT /
#                     NGINX_HTTPS_PORT / CDP_PORT only pick the HOST-side
#                     ports docker publishes (compose "ports:" / docker -p).
#
# Container start == service start ("开机自启"): this script is the image
# ENTRYPOINT; combine with `docker run --restart=always` for boot persistence.
#
# Any first argument other than "start" (or no argument) is exec'd as a
# command instead, e.g. `docker run -it <image> bash` drops to a shell.
#
# Common overrides (-e):
#   ENABLE_HTTPS=false          true = nginx also serves HTTPS on 443. The
#                               certificate pair is REUSED whenever a valid one
#                               already exists (mounted or generated on an
#                               earlier start — self-signed counts as valid);
#                               only when no usable pair is found is a fresh
#                               self-signed one generated.
#   TLS_CERT_DIR=/etc/nginx/tls where certificates are looked up and, when the
#                               directory is writable, generated into (so a
#                               generated pair persists across restarts when
#                               the directory is a bind mount)
#   TLS_CERT_FILE/TLS_KEY_FILE  explicit cert/key paths (default inside TLS_CERT_DIR)
#   TLS_SELF_SIGNED_CN=localhost CN of the generated self-signed certificate
#   SELKIES_INTERNAL_PORT=8081  loopback port Selkies binds to (behind nginx)
#   SELKIES_BASIC_AUTH_PASSWORD  set it to enable the login screen
#   SELKIES_ENCODER=h264enc      h264enc | h264enc-striped | openh264enc | jpeg
#   SCREEN_GEOMETRY=1920x1080x24 Xvfb screen size
#   TZ=UTC                      container timezone (default UTC; -e TZ=...
#                               overrides at runtime, no rebuild needed)
#   CHROMIUM_LANG=en-US         browser UI locale + Accept-Language (default
#                               system English; e.g. zh-CN for Chinese)
#   CHROMIUM_DISABLE_FEATURES   comma-separated chromium feature names passed
#                               as --disable-features=... (empty/unset = no
#                               flag; the compose file ships a default that
#                               turns off the HTTPS-First/HTTPS-Upgrade
#                               experiments so plain-http pages stay as-is)
#   CDP_INTERNAL_PORT=9221      chromium loopback DevTools port (behind nginx)
#   CHROMIUM_HEADLESS=1          run the browser headless instead (default 0:
#                                the browser window opens on the Xvfb display
#                                and is visible live in the Selkies stream)
#   ENABLE_SELKIES=true          set false to skip Selkies + display + audio
#   ENABLE_CDP=true              set false to skip Chromium + the CDP gateway
set -uo pipefail

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --- passthrough mode: run whatever command was given -----------------------
if [ "${1:-start}" != "start" ]; then
    exec "$@"
fi

# --- config ------------------------------------------------------------------
DISPLAY="${DISPLAY:-:0}"
SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1920x1080x24}"

# Selkies itself is loopback-only; nginx is the public front door.
SELKIES_INTERNAL_PORT="${SELKIES_INTERNAL_PORT:-8081}"
SELKIES_ADDR="${SELKIES_ADDR:-127.0.0.1}"

# nginx public ports — FIXED by design (host-side publishing of these ports is
# chosen by docker: compose "ports:" / docker -p, NOT by this container).
WEB_HTTP_PORT=80      # web UI over HTTP (always on)
WEB_HTTPS_PORT=443    # web UI over HTTPS (ENABLE_HTTPS=true only)
CDP_LISTEN_PORT=9222  # chromium CDP gateway
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"   # true = also serve HTTPS on ${WEB_HTTPS_PORT}

# TLS: reuse any valid existing pair (mounted or generated on an earlier
# start); generate a self-signed one only when no usable pair is found.
TLS_CERT_DIR="${TLS_CERT_DIR:-/etc/nginx/tls}"
TLS_CERT_FILE="${TLS_CERT_FILE:-${TLS_CERT_DIR}/fullchain.pem}"
TLS_KEY_FILE="${TLS_KEY_FILE:-${TLS_CERT_DIR}/privkey.pem}"
TLS_SELF_SIGNED_CN="${TLS_SELF_SIGNED_CN:-localhost}"
# fallback location for generated pairs when TLS_CERT_DIR is not writable
# (e.g. a read-only mount); container-local, so it survives `docker restart`
TLS_FALLBACK_DIR="/etc/nginx/tls-selfsigned"

CDP_INTERNAL_PORT="${CDP_INTERNAL_PORT:-9221}" # chromium loopback DevTools port

CHROMIUM_HEADLESS="${CHROMIUM_HEADLESS:-0}"
CHROMIUM_START_URL="${CHROMIUM_START_URL:-about:blank}"
CHROMIUM_USER_DATA_DIR="${CHROMIUM_USER_DATA_DIR:-/tmp/chrome-profile}"
# Browser UI locale + Accept-Language; en-US by default (env override: any
# other locale, e.g. zh-CN).
CHROMIUM_LANG="${CHROMIUM_LANG:-en-US}"
# Comma-separated chromium feature names -> --disable-features=<value>. No
# default here on purpose: the compose file owns the default value; with a
# bare `docker run` the flag is only passed when the variable is set non-empty.
CHROMIUM_DISABLE_FEATURES="${CHROMIUM_DISABLE_FEATURES:-}"

ENABLE_SELKIES="${ENABLE_SELKIES:-true}"
ENABLE_CDP="${ENABLE_CDP:-true}"
[ "${ENABLE_SELKIES}" = "true" ] || [ "${ENABLE_CDP}" = "true" ] \
    || die "nothing to start (ENABLE_SELKIES and ENABLE_CDP both false?)"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export DISPLAY XDG_RUNTIME_DIR
export PIPEWIRE_LATENCY="${PIPEWIRE_LATENCY:-256/48000}"
PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR}/pulse}"
PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"
export PULSE_RUNTIME_PATH PULSE_SERVER

# --- PID 1 duties: reap children, forward docker stop ------------------------
pids=()
cleanup() {
    trap - TERM INT EXIT
    [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null
    # give services a moment to exit, then force-kill the survivors
    for _ in $(seq 1 20); do
        kill -0 "${pids[@]}" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "${pids[@]}" 2>/dev/null
    wait "${pids[@]}" 2>/dev/null
    log "stopped"
}
trap 'cleanup; exit 0' TERM INT
trap 'cleanup' EXIT

# --- 1. virtual display + 2. audio (only needed by Selkies) ------------------
if [ "${ENABLE_SELKIES}" = "true" ]; then
    log "starting Xvfb on display ${DISPLAY} (${SCREEN_GEOMETRY})"
    Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" +extension "COMPOSITE" \
        +extension "DAMAGE" +extension "RANDR" +extension "RENDER" \
        +extension "XTEST" -nolisten tcp -ac -noreset \
        >/tmp/xvfb.log 2>&1 &
    pids+=($!)
    XSOCKET="/tmp/.X11-unix/X${DISPLAY#*:}"
    for _ in $(seq 1 50); do [ -S "${XSOCKET}" ] && break; sleep 0.2; done
    [ -S "${XSOCKET}" ] || die "Xvfb did not create ${XSOCKET}; see /tmp/xvfb.log"

    log "starting PulseAudio (socket ${PULSE_SERVER})"
    mkdir -p "${PULSE_RUNTIME_PATH}"
    pulseaudio --daemonize=no --exit-idle-time=-1 --disallow-exit \
        >/tmp/pulseaudio.log 2>&1 &
    pids+=($!)
    for _ in $(seq 1 50); do [ -S "${PULSE_SERVER#unix:}" ] && break; sleep 0.2; done
    [ -S "${PULSE_SERVER#unix:}" ] || log "WARNING: PulseAudio socket missing; streaming continues without audio (see /tmp/pulseaudio.log)"
fi

# --- 3. Selkies remote desktop -----------------------------------------------
if [ "${ENABLE_SELKIES}" = "true" ]; then
    # Enable the login screen only when a password is around; Selkies refuses
    # to start with auth enabled and no password. Username resolves natively
    # from SELKIES_BASIC_AUTH_USER / CUSTOM_USER / USERNAME / USER and falls
    # back to selkies' built-in default "ubuntu" (e.g. no USER in the image).
    if [ -n "${SELKIES_ENABLE_BASIC_AUTH:-}" ]; then
        AUTH_FLAG="--enable-basic-auth=${SELKIES_ENABLE_BASIC_AUTH}"
    elif [ -n "${SELKIES_BASIC_AUTH_PASSWORD:-}${PASSWORD:-}${PASSWD:-}" ]; then
        AUTH_FLAG="--enable-basic-auth=true"
    else
        log "no SELKIES_BASIC_AUTH_PASSWORD set -> serving without login"
        AUTH_FLAG="--enable-basic-auth=false"
    fi

    log "starting selkies on ${SELKIES_ADDR}:${SELKIES_INTERNAL_PORT} (encoder ${SELKIES_ENCODER:-h264enc}, fronted by nginx)"
    # Extra settings ride the native SELKIES_* env vars (CLI > env > default).
    # TLS terminates at nginx, so selkies itself always serves plain HTTP on
    # the loopback port nginx proxies to.
    # shellcheck disable=SC2086
    selkies \
        --addr="${SELKIES_ADDR}" \
        --port="${SELKIES_INTERNAL_PORT}" \
        --encoder="${SELKIES_ENCODER:-h264enc}" \
        --enable-resize="${SELKIES_ENABLE_RESIZE:-false}" \
        ${AUTH_FLAG} \
        ${SELKIES_EXTRA_ARGS:-} &
    pids+=($!)
fi

# --- 5. chromium (loopback CDP endpoint) ---------------------------------------
if [ "${ENABLE_CDP}" = "true" ]; then
    CHROME_BIN="${CHROME_BIN:-$(echo /usr/local/share/ms-playwright/chromium-*/chrome-linux*/chrome)}"
    [ -x "${CHROME_BIN}" ] || die "chrome binary not found: ${CHROME_BIN}"

    # Headed is the default so the browser window is visible in the Selkies
    # stream; but a headed browser needs the Xvfb display; without it
    # (ENABLE_SELKIES=false and no external display) fall back to headless.
    XSOCKET="/tmp/.X11-unix/X${DISPLAY#*:}"
    if [ "${CHROMIUM_HEADLESS}" = "0" ] && [ "${ENABLE_SELKIES}" != "true" ] && [ ! -S "${XSOCKET}" ]; then
        log "WARNING: no X display for a headed chromium -> falling back to headless"
        CHROMIUM_HEADLESS=1
    fi

    CHROMIUM_FLAGS=(--no-sandbox --disable-dev-shm-usage
        --user-data-dir="${CHROMIUM_USER_DATA_DIR}"
        --remote-debugging-port="${CDP_INTERNAL_PORT}"
        # suppress the "Chrome for testing is only for automated testing"
        # banner bar (verified pixel-level: the ~36px band disappears)
        --disable-infobars)
    if [ "${CHROMIUM_HEADLESS}" = "1" ]; then
        CHROMIUM_FLAGS+=(--headless --disable-gpu)
    else
        # Headed on the Xvfb display (default): the browser window shows up in
        # the Selkies stream, so automation can be watched live.
        WIN_W="${SCREEN_GEOMETRY%%x*}"
        WIN_H="$(echo "${SCREEN_GEOMETRY}" | cut -dx -f2)"
        CHROMIUM_FLAGS+=(--window-size="${WIN_W},${WIN_H}" --start-maximized --no-first-run)
    fi
    # Dedicated --disable-features knob (CHROMIUM_DISABLE_FEATURES, fed from
    # .env by compose). Appended before CHROMIUM_EXTRA_ARGS so a manually
    # passed --disable-features there still wins (chromium keeps the last
    # occurrence of a repeated switch).
    if [ -n "${CHROMIUM_DISABLE_FEATURES}" ]; then
        log "chromium: disabling features: ${CHROMIUM_DISABLE_FEATURES}"
        CHROMIUM_FLAGS+=(--disable-features="${CHROMIUM_DISABLE_FEATURES}")
    fi
    if [ -n "${CHROMIUM_EXTRA_ARGS:-}" ]; then
        # split the flag string into words — same semantics as the unquoted
        # expansion this replaces, but robust for the array append
        read -r -a extra_flags <<< "${CHROMIUM_EXTRA_ARGS}"
        CHROMIUM_FLAGS+=("${extra_flags[@]}")
    fi

    log "starting chromium (headless=${CHROMIUM_HEADLESS}) with CDP on 127.0.0.1:${CDP_INTERNAL_PORT}"
    # A persisted profile carries Singleton* lock files from the previous
    # run, bound to the old container hostname/pid; chrome refuses to start
    # on them ("profile in use by another process"). They are runtime-only
    # artifacts, so clear them before every launch.
    rm -f "${CHROMIUM_USER_DATA_DIR}"/SingletonLock \
          "${CHROMIUM_USER_DATA_DIR}"/SingletonSocket \
          "${CHROMIUM_USER_DATA_DIR}"/SingletonCookie
    # Seed the profile's language prefs: navigator.language reads them from
    # the profile, so a persisted profile keeps the locale of its first run
    # and the LANG env var alone cannot retarget it (verified: seeding +
    # LANG retargets a persisted profile to the requested locale).
    mkdir -p "${CHROMIUM_USER_DATA_DIR}/Default"
    python3 - "${CHROMIUM_USER_DATA_DIR}/Default/Preferences" "${CHROMIUM_LANG}" <<'PYSEED'
import json, sys
path, lang = sys.argv[1], sys.argv[2]
langs = lang + "," + lang.split("-")[0]
try:
    prefs = json.load(open(path))
except Exception:
    prefs = {}
prefs.setdefault("intl", {})
prefs["intl"]["accept_languages"] = langs
prefs["intl"]["selected_languages"] = langs
json.dump(prefs, open(path, "w"))
PYSEED
    # Chromium on Linux ignores --lang for both UI and Accept-Language; the
    # LANG env var is what selects them (verified with LANG=zh_CN.UTF-8:
    # Chinese UI, zh-CN navigator.language, zh-CN,zh selected_languages).
    # Map the BCP-47 spelling (e.g. en-US) to the POSIX one (en_US.UTF-8).
    CHROMIUM_LOCALE_POSIX="$(echo "${CHROMIUM_LANG}" | tr '-' '_').UTF-8"
    LANG="${CHROMIUM_LOCALE_POSIX}" LC_ALL="${CHROMIUM_LOCALE_POSIX}" \
        "${CHROME_BIN}" "${CHROMIUM_FLAGS[@]}" "${CHROMIUM_START_URL}" \
        >/tmp/chromium.log 2>&1 &
    pids+=($!)

    # Wait for the loopback DevTools endpoint before forwarding.
    for _ in $(seq 1 100); do
        curl -fsS "http://127.0.0.1:${CDP_INTERNAL_PORT}/json/version" >/dev/null 2>&1 && break
        sleep 0.2
    done
    curl -fsS "http://127.0.0.1:${CDP_INTERNAL_PORT}/json/version" >/dev/null 2>&1 \
        || log "WARNING: chromium DevTools endpoint not up yet; nginx forwards anyway (see /tmp/chromium.log)"
fi

# --- 6. nginx front door: web HTTP/HTTPS + CDP gateway ------------------------
# One nginx instance serves every public port (replacing the old socat CDP
# forwarder), on FIXED container ports:
#   ${WEB_HTTP_PORT}  -> 127.0.0.1:${SELKIES_INTERNAL_PORT}  web UI, HTTP (always)
#   ${WEB_HTTPS_PORT} -> 127.0.0.1:${SELKIES_INTERNAL_PORT}  web UI, TLS (optional)
#   ${CDP_LISTEN_PORT} -> 127.0.0.1:${CDP_INTERNAL_PORT}     chromium CDP
# Every proxy is WebSocket-capable (CDP and Selkies signaling both need it).

listen_ports=()
upstream_ports=()
if [ "${ENABLE_SELKIES}" = "true" ]; then
    listen_ports+=("${WEB_HTTP_PORT}")
    upstream_ports+=("${SELKIES_INTERNAL_PORT}")
    if [ "${ENABLE_HTTPS}" = "true" ]; then
        listen_ports+=("${WEB_HTTPS_PORT}")
    fi
elif [ "${ENABLE_HTTPS}" = "true" ]; then
    log "NOTE: ENABLE_HTTPS=true ignored: the web UI is disabled (ENABLE_SELKIES=false)"
fi
if [ "${ENABLE_CDP}" = "true" ]; then
    listen_ports+=("${CDP_LISTEN_PORT}")
    upstream_ports+=("${CDP_INTERNAL_PORT}")
fi

# A listener colliding with a loopback upstream would make nginx fail at bind
# time with a cryptic error; fail fast with a clear one.
all_ports=("${listen_ports[@]}" "${upstream_ports[@]}")
for i in "${!all_ports[@]}"; do
    for j in "${!all_ports[@]}"; do
        if [ "${i}" -lt "${j}" ] && [ "${all_ports[$i]}" = "${all_ports[$j]}" ]; then
            die "port ${all_ports[$i]} is used more than once (listen: ${listen_ports[*]:-none}; upstream: ${upstream_ports[*]:-none})"
        fi
    done
done

# --- TLS certificate: reuse any valid pair, self-sign only when needed --------
# "Valid" = parseable certificate + parseable key + the two belong together
# (same public key). Self-signed pairs are perfectly valid. An existing pair
# that fails validation is a configuration error and stops the container
# rather than being silently replaced.
TLS_CERT=""
TLS_KEY=""

# tls_pair_issue <cert> <key>: prints the problem (if any); silent when valid.
tls_pair_issue() {
    if ! openssl x509 -noout -in "$1" >/dev/null 2>&1; then
        echo "certificate is not parseable (openssl x509 rejected $1)"
        return 1
    fi
    if ! openssl pkey -noout -in "$2" >/dev/null 2>&1; then
        echo "private key is not parseable (openssl pkey rejected $2)"
        return 1
    fi
    local cert_pub key_pub
    cert_pub="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null)"
    key_pub="$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | openssl sha256 2>/dev/null)"
    if [ -z "${cert_pub}" ] || [ "${cert_pub}" != "${key_pub}" ]; then
        echo "certificate $1 does not match private key $2"
        return 1
    fi
    return 0
}

# tls_valid_for_nginx <cert> <key>: quick re-check used right before start.
tls_valid_for_nginx() {
    [ -s "$1" ] && [ -s "$2" ] && tls_pair_issue "$1" "$2" >/dev/null
}

# tls_log_reuse <cert>: describe the certificate being (re)used.
tls_log_reuse() {
    local end
    end="$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2-)"
    if openssl x509 -noout -checkend 0 -in "$1" >/dev/null 2>&1; then
        log "HTTPS: reusing existing certificate $1 (valid until ${end:-unknown})"
    else
        log "HTTPS: WARNING: certificate $1 is EXPIRED (${end:-unknown}); reusing it anyway — delete it to force a new one"
    fi
}

if [ "${ENABLE_SELKIES}" = "true" ] && [ "${ENABLE_HTTPS}" = "true" ]; then
    if [ -s "${TLS_CERT_FILE}" ] && [ -s "${TLS_KEY_FILE}" ]; then
        # A pair is present (mounted, or generated into a writable TLS_CERT_DIR
        # on an earlier start): reuse it as long as it is valid.
        issue="$(tls_pair_issue "${TLS_CERT_FILE}" "${TLS_KEY_FILE}")" \
            || die "HTTPS: refusing to start with a broken certificate pair: ${issue}. Fix or delete ${TLS_CERT_FILE} / ${TLS_KEY_FILE} (a valid pair is reused as-is; a deleted pair is regenerated self-signed)."
        TLS_CERT="${TLS_CERT_FILE}"
        TLS_KEY="${TLS_KEY_FILE}"
        tls_log_reuse "${TLS_CERT}"
    elif [ -s "${TLS_FALLBACK_DIR}/fullchain.pem" ] && [ -s "${TLS_FALLBACK_DIR}/privkey.pem" ] \
        && tls_valid_for_nginx "${TLS_FALLBACK_DIR}/fullchain.pem" "${TLS_FALLBACK_DIR}/privkey.pem"; then
        # Pair from an earlier start of this same container (TLS_CERT_DIR was
        # not writable then). Reuse instead of generating a new one.
        TLS_CERT="${TLS_FALLBACK_DIR}/fullchain.pem"
        TLS_KEY="${TLS_FALLBACK_DIR}/privkey.pem"
        tls_log_reuse "${TLS_CERT}"
    else
        # No usable pair anywhere -> generate a self-signed one. Prefer
        # TLS_CERT_DIR (a bind mount there persists the pair across container
        # recreation, so it is generated only once); fall back to the
        # container-local dir when TLS_CERT_DIR is read-only or its target
        # names are occupied by unrelated files.
        gen_dir=""
        if mkdir -p "${TLS_CERT_DIR}" 2>/dev/null \
            && touch "${TLS_CERT_DIR}/.write-test" 2>/dev/null \
            && rm -f "${TLS_CERT_DIR}/.write-test" \
            && [ ! -e "${TLS_CERT_FILE}" ] && [ ! -e "${TLS_KEY_FILE}" ]; then
            gen_dir="${TLS_CERT_DIR}"
        else
            mkdir -p "${TLS_FALLBACK_DIR}"
            gen_dir="${TLS_FALLBACK_DIR}"
        fi
        TLS_CERT="${gen_dir}/fullchain.pem"
        TLS_KEY="${gen_dir}/privkey.pem"
        log "HTTPS: no valid certificate found -> generating self-signed ${TLS_CERT} (CN=${TLS_SELF_SIGNED_CN})"
        rm -f "${TLS_CERT}" "${TLS_KEY}"
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -keyout "${TLS_KEY}" -out "${TLS_CERT}" \
            -subj "/CN=${TLS_SELF_SIGNED_CN}" \
            -addext "subjectAltName=DNS:${TLS_SELF_SIGNED_CN},DNS:localhost,IP:127.0.0.1" \
            >/dev/null 2>&1 || die "self-signed certificate generation failed"
        tls_valid_for_nginx "${TLS_CERT}" "${TLS_KEY}" \
            || die "generated self-signed pair failed its own validation check"
    fi
fi

# --- generate the site config from the flags above ----------------------------
NGINX_CONF=/tmp/nginx/nginx.conf
mkdir -p /tmp/nginx/client_body /tmp/nginx/proxy /tmp/nginx/fastcgi \
         /tmp/nginx/uwsgi /tmp/nginx/scgi

WEB_SERVERS=""
if [ "${ENABLE_SELKIES}" = "true" ]; then
    WEB_SERVERS="$(cat <<EOF
    # web UI over plain HTTP (always on)
    server {
        listen ${WEB_HTTP_PORT};
        server_name _;
        location / {
            proxy_pass http://127.0.0.1:${SELKIES_INTERNAL_PORT};
        }
    }
EOF
)"
    if [ -n "${TLS_CERT}" ]; then
        WEB_SERVERS="${WEB_SERVERS}
$(cat <<EOF
    # web UI over HTTPS (ENABLE_HTTPS=true)
    server {
        listen ${WEB_HTTPS_PORT} ssl;
        server_name _;
        ssl_certificate ${TLS_CERT};
        ssl_certificate_key ${TLS_KEY};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        location / {
            proxy_pass http://127.0.0.1:${SELKIES_INTERNAL_PORT};
        }
    }
EOF
)"
    fi
fi

CDP_SERVER=""
if [ "${ENABLE_CDP}" = "true" ]; then
    CDP_SERVER="$(cat <<EOF
    # chromium CDP gateway (DevTools protocol over HTTP + WebSocket)
    server {
        listen ${CDP_LISTEN_PORT};
        server_name _;
        location / {
            # Chromium's DevTools endpoint rejects Host headers that are not
            # an IP address or "localhost" (DNS-rebinding protection) with
            # HTTP 500, and it embeds the request's Host into every
            # webSocketDebuggerUrl it returns. So: rewrite the Host to the
            # loopback upstream (always accepted) and swap the loopback
            # host:port inside JSON bodies back to the host:port the client
            # actually dialed (\$cdp_public_host, from the map above), so the
            # returned ws:// URLs stay reachable through this proxy.
            # proxy_set_header is all-or-nothing per level: defining Host
            # here stops the http-level Upgrade/Connection headers from
            # being inherited, so repeat them (a lost Upgrade header makes
            # chromium answer the DevTools WS handshake with HTTP 200).
            proxy_set_header Host 127.0.0.1:${CDP_INTERNAL_PORT};
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            sub_filter_types application/json;
            sub_filter_once off;
            sub_filter '127.0.0.1:${CDP_INTERNAL_PORT}' '\$cdp_public_host';
            proxy_buffering on;
            proxy_pass http://127.0.0.1:${CDP_INTERNAL_PORT};
        }
    }
EOF
)"
fi

cat > "${NGINX_CONF}" <<EOF
# generated by docker-entrypoint.sh at container start — do not edit
daemon off;
worker_processes auto;
pid /tmp/nginx/nginx.pid;
error_log /tmp/nginx/error.log warn;

events {
    worker_connections 1024;
}

http {
    access_log /tmp/nginx/access.log;

    # temp dirs on the container's writable /tmp
    client_body_temp_path /tmp/nginx/client_body;
    proxy_temp_path       /tmp/nginx/proxy;
    fastcgi_temp_path     /tmp/nginx/fastcgi;
    uwsgi_temp_path       /tmp/nginx/uwsgi;
    scgi_temp_path        /tmp/nginx/scgi;

    # WebSocket upgrade handling (needed by CDP and Selkies signaling)
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    # host:port the client dialed the CDP gateway on; falls back to \$host
    # when the client sent no port (or HTTP/1.0 without a Host at all)
    map \$http_host \$cdp_public_host {
        default \$http_host;
        ''      \$host;
    }

    # proxy defaults inherited by every server block below
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    # idle DevTools/Selkies WebSocket sessions can outlive the 60s default
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_buffering off;
    client_max_body_size 50m;

${WEB_SERVERS}
${CDP_SERVER}
}
EOF

if ! nginx_out="$(nginx -t -c "${NGINX_CONF}" 2>&1)"; then
    die "nginx config invalid: ${nginx_out}"
fi

fronts=""
[ "${ENABLE_SELKIES}" = "true" ] && fronts="http:${WEB_HTTP_PORT}"
[ -n "${TLS_CERT}" ] && fronts="${fronts} https:${WEB_HTTPS_PORT}"
[ "${ENABLE_CDP}" = "true" ] && fronts="${fronts} cdp:${CDP_LISTEN_PORT}"
log "starting nginx (${fronts:-no listeners}; host-side publishing is up to docker)"
nginx -c "${NGINX_CONF}" &
pids+=($!)

log "all services up (supervising ${pids[*]}); ready"

# --- wait: exit (and let docker restart) if any service dies ------------------
while :; do
    # returns as soon as one child exits, whatever its status
    wait -n 2>/dev/null || true
    sleep 0.2
    for pid in "${pids[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            log "service pid ${pid} exited; shutting down"
            exit 1
        fi
    done
done
