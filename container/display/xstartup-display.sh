#!/usr/bin/env bash
# che-android-studio DISPLAY-sidecar entrypoint (asfp-split editor).
#
# Runs in the 'asfp-display' container: a thin X SERVER + KasmVNC + openbox,
# nothing else. Android Studio is NOT launched from here — it runs as an
# ordinary X client in the workspace's dev container, against DISPLAY=:1, over
# the /tmp/.X11-unix socket this container serves (shared via the devfile's
# x11-socket ephemeral volume, mounted at the same path in both containers).
#
# This is the display-only counterpart to container/entrypoint.sh, with
# everything IDE-specific removed: no asset resolution, no IDE_FLAVOR, no
# vmoptions/first-run seeding/jdk.table generation, no git identity, no D-Bus
# (openbox and Xvnc need no session bus; the dev entrypoint's D-Bus block
# exists for the IDE, which lives in the other container now). What's left is
# the X-server-and-WM half of that script, unchanged in substance.
#
# Order: X11 socket → passwd entry for the arbitrary UID → writable HOME →
# xstartup (openbox only) → kasmvnc write-user + config → exec kasmvncserver
# (PID-1 of this container).

set -euo pipefail

log() { printf '[%s] [display] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

DISPLAY_NUM=":1"

# --- X11 socket dir -----------------------------------------------------------
# /tmp/.X11-unix is the devfile's x11-socket volume, mounted here AND in the
# dev container. The Containerfile pre-creates+chmods this path too, but that
# bake is a fallback only: an ephemeral volume mount REPLACES whatever was at
# this path in the image the moment the pod starts, so the permissions that
# matter are the ones set here, at runtime, after the mount lands. Sticky +
# world-writable is the proven configuration (see the Containerfile's header
# comment) — the dev container's client and this container's Xvnc are
# different uids, and only a 1777 dir lets either of them create/open the
# socket first.
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# --- Arbitrary-UID passwd/group entry ----------------------------------------
# Same rationale as container/entrypoint.sh: under a restricted SCC this runs
# as an arbitrary UID in group 0 with no passwd entry, and both kasmvncserver
# and openbox call getpwuid(). The Containerfile bakes uid 1000 for plain
# Kubernetes; this covers every OTHER uid the SCC might hand out.
ensure_passwd_entry() {
    local home="$1" uid gid
    uid="$(id -u)"
    gid="$(id -g)"
    if ! getent passwd "${uid}" >/dev/null 2>&1; then
        if echo "developer:x:${uid}:${gid}:che-android-studio display:${home}:/bin/bash" >>/etc/passwd 2>/dev/null; then
            log "added /etc/passwd entry for uid=${uid}"
        else
            log "WARN: could not append /etc/passwd entry for uid=${uid}"
        fi
    fi
    if ! getent group "${gid}" >/dev/null 2>&1; then
        echo "developer:x:${gid}:" >>/etc/group 2>/dev/null || true
    fi
}

# --- HOME -----------------------------------------------------------------
# Just needs to be writable — this container carries no state worth
# persisting across restarts (KasmVNC's config/pki/lock files all regenerate
# on every start), so unlike the dev entrypoint's pick_writable_home there is
# no PVC candidate to prefer. Same three-candidate order kept anyway, in case
# a future devfile revision mounts persistUserHome here too.
pick_writable_home() {
    local cand
    for cand in /home/user /home/developer /tmp/che-home; do
        if mkdir -p "${cand}" 2>/dev/null && touch "${cand}/.asfp-display-write-test" 2>/dev/null; then
            rm -f "${cand}/.asfp-display-write-test"
            echo "${cand}"
            return 0
        fi
    done
    return 1
}

if HOME="$(pick_writable_home)"; then
    log "using writable HOME=${HOME}"
else
    HOME="/tmp/che-home"
    mkdir -p "${HOME}" 2>/dev/null || true
    log "WARN: no preferred HOME was writable; falling back to ${HOME}"
fi
export HOME
mkdir -p "${HOME}/.vnc" 2>/dev/null || true

ensure_passwd_entry "${HOME}"

# --- xstartup -----------------------------------------------------------------
# KasmVNC runs ~/.vnc/xstartup once Xkasmvnc is up (-select-de manual keeps it
# ours), and runs it TWICE — once from the server process, once from its
# child — hence the same single-instance mkdir-lock guard
# container/entrypoint.sh uses for the IDE loop. Here it just guards openbox:
# two window managers racing for the same X session is the same class of bug
# either way, IDE or no IDE.
cat >"${HOME}/.vnc/xstartup" <<XSTARTUP
#!/usr/bin/env bash
export HOME="${HOME}"

# SINGLE INSTANCE — see container/entrypoint.sh's xstartup for the full
# explanation. Must NOT exit: KasmVNC tears the X server down when xstartup
# returns, so the second invocation stays parked instead.
if ! mkdir "/tmp/che-as-session.lock" 2>/dev/null; then
    echo "[xstartup] another invocation already owns this session; parking"
    exec sleep infinity
fi
trap 'rmdir /tmp/che-as-session.lock 2>/dev/null || true' EXIT

# Window manager only. NO IDE launch here — Android Studio runs as an X
# client in the workspace's dev container, against this DISPLAY, over the
# shared /tmp/.X11-unix socket. openbox still needs to run wherever the X
# server is, because it decorates/places windows via the X protocol, not by
# being co-located with the process that created them.
openbox &

# Keep the session alive so KasmVNC doesn't tear down the X server.
wait
XSTARTUP
chmod +x "${HOME}/.vnc/xstartup"
log "wrote ${HOME}/.vnc/xstartup (display-only: openbox, no IDE)"

# --- KasmVNC write-access user ------------------------------------------------
# KasmVNC 1.x needs a write-access user to exist or it loops on an interactive
# prompt and never opens 6901. Pre-create one non-interactively (the password
# is irrelevant once basic auth is disabled below).
KASM_PASSWD_FILE="${HOME}/.kasmpasswd"
if command -v kasmvncpasswd >/dev/null 2>&1; then
    if printf '%s\n%s\n' "chestudio" "chestudio" \
        | kasmvncpasswd -u chestudio -wo "${KASM_PASSWD_FILE}" >/dev/null 2>&1; then
        log "created KasmVNC write-access user 'chestudio'"
    else
        log "WARN: kasmvncpasswd failed; KasmVNC may prompt for a user"
    fi
fi

# --- KasmVNC config: serve plain HTTP on loopback ----------------------------
# Che's gateway connects over http://127.0.0.1:6901 (TLS/auth at the edge), so
# KasmVNC must NOT require SSL. The unconditional cert-readability gate is
# satisfied by the world-readable throwaway pair the Containerfile generated
# under /etc/che-android-studio/pki.
cat >"${HOME}/.vnc/kasmvnc.yaml" <<KASMYAML
network:
  protocol: http
  ssl:
    require_ssl: false
    pem_certificate: /etc/che-android-studio/pki/snakeoil.pem
    pem_key: /etc/che-android-studio/pki/snakeoil.key
KASMYAML
log "wrote ${HOME}/.vnc/kasmvnc.yaml (require_ssl: false)"

# --- Stale X lock cleanup -----------------------------------------------------
# Same reasoning as container/entrypoint.sh: kasmvncserver refuses a display
# whose /tmp/.X<n>-lock exists ("A VNC server is already running as :1") and
# exits, which reads as a failed container rather than a leftover lock file.
# Exactly one Xvnc runs per pod, so anything found here is leftover from a
# previous attempt in THIS container, not a live server.
kasmvncserver -kill "${DISPLAY_NUM}" >/dev/null 2>&1 || true
rm -f "/tmp/.X${DISPLAY_NUM#:}-lock" 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISPLAY_NUM#:}" 2>/dev/null || true
rm -f "${HOME}/.vnc/"*":${DISPLAY_NUM#:}.pid" 2>/dev/null || true
ls -la "/tmp/.X${DISPLAY_NUM#:}-lock" 2>/dev/null \
    && log "WARN: /tmp/.X${DISPLAY_NUM#:}-lock survived cleanup — kasmvncserver will refuse the display"

# --- KasmVNC -------------------------------------------------------------------
# -DisableBasicAuth 1 is REQUIRED: -SecurityTypes None only covers the RFB
# layer; the websocket server otherwise 401s every request (incl. /healthz) →
# Che never goes healthy. kasmvncserver forwards unknown -Foo args to Xkasmvnc.
exec kasmvncserver "${DISPLAY_NUM}" \
    -interface 127.0.0.1 \
    -websocketPort 6901 \
    -SecurityTypes None \
    -DisableBasicAuth 1 \
    -select-de manual \
    -prompt no \
    -log "*:stderr:30" \
    -fg
