#!/usr/bin/env bash
# docker-entrypoint.sh — one-shot supervisor for this image's services.
#
# Starts, in order:
#   1. Xvfb            virtual X11 display (Selkies captures it)
#      picom           compositing manager for that display (keeps popup
#                       menu shadows visible; see ENABLE_COMPOSITOR)
#   2. PulseAudio      audio server (Selkies captures it via pcmflux)
#   3. Selkies         HTML5 remote desktop on 127.0.0.1:${SELKIES_INTERNAL_PORT:-8081}
#   4. Chromium        playwright-built browser with a CDP endpoint on loopback
#   5. nginx           the public front door, on these container ports
#                     (defaults; each one an env knob, see below):
#                       - 0.0.0.0:80    -> Selkies web UI over HTTP (always)
#                         (NGINX_LISTEN_HTTP_PORT)
#                       - 0.0.0.0:443   -> Selkies web UI over TLS (only when
#                         ENABLE_HTTPS=true; nginx does not even listen on it
#                         otherwise) (NGINX_LISTEN_HTTPS_PORT)
#                       - 0.0.0.0:9222  -> chromium CDP gateway (CDP_LISTEN_PORT)
#                     NGINX_HTTP_PORT / NGINX_HTTPS_PORT / CDP_PORT are a
#                     different thing: they only pick the HOST-side ports
#                     docker publishes (compose "ports:" / docker -p).
#
# Container start == service start ("开机自启"): this script is the image
# ENTRYPOINT; combine with `docker run --restart=always` for boot persistence.
#
# Any first argument other than "start" (or no argument) is exec'd as a
# command instead, e.g. `docker run -it <image> bash` drops to a shell.
#
# Common overrides (-e):
#   NGINX_LISTEN_HTTP_PORT=80            container port nginx serves the web UI on (HTTP)
#   NGINX_LISTEN_HTTPS_PORT=443          container port nginx serves the web UI on (TLS)
#   CDP_LISTEN_PORT=9222        container port of the public CDP gateway
#                               (the three above are what nginx binds INSIDE the
#                               container — useful with network_mode: host or
#                               when sharing a network namespace)
#   NGINX_LISTEN_ADDR=""        address every nginx listener binds to; empty =
#                               all interfaces. With network_mode: host set
#                               127.0.0.1 to keep the unauthenticated CDP
#                               endpoint (and the web UI) off the network.
#   ENABLE_HTTPS=false          true = nginx also serves HTTPS on NGINX_LISTEN_HTTPS_PORT. The
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
#   SELKIES_SUBFOLDER=""         URL path prefix the web UI is served under
#                                (e.g. /desk -> http://host:port/desk/); empty
#                                = the site root. Selkies' native setting; nginx
#                                additionally redirects / and /desk to /desk/
#   SELKIES_BASIC_AUTH_PASSWORD  set it to enable the login screen
#   SELKIES_ENCODER=h264enc      h264enc | h264enc-striped | openh264enc | jpeg
#   SCREEN_GEOMETRY=1920x1080x24 Xvfb screen size (the working size; also
#                                sizes the Selkies stream)
#   SCREEN_GEOMETRY_MAX=8192x4096x24 RandR ceiling the Xvfb screen is created
#                                at so Selkies' browser-driven resize can grow
#                                past SCREEN_GEOMETRY; empty = the fixed screen
#                                of SCREEN_GEOMETRY and no resize headroom
#   DISPLAY=:0                   Xvfb display. When it is already taken in the
#                                network namespace (network_mode: host on a
#                                desktop host running X/Xwayland), the next
#                                free display number is used instead.
#   TZ=UTC                      container timezone (default UTC; -e TZ=...
#                               overrides at runtime, no rebuild needed)
#   CHROMIUM_LANG=en-US         browser UI locale + Accept-Language (default
#                               system English; e.g. zh-CN for Chinese)
#   CHROMIUM_DISABLE_FEATURES   comma-separated chromium feature names passed
#                               as --disable-features=... (empty/unset = no
#                               flag; the compose file ships a default that
#                               turns off the HTTPS-First/HTTPS-Upgrade
#                               experiments so plain-http pages stay as-is)
#   CHROMIUM_GPU=auto            GPU/rendering policy (device detection in
#                               the chromium section): auto = hardware GL
#                               when a GPU is passed into the container
#                               (compose.gpu.yaml / compose.gpu-nvidia.yaml
#                               overlay), SwiftShader software rendering
#                               otherwise — WebGL always works; off = force
#                               software rendering even with a GPU attached;
#                               strict = never allow SwiftShader (anti-
#                               fingerprinting): hardware GL only, WebGL
#                               unavailable without a GPU
#   CDP_INTERNAL_PORT=9221      chromium loopback DevTools port (behind nginx)
#   CHROMIUM_HEADLESS=1          run the browser headless instead (default 0:
#                                the browser window opens on the Xvfb display
#                                and is visible live in the Selkies stream)
#   ENABLE_SELKIES=true          set false to skip Selkies + display + audio
#   ENABLE_CDP=true              set false to skip Chromium + the CDP gateway
#   ENABLE_COMPOSITOR=true       run a compositing manager (picom) on the
#                                Xvfb display. Without one chromium drops
#                                the alpha-blended shadows of its popup
#                                windows, so the right-click context menu
#                                floats around as a seemingly borderless
#                                white sheet; false = no compositor (the
#                                historical flat look)
#   CHROMIUM_FOLLOW_SCREEN=true  keep the headed chromium browser window
#                                covering the whole display when the screen
#                                size changes (Selkies' browser-driven
#                                resize). No window manager runs on Xvfb, so
#                                without it the window keeps its startup
#                                size; false = the window stays as launched
#   PORT_FORWARDS=""             extra reverse proxies served by nginx, e.g.
#                                "3080=peer:80 6080=other:6080" (space or
#                                comma separated): each LISTEN=HOST:PORT entry
#                                makes nginx listen on container port LISTEN
#                                and forward it to HOST:PORT — typically a
#                                sibling container on the same docker network.
#                                See the PORT_FORWARDS section below the nginx
#                                front door for details (late peer startup,
#                                WebSocket support, collision rules).
#   RUN_USER=""                  privilege drop for the desktop stack (Xvfb,
#                                picom, PulseAudio, selkies, chromium) and the
#                                nginx workers. Empty (default) = everything
#                                runs as root (the historical behavior). A
#                                user name that exists in /etc/passwd (e.g.
#                                pwuser) or uid[:gid] (missing passwd/group
#                                entries are synthesized at startup) runs those
#                                daemons as that user instead. PID 1 and the
#                                nginx master always stay root: nginx binds the
#                                (possibly privileged) listen ports and reads the
#                                TLS key, and the supervisor keeps preparing
#                                the browser profile (chowned to the user on
#                                every start).
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
# RandR ceiling (WxHxD) the Xvfb screen is created at, giving Selkies'
# browser-driven resize room to grow past SCREEN_GEOMETRY. Empty = the old
# behavior: a fixed screen of SCREEN_GEOMETRY nothing can resize beyond.
# The default matches the official selkies-session framebuffer (8192x4096).
SCREEN_GEOMETRY_MAX="${SCREEN_GEOMETRY_MAX-8192x4096x24}"
if [ -n "${SCREEN_GEOMETRY_MAX}" ] \
    && ! printf '%s' "${SCREEN_GEOMETRY_MAX}" | grep -Eq '^[0-9]+x[0-9]+x[0-9]+$'; then
    die "SCREEN_GEOMETRY_MAX must be WxHxD or empty, got '${SCREEN_GEOMETRY_MAX}'"
fi

# Selkies itself is loopback-only; nginx is the public front door.
SELKIES_INTERNAL_PORT="${SELKIES_INTERNAL_PORT:-8081}"
SELKIES_ADDR="${SELKIES_ADDR:-127.0.0.1}"
# URL path prefix of the web UI (empty = root). Normalized to the form both
# selkies and the nginx locations below expect: "/a/b" — leading slash, no
# trailing one. Restricted to URL-safe path characters, as the value lands
# verbatim in nginx location/return directives.
SELKIES_SUBFOLDER="${SELKIES_SUBFOLDER:-}"
SELKIES_SUBFOLDER="${SELKIES_SUBFOLDER#"${SELKIES_SUBFOLDER%%[!/]*}"}"   # strip leading /
SELKIES_SUBFOLDER="${SELKIES_SUBFOLDER%"${SELKIES_SUBFOLDER##*[!/]}"}"   # strip trailing /
case "/${SELKIES_SUBFOLDER}/" in
    *[!A-Za-z0-9._~/-]*|*//*|*/./*|*/../*)
        die "SELKIES_SUBFOLDER='${SELKIES_SUBFOLDER}' must be a plain URL path like /desk or /a/b" ;;
esac
[ -n "${SELKIES_SUBFOLDER}" ] && SELKIES_SUBFOLDER="/${SELKIES_SUBFOLDER}"

# nginx public listen ports INSIDE the container (host-side publishing of
# these ports is a separate choice made by docker: compose "ports:" /
# docker -p — NGINX_HTTP_PORT / NGINX_HTTPS_PORT / CDP_PORT in compose).
NGINX_LISTEN_HTTP_PORT="${NGINX_LISTEN_HTTP_PORT:-80}"        # web UI over HTTP (always on)
NGINX_LISTEN_HTTPS_PORT="${NGINX_LISTEN_HTTPS_PORT:-443}"     # web UI over HTTPS (ENABLE_HTTPS=true only)
CDP_LISTEN_PORT="${CDP_LISTEN_PORT:-9222}"  # chromium CDP gateway
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"   # true = also serve HTTPS on ${NGINX_LISTEN_HTTPS_PORT}
# Address every nginx listener binds to (empty = all interfaces). Matters with
# network_mode: host, where there is no docker port mapping to restrict
# exposure: 127.0.0.1 keeps the unauthenticated CDP endpoint host-local.
NGINX_LISTEN_ADDR="${NGINX_LISTEN_ADDR:-}"
case "${NGINX_LISTEN_ADDR}" in
    '') LISTEN_PREFIX="" ;;
    *[!0-9A-Fa-f.:\[\]]*) die "NGINX_LISTEN_ADDR='${NGINX_LISTEN_ADDR}' must be an IPv4/IPv6 address" ;;
    \[*) LISTEN_PREFIX="${NGINX_LISTEN_ADDR}:" ;;
    *:*) LISTEN_PREFIX="[${NGINX_LISTEN_ADDR}]:" ;;   # bare IPv6 -> [addr]:port
    *) LISTEN_PREFIX="${NGINX_LISTEN_ADDR}:" ;;
esac

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

# Every port knob must be a plain TCP port number; a typo would otherwise
# only surface as an obscure nginx/selkies/chromium startup failure.
for port_var in NGINX_LISTEN_HTTP_PORT NGINX_LISTEN_HTTPS_PORT CDP_LISTEN_PORT \
                SELKIES_INTERNAL_PORT CDP_INTERNAL_PORT; do
    port_val="${!port_var}"
    case "${port_val}" in
        ''|*[!0-9]*) die "${port_var}='${port_val}' is not a port number" ;;
    esac
    { [ "${port_val}" -ge 1 ] && [ "${port_val}" -le 65535 ]; } \
        || die "${port_var}=${port_val} is outside 1-65535"
done

# Extra reverse proxies served by the same nginx front door (empty = none).
# Parsed and validated in the nginx section below.
PORT_FORWARDS="${PORT_FORWARDS:-}"

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
# Single GPU/rendering policy knob; the device detection lives in the
# chromium section below. auto = hardware GL when a GPU is visible, else
# SwiftShader software; off = always software (the historical behavior);
# strict = hardware only, never allow SwiftShader.
CHROMIUM_GPU="${CHROMIUM_GPU:-auto}"

ENABLE_SELKIES="${ENABLE_SELKIES:-true}"
ENABLE_CDP="${ENABLE_CDP:-true}"
# picom is started together with Xvfb; the knob only makes sense when the
# display exists (ENABLE_SELKIES=true) and is harmlessly ignored otherwise.
ENABLE_COMPOSITOR="${ENABLE_COMPOSITOR:-true}"
# Screen follower for the headed chromium window (started next to chromium,
# see section 5); ignored when chromium runs headless.
CHROMIUM_FOLLOW_SCREEN="${CHROMIUM_FOLLOW_SCREEN:-true}"
[ "${ENABLE_SELKIES}" = "true" ] || [ "${ENABLE_CDP}" = "true" ] \
    || die "nothing to start (ENABLE_SELKIES and ENABLE_CDP both false?)"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export DISPLAY XDG_RUNTIME_DIR
export PIPEWIRE_LATENCY="${PIPEWIRE_LATENCY:-256/48000}"
PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-${XDG_RUNTIME_DIR}/pulse}"
PULSE_SERVER="${PULSE_SERVER:-unix:${PULSE_RUNTIME_PATH}/native}"
export PULSE_RUNTIME_PATH PULSE_SERVER

# --- privilege drop (RUN_USER) ------------------------------------------------
# RUN_USER runs the desktop stack — Xvfb, picom, PulseAudio, Selkies,
# Chromium — and the nginx workers as an unprivileged user. PID 1 and the
# nginx MASTER stay root: nginx binds the (by default privileged) listen
# ports and reads the TLS key, and the supervisor must keep chown-ing the
# browser profile. Empty (default) = everything runs as root, exactly the historical
# behavior: DROP stays an empty array and every "${DROP[@]}" prefix below is
# a no-op.
RUN_USER="${RUN_USER:-}"
DROP=()
run_uid="" run_gid="" run_name=""
RUN_NGINX_USER=""
if [ -n "${RUN_USER}" ]; then
    if [[ "${RUN_USER}" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        run_uid="${RUN_USER%%:*}"
        run_gid="${RUN_USER#*:}"
        [ "${run_gid}" != "${RUN_USER}" ] || run_gid="${run_uid}"
        [ "${run_uid}" != "0" ] \
            || die "RUN_USER=0 would drop privileges to root; pick a real unprivileged uid"
        # nginx's `user` directive takes a NAME and the daemons want a HOME:
        # synthesize passwd/group entries for bare numeric ids (idempotent —
        # an entry created on an earlier `docker restart` is simply reused).
        getent group "${run_gid}" >/dev/null 2>&1 \
            || groupadd -g "${run_gid}" "run${run_gid}"
        run_name="$(getent passwd "${run_uid}" | cut -d: -f1 || true)"
        if [ -z "${run_name}" ]; then
            useradd -o -u "${run_uid}" -g "${run_gid}" -d /tmp/run-home \
                -s /usr/sbin/nologin "run${run_uid}"
            run_name="run${run_uid}"
        fi
    else
        run_name="${RUN_USER}"
        passwd_entry="$(getent passwd "${run_name}")" \
            || die "RUN_USER=${RUN_USER}: no such user in /etc/passwd (use a name like pwuser, or uid[:gid])"
        run_uid="$(echo "${passwd_entry}" | cut -d: -f3)"
        run_gid="$(echo "${passwd_entry}" | cut -d: -f4)"
    fi

    # A writable HOME of the run user: chromium's crashpad handler and
    # pulse's cookie file live under it (verified: with root's /root left in
    # place both fail with permission errors).
    run_home="$(getent passwd "${run_uid}" | cut -d: -f6)"
    mkdir -p "${run_home}"
    chown "${run_uid}:${run_gid}" "${run_home}"
    export HOME="${run_home}"

    # GPU device nodes are root:<gid> 0660 — a dropped Chromium (Vulkan/
    # ANGLE) or a hardware Selkies encoder needs the device gids kept in the
    # supplementary group set (the gids come from the nodes, which belong to
    # the HOST, not from the container's /etc/group).
    run_groups=""
    for dev in /dev/dri/* /dev/nvidiactl /dev/nvidia[0-9]*; do
        [ -e "${dev}" ] || continue
        dev_gid="$(stat -c %g "${dev}" 2>/dev/null || true)"
        [ -n "${dev_gid}" ] || continue
        case ",${run_groups}," in
            *",${dev_gid},"*) : ;;
            *) run_groups="${run_groups:+${run_groups},}${dev_gid}" ;;
        esac
    done
    # setpriv demands an explicit group decision alongside --regid.
    if [ -n "${run_groups}" ]; then
        DROP=(setpriv --reuid="${run_uid}" --regid="${run_gid}" --groups="${run_groups}")
    else
        DROP=(setpriv --reuid="${run_uid}" --regid="${run_gid}" --clear-groups)
    fi
    RUN_NGINX_USER="${run_name}"

    # The browser profile is opened read-write by chromium: own it by the
    # run user (covers fresh root-created dirs and leftovers from earlier
    # root-mode starts alike; a no-op walk once everything is owned).
    mkdir -p "${CHROMIUM_USER_DATA_DIR}"
    chown_begin="$(date +%s)"
    chown -R "${run_uid}:${run_gid}" "${CHROMIUM_USER_DATA_DIR}"
    log "RUN_USER: ${CHROMIUM_USER_DATA_DIR} now owned by ${run_uid}:${run_gid} ($(( $(date +%s) - chown_begin ))s)"

    # Root-owned runtime leftovers (e.g. after `docker restart` of a
    # container that previously ran as root) would block the dropped
    # daemons: the pulse socket dir is 0700 and a stale X socket cannot be
    # unlinked across uids. Remove them; each daemon recreates its own as
    # the run user. The X socket dir is pre-created here too — a non-root
    # Xvfb refuses to create it "securely" itself (_XSERVTransmkdir error).
    rm -rf "${PULSE_RUNTIME_PATH}"
    rm -f /tmp/.X11-unix/X*
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

    log "RUN_USER: desktop stack + nginx workers run as ${run_name} (uid=${run_uid} gid=${run_gid}${run_groups:+ groups=${run_groups}}); PID 1 + nginx master stay root"
fi

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
    # X clients try the display's ABSTRACT socket (@/tmp/.X11-unix/X<n>)
    # before the filesystem one, and abstract sockets live in the network
    # namespace. With network_mode: host a host X server (Xorg/Xwayland) on
    # the same display number would capture chromium/selkies and make Xvfb
    # fail — so skip to the next display number nobody uses there.
    disp_num="${DISPLAY#*:}"
    disp_num="${disp_num%%.*}"
    case "${disp_num}" in
        ''|*[!0-9]*) die "DISPLAY='${DISPLAY}' must look like :<number>" ;;
    esac
    disp_wanted="${disp_num}"
    while grep -q "[[:space:]]@/tmp/\.X11-unix/X${disp_num}\$" /proc/net/unix 2>/dev/null; do
        disp_num=$((disp_num + 1))
        [ "${disp_num}" -le $((disp_wanted + 100)) ] || die "no free X display found from :${disp_wanted} upwards"
    done
    if [ "${disp_num}" != "${disp_wanted}" ]; then
        log "display :${disp_wanted} is already taken in this network namespace (host network?) -> using :${disp_num}"
    fi
    DISPLAY=":${disp_num}"

    # An X screen can never grow past the geometry it was created with, so a
    # fixed -screen of SCREEN_GEOMETRY caps Selkies' browser-driven resize at
    # the working size: a browser larger than the screen stays cropped
    # ("screen cannot be larger than ..." in the selkies log). Create the
    # screen at the SCREEN_GEOMETRY_MAX ceiling instead and preset the working
    # size right after — the same shape the official selkies-session brings
    # its display up in (XVFB_ARGS 8192x4096 + a RandR preset).
    XVFB_SCREEN="${SCREEN_GEOMETRY}"
    [ -n "${SCREEN_GEOMETRY_MAX}" ] && XVFB_SCREEN="${SCREEN_GEOMETRY_MAX}"

    log "starting Xvfb on display ${DISPLAY} (screen ${XVFB_SCREEN}, working ${SCREEN_GEOMETRY})"
    # -nolisten local: no abstract socket, only /tmp/.X11-unix/X<n> inside
    # the container's filesystem. -ac turns X access control off, so an
    # abstract socket would let any process sharing the network namespace
    # (every host process, with network_mode: host) drive the browser.
    "${DROP[@]}" Xvfb "${DISPLAY}" -screen 0 "${XVFB_SCREEN}" +extension "COMPOSITE" \
        +extension "DAMAGE" +extension "RANDR" +extension "RENDER" \
        +extension "XTEST" -nolisten tcp -nolisten local -ac -noreset \
        >/tmp/xvfb.log 2>&1 &
    pids+=($!)
    XSOCKET="/tmp/.X11-unix/X${DISPLAY#*:}"
    for _ in $(seq 1 50); do [ -S "${XSOCKET}" ] && break; sleep 0.2; done
    [ -S "${XSOCKET}" ] || die "Xvfb did not create ${XSOCKET}; see /tmp/xvfb.log"

    if [ "${XVFB_SCREEN}" != "${SCREEN_GEOMETRY}" ]; then
        # Preset the working size through the same RandR path a browser
        # resize takes (mode creation + screen size; selkies-resize defaults
        # to 60 Hz where nothing configured one). Cosmetic on failure: the
        # display then stays at the ceiling until the first client resize.
        INIT_W="${SCREEN_GEOMETRY%%x*}"
        INIT_H="$(printf '%s' "${SCREEN_GEOMETRY}" | cut -dx -f2)"
        if ! "${DROP[@]}" selkies-resize "${INIT_W}x${INIT_H}" >/tmp/display-preset.log 2>&1; then
            log "WARN: presetting ${INIT_W}x${INIT_H} failed (see /tmp/display-preset.log); the display stays at ${XVFB_SCREEN} until a client resizes it"
        fi
    fi

    # Compositing manager for the fresh display. No WM runs here and Xvfb
    # has no compositor of its own, and without a compositing manager
    # chromium refuses to alpha-blend its popup windows: the right-click
    # context menu loses its drop shadow and — being a plain white sheet —
    # looks borderless against light pages. picom only needs to RUN:
    # chromium paints the shadow itself into an ARGB popup window, picom
    # supplies the blending. picom's own decorations stay off (shadow=false)
    # so nothing is painted on top of chromium's; the backend is pinned to
    # xrender because the GLX backend has nothing to grab on the GL-less
    # Xvfb display. Cosmetic, so a dead picom only warns.
    if [ "${ENABLE_COMPOSITOR}" = "true" ]; then
        if command -v picom >/dev/null 2>&1; then
            printf 'shadow = false\nfading = false\nbackend = "xrender"\n' \
                >/tmp/picom.conf
            log "starting picom compositor on display ${DISPLAY}"
            "${DROP[@]}" picom --config /tmp/picom.conf >/tmp/picom.log 2>&1 &
            picom_pid=$!
            pids+=("${picom_pid}")
            sleep 0.5
            kill -0 "${picom_pid}" 2>/dev/null || log "WARNING: picom exited early; popup menus will render without shadows (see /tmp/picom.log)"
        else
            log "WARNING: picom not found; popup menus will render without shadows (image built without picom?)"
        fi
    fi

    log "starting PulseAudio (socket ${PULSE_SERVER})"
    # PulseAudio demands a 0700 runtime dir owned by its own uid ("Failed to
    # create secure directory" + exit otherwise), so a plain root mkdir -p
    # breaks the RUN_USER mode: hand the dir over when dropping privileges.
    if [ "${#DROP[@]}" -gt 0 ]; then
        install -d -o "${run_uid}" -g "${run_gid}" -m 700 "${PULSE_RUNTIME_PATH}"
    else
        mkdir -p "${PULSE_RUNTIME_PATH}"
    fi
    "${DROP[@]}" pulseaudio --daemonize=no --exit-idle-time=-1 --disallow-exit \
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

    log "starting selkies on ${SELKIES_ADDR}:${SELKIES_INTERNAL_PORT} (encoder ${SELKIES_ENCODER:-h264enc}, path ${SELKIES_SUBFOLDER:-/}, fronted by nginx)"
    # Extra settings ride the native SELKIES_* env vars (CLI > env > default).
    # TLS terminates at nginx, so selkies itself always serves plain HTTP on
    # the loopback port nginx proxies to.
    # shellcheck disable=SC2086
    "${DROP[@]}" selkies \
        --addr="${SELKIES_ADDR}" \
        --port="${SELKIES_INTERNAL_PORT}" \
        --subfolder="${SELKIES_SUBFOLDER}" \
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

    # --- GPU: hardware GL when the container owns a real GPU ---------------
    # compose.gpu.yaml (Intel/AMD: /dev/dri passthrough) or
    # compose.gpu-nvidia.yaml (nvidia runtime) pass a host GPU in; detect it
    # here. Only DEVICE NODES count as evidence: /proc/driver/nvidia is
    # visible in every container on a host with the kernel module loaded
    # (it reflects the host kernel, not the container), and the nvidia
    # toolkit only creates /dev/nvidiactl inside the container when the
    # passthrough actually worked. A /dev/dri node owned by nvidia-drm is
    # skipped — Mesa cannot drive it (only the injected nvidia GL stack can,
    # detected via /dev/nvidiactl below). In "hw" mode chromium renders via
    # Vulkan/ANGLE (see the --use-angle=vulkan note below), which needs no
    # GL visuals from the software Xvfb display.
    GPU_RENDER_NODE=""
    for node in /dev/dri/renderD*; do
        [ -e "${node}" ] || continue
        grep -q 'DRIVER=nvidia' "/sys/class/drm/${node##*/}/device/uevent" \
            2>/dev/null && continue
        GPU_RENDER_NODE="${node}"
        break
    done
    if [ -z "${GPU_RENDER_NODE}" ] && [ -e /dev/nvidiactl ]; then
        GPU_RENDER_NODE="nvidia (/dev/nvidiactl)"
    fi
    if [ "${CHROMIUM_GPU}" = "auto" ]; then
        if [ -n "${GPU_RENDER_NODE}" ]; then
            CHROMIUM_GPU=hw
        else
            CHROMIUM_GPU=sw
        fi
    fi
    # Render on the device when one is present, except in "off" mode ("off"
    # forces the software path even with a GPU attached). "strict" keeps its
    # name — the SwiftShader decision below needs to tell it apart — but
    # still uses a present device.
    if [ -n "${GPU_RENDER_NODE}" ] && [ "${CHROMIUM_GPU}" != "off" ]; then
        GPU_HW=true
    else
        GPU_HW=false
    fi
    log "chromium: GPU mode=${CHROMIUM_GPU}${GPU_RENDER_NODE:+ (${GPU_RENDER_NODE})}"

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
        # --disable-gpu only without a usable device: new headless renders
        # on the GPU when one is passed in (see GPU detection above).
        CHROMIUM_FLAGS+=(--headless)
        [ "${GPU_HW}" = "true" ] || CHROMIUM_FLAGS+=(--disable-gpu)
    else
        # Headed on the Xvfb display (default): the browser window shows up in
        # the Selkies stream, so automation can be watched live.
        WIN_W="${SCREEN_GEOMETRY%%x*}"
        WIN_H="$(echo "${SCREEN_GEOMETRY}" | cut -dx -f2)"
        # No window manager runs on this Xvfb display, so --start-maximized
        # is inert; chrome would otherwise restore a stale window position
        # from the persisted profile (e.g. +184+163, off the screen) and
        # shaves 1px off a window size that exactly matches the screen.
        # Pin the window to the top-left corner and ask for one extra pixel
        # per axis: the result covers the screen exactly (the spillover is
        # clipped by the screen edges).
        CHROMIUM_FLAGS+=(--window-position="0,0" \
            --window-size="$((WIN_W + 1)),$((WIN_H + 1))" \
            --start-maximized --no-first-run)
    fi
    # Hardware GL via the Vulkan/ANGLE backend. Explicit on purpose:
    # chromium's automatic backend selection prefers the native-GL path,
    # which cannot work on the software Xvfb display (no window-system GL
    # visuals -> "Couldn't find an EGLConfig", the GPU process exits and
    # chrome://gpu ends up all-disabled). Vulkan renders offscreen and
    # presents to the X window via xcb, which needs no GL visuals.
    # Verified on nvidia CDI passthrough (RTX 2080 Ti): WebGL then reports
    # "ANGLE (NVIDIA, Vulkan 1.4.341 (NVIDIA GeForce RTX 2080 Ti))", while
    # auto selection lands on SwiftShader and forced "--use-angle=gl" kills
    # WebGL entirely. --enable-features=Vulkan additionally moves the
    # display compositor (viz) onto Vulkan: without it viz composites in
    # software and chrome://gpu reports WebGL/WebGPU as "enabled_readback"
    # ("Hardware accelerated but at reduced performance" — GPU frames are
    # read back into the CPU compositor). With it, verified on the AMD
    # iGPU (RADV): gpu_compositing=enabled, webgl/webgpu=enabled (no
    # readback). If the Vulkan stack is unusable, chromium falls back
    # internally and SwiftShader (allowed below) keeps WebGL alive.
    # Both are appended before CHROMIUM_EXTRA_ARGS so a user's own
    # --enable-features there still wins (chromium keeps the last
    # occurrence of a repeated switch).
    if [ "${GPU_HW}" = "true" ]; then
        CHROMIUM_FLAGS+=(--use-angle=vulkan --enable-features=Vulkan)
    fi
    # Software WebGL fallback: Chrome 137+ gates SwiftShader behind
    # --enable-unsafe-swiftshader; without the switch WebGL is unavailable.
    # Allowed in every mode except "strict" — the browser must never report
    # a SwiftShader renderer there — so WebGL works without a GPU (auto/off)
    # and survives a device that errors out mid-run (auto with hardware).
    if [ "${CHROMIUM_GPU}" != "strict" ]; then
        CHROMIUM_FLAGS+=(--enable-unsafe-swiftshader)
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

    # Screen follower. The launch flags above size the window for the
    # startup screen only, and no window manager runs on this display to
    # re-maximize it, so after Selkies' browser-driven resize the window
    # stayed at SCREEN_GEOMETRY: a larger screen showed it in one corner
    # next to black, a smaller one cropped it. A RandR size change reaches
    # the root window as a ConfigureNotify; on each one (and on every newly
    # mapped window) the follower moves chromium's main windows
    # (WM_WINDOW_ROLE "browser") to 0,0 at the full screen size. Popups,
    # app windows and undocked DevTools carry other roles and stay as
    # chromium placed them. Started before chromium so the first window is
    # caught at map time. Cosmetic, so a missing python3-xlib only warns.
    if [ "${CHROMIUM_HEADLESS}" = "0" ] && [ "${CHROMIUM_FOLLOW_SCREEN}" = "true" ]; then
        if python3 -c 'import Xlib' 2>/dev/null; then
            cat >/tmp/chromium-follow-screen.py <<'PYFOLLOW'
from Xlib import X, display, error

d = display.Display()
d.set_error_handler(lambda *_: None)  # windows may vanish mid-configure
root = d.screen().root
ROLE = d.intern_atom("WM_WINDOW_ROLE")
root.change_attributes(event_mask=X.StructureNotifyMask | X.SubstructureNotifyMask)


def fit(win, w, h):
    try:
        if win.get_attributes().override_redirect:
            return
        role = win.get_full_property(ROLE, X.AnyPropertyType)
        if not role or role.value != b"browser":
            return
        g = win.get_geometry()
        if (g.x, g.y, g.width, g.height) == (0, 0, w, h):
            return
        win.configure(x=0, y=0, width=w, height=h)
        print(f"0x{win.id:x}: {g.width}x{g.height}+{g.x}+{g.y} -> {w}x{h}+0+0", flush=True)
    except error.XError:
        pass


def fit_all():
    g = root.get_geometry()
    for win in root.query_tree().children:
        fit(win, g.width, g.height)
    d.flush()


fit_all()
while True:
    ev = d.next_event()
    if ev.type == X.ConfigureNotify and ev.window.id == root.id:
        fit_all()
    elif ev.type == X.MapNotify:
        g = root.get_geometry()
        fit(ev.window, g.width, g.height)
        d.flush()
PYFOLLOW
            log "starting chromium screen follower on display ${DISPLAY}"
            "${DROP[@]}" python3 -u /tmp/chromium-follow-screen.py \
                >/tmp/chromium-follow-screen.log 2>&1 &
            pids+=($!)
        else
            log "WARNING: python3-xlib not found; the chromium window keeps its startup size when the screen is resized (image built without python3-xlib?)"
        fi
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
    "${DROP[@]}" mkdir -p "${CHROMIUM_USER_DATA_DIR}/Default"
    "${DROP[@]}" python3 - "${CHROMIUM_USER_DATA_DIR}/Default/Preferences" "${CHROMIUM_LANG}" <<'PYSEED'
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
# HTTPS-First balanced mode is switched by this PREF, not by the
# --disable-features switch: a profile that ran once without the flag
# persists "enabled": true, and every later start ignores the flag and
# hard-fails http navigations on hosts whose https is broken
# (net::ERR_BLOCKED_BY_CLIENT). Pin it off so an existing profile heals.
prefs["https_first_balanced_mode_enabled"] = False
prefs["https_only_mode_auto_enabled"] = False
json.dump(prefs, open(path, "w"))
PYSEED
    # Chromium on Linux ignores --lang for both UI and Accept-Language; the
    # LANG env var is what selects them (verified with LANG=zh_CN.UTF-8:
    # Chinese UI, zh-CN navigator.language, zh-CN,zh selected_languages).
    # Map the BCP-47 spelling (e.g. en-US) to the POSIX one (en_US.UTF-8).
    CHROMIUM_LOCALE_POSIX="$(echo "${CHROMIUM_LANG}" | tr '-' '_').UTF-8"
    LANG="${CHROMIUM_LOCALE_POSIX}" LC_ALL="${CHROMIUM_LOCALE_POSIX}" \
        "${DROP[@]}" "${CHROME_BIN}" "${CHROMIUM_FLAGS[@]}" "${CHROMIUM_START_URL}" \
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
# forwarder), on these container ports (NGINX_LISTEN_HTTP_PORT / NGINX_LISTEN_HTTPS_PORT /
# CDP_LISTEN_PORT):
#   ${NGINX_LISTEN_HTTP_PORT}  -> 127.0.0.1:${SELKIES_INTERNAL_PORT}  web UI, HTTP (always)
#   ${NGINX_LISTEN_HTTPS_PORT} -> 127.0.0.1:${SELKIES_INTERNAL_PORT}  web UI, TLS (optional)
#   ${CDP_LISTEN_PORT} -> 127.0.0.1:${CDP_INTERNAL_PORT}     chromium CDP
# plus one listener per PORT_FORWARDS entry (same-network peers, see the
# PORT_FORWARDS block above). Every proxy is WebSocket-capable (CDP and
# Selkies signaling both need it).

listen_ports=()
upstream_ports=()
if [ "${ENABLE_SELKIES}" = "true" ]; then
    listen_ports+=("${NGINX_LISTEN_HTTP_PORT}")
    upstream_ports+=("${SELKIES_INTERNAL_PORT}")
    if [ "${ENABLE_HTTPS}" = "true" ]; then
        listen_ports+=("${NGINX_LISTEN_HTTPS_PORT}")
    fi
elif [ "${ENABLE_HTTPS}" = "true" ]; then
    log "NOTE: ENABLE_HTTPS=true ignored: the web UI is disabled (ENABLE_SELKIES=false)"
fi
if [ "${ENABLE_CDP}" = "true" ]; then
    listen_ports+=("${CDP_LISTEN_PORT}")
    upstream_ports+=("${CDP_INTERNAL_PORT}")
fi

# --- extra port forwards (PORT_FORWARDS) --------------------------------------
# PORT_FORWARDS="3080=peer:80 6080=other:6080" (space or comma separated) makes
# nginx also listen on each LISTEN port and reverse-proxy it to HOST:PORT —
# typically a sibling container on the same docker network, reached by
# container name. Deliberate properties:
#   * same nginx instance & lifecycle as every other listener (no extra
#     process, no extra image dependency, dies with the container);
#   * the http-level proxy defaults apply: WebSocket upgrade, 24h read/write
#     timeouts, 50m bodies — forwarded apps that speak WS just work;
#   * the peer hostname is resolved PER REQUEST via docker's embedded DNS
#     (resolver below), not at config-parse time: this container starts fine
#     while the peer is still down, and picks up its new IP after a recreate
#     (valid=10s) — requests 502 until the peer answers, instead of the whole
#     front door failing `nginx -t`;
#   * HTTP reverse proxy, not a raw TCP pipe; an https:// upstream would need
#     proxy_ssl on (not exposed as a knob — none of our peers speak TLS).
FORWARD_SERVERS=""
# nginx's resolver needs an explicit DNS server: take the container's own
# (/etc/resolv.conf) — docker's embedded 127.0.0.11 on user-defined networks,
# the host's resolver with network_mode: host or the default bridge.
FORWARD_RESOLVER="$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf 2>/dev/null)"
case "${FORWARD_RESOLVER}" in
    '') FORWARD_RESOLVER="127.0.0.11" ;;
    *%*) die "PORT_FORWARDS: nameserver '${FORWARD_RESOLVER}' in /etc/resolv.conf has a zone id nginx cannot use" ;;
    *:*) FORWARD_RESOLVER="[${FORWARD_RESOLVER}]" ;;
esac
forward_listen_ports=()
forward_targets=()
if [ -n "${PORT_FORWARDS}" ]; then
    for spec in $(printf '%s\n' "${PORT_FORWARDS}" | tr ',' ' '); do
        [ -n "${spec}" ] || continue
        case "${spec}" in
            *=*) : ;;
            *) die "PORT_FORWARDS entry '${spec}' must be LISTEN=HOST:PORT" ;;
        esac
        fwd_listen="${spec%%=*}"
        fwd_target="${spec#*=}"
        case "${fwd_listen}" in
            ''|*[!0-9]*) die "PORT_FORWARDS listen port '${fwd_listen}' is not a number (entry '${spec}')" ;;
        esac
        case "${fwd_target}" in
            *:*) : ;;
            *) die "PORT_FORWARDS target '${fwd_target}' must be HOST:PORT (entry '${spec}')" ;;
        esac
        forward_listen_ports+=("${fwd_listen}")
        forward_targets+=("${fwd_target}")
        FORWARD_SERVERS="${FORWARD_SERVERS}
$(cat <<EOF
    # extra port forward ${fwd_listen} -> ${fwd_target} (PORT_FORWARDS)
    server {
        listen ${LISTEN_PREFIX}${fwd_listen};
        server_name _;
        # container DNS (docker's embedded 127.0.0.11 on compose networks);
        # per-request resolution keeps this listener (and the whole nginx)
        # up while the peer container is down
        resolver ${FORWARD_RESOLVER} valid=10s ipv6=off;
        location / {
            # variable target => resolved at request time via the resolver
            # above, NOT at config-parse time (nginx -t never needs the peer)
            set \$fwd_upstream ${fwd_target};
            proxy_pass http://\$fwd_upstream;
        }
    }
EOF
)"
    done
fi

# A listener colliding with a loopback upstream would make nginx fail at bind
# time with a cryptic error; fail fast with a clear one.
all_ports=("${listen_ports[@]}" "${upstream_ports[@]}" "${forward_listen_ports[@]}")
for i in "${!all_ports[@]}"; do
    for j in "${!all_ports[@]}"; do
        if [ "${i}" -lt "${j}" ] && [ "${all_ports[$i]}" = "${all_ports[$j]}" ]; then
            die "port ${all_ports[$i]} is used more than once (listen: ${listen_ports[*]:-none}; upstream: ${upstream_ports[*]:-none}; forwards: ${forward_listen_ports[*]:-none})"
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
# Workers buffer large request bodies through these temp dirs as their own
# uid — hand them over when privileges are dropped (nobody, the compiled
# default, cannot write into root-owned 0755 dirs either, but RUN_USER
# should not inherit that wart).
[ -n "${RUN_NGINX_USER}" ] \
    && chown -R "${run_uid}:${run_gid}" /tmp/nginx

# nginx workers as the RUN_USER (the `user` directive takes a NAME, which
# is why numeric ids get a synthesized passwd entry above); empty = compiled
# default nobody, the historical behavior.
NGINX_USER_CONF=""
[ -n "${RUN_NGINX_USER}" ] && NGINX_USER_CONF="user ${RUN_NGINX_USER};"

WEB_SERVERS=""
if [ "${ENABLE_SELKIES}" = "true" ]; then
    # Selkies serves every route under SELKIES_SUBFOLDER itself, so requests
    # pass through unmodified (no prefix stripping). With a subfolder, the
    # bare root and the slash-less prefix redirect to "<prefix>/": the web
    # client derives its API/WebSocket base from the page URL's directory.
    # Relative redirects keep working behind docker port mapping and an
    # outer reverse proxy, where nginx's own host:port would be wrong.
    WEB_LOCATIONS="        location / {
            proxy_pass http://127.0.0.1:${SELKIES_INTERNAL_PORT};
        }"
    if [ -n "${SELKIES_SUBFOLDER}" ]; then
        WEB_LOCATIONS="${WEB_LOCATIONS}
        location = / {
            absolute_redirect off;
            return 302 ${SELKIES_SUBFOLDER}/;
        }
        location = ${SELKIES_SUBFOLDER} {
            absolute_redirect off;
            return 301 ${SELKIES_SUBFOLDER}/;
        }"
    fi
    WEB_SERVERS="$(cat <<EOF
    # web UI over plain HTTP (always on)
    server {
        listen ${LISTEN_PREFIX}${NGINX_LISTEN_HTTP_PORT};
        server_name _;
${WEB_LOCATIONS}
    }
EOF
)"
    if [ -n "${TLS_CERT}" ]; then
        WEB_SERVERS="${WEB_SERVERS}
$(cat <<EOF
    # web UI over HTTPS (ENABLE_HTTPS=true)
    server {
        listen ${LISTEN_PREFIX}${NGINX_LISTEN_HTTPS_PORT} ssl;
        server_name _;
        ssl_certificate ${TLS_CERT};
        ssl_certificate_key ${TLS_KEY};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
${WEB_LOCATIONS}
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
        listen ${LISTEN_PREFIX}${CDP_LISTEN_PORT};
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
${NGINX_USER_CONF}
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
${FORWARD_SERVERS}
}
EOF

if ! nginx_out="$(nginx -t -c "${NGINX_CONF}" 2>&1)"; then
    die "nginx config invalid: ${nginx_out}"
fi

fronts=""
[ "${ENABLE_SELKIES}" = "true" ] && fronts="http:${NGINX_LISTEN_HTTP_PORT}"
[ -n "${TLS_CERT}" ] && fronts="${fronts} https:${NGINX_LISTEN_HTTPS_PORT}"
[ "${ENABLE_CDP}" = "true" ] && fronts="${fronts} cdp:${CDP_LISTEN_PORT}"
for i in "${!forward_listen_ports[@]}"; do
    fronts="${fronts} fwd:${forward_listen_ports[$i]}->${forward_targets[$i]}"
done
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
