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
# this path in the image the moment the pod starts, so what actually governs
# behavior at runtime is whatever ownership/mode the volume itself shows up
# with — NOT what the image baked.
#
# mkdir -p is a safe no-op if the mount already provided the directory (the
# normal case). The chmod is deliberately best-effort, NOT `set -e`-fatal:
# chmod requires OWNING the target, and under an arbitrary-UID SCC or a plain
# Kubernetes uid this process very often does not own a root-created mount —
# attempting it anyway and letting failure abort the container was tried and
# is wrong: it turned a directory that was ALREADY sufficiently permissive
# (Kubernetes' emptyDir default) into a hard crash-loop on a chmod nobody
# needed. If the mount is NOT permissive enough, Xvnc's own bind() on the
# socket fails next with a clear, specific error — a far better diagnostic
# than this script dying one step earlier on a permission check that was
# never the real requirement.
mkdir -p /tmp/.X11-unix 2>/dev/null || true
if chmod 1777 /tmp/.X11-unix 2>/dev/null; then
    log "set /tmp/.X11-unix to 1777"
else
    log "WARN: not the owner of /tmp/.X11-unix, could not chmod it — trusting the mount's existing permissions"
fi

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

# --- Stale lock cleanup -------------------------------------------------------
# The xstartup single-instance lock above is a DIRECTORY removed by an EXIT
# trap, and that trap does not run when the process is SIGKILLed — so a
# surviving /tmp/che-as-session.lock parks BOTH invocations in `sleep infinity`
# and openbox never starts. The window comes up unmanaged (no maximize, no
# undecorate), which is a degradation nothing attributes to a leftover
# directory. It matters MORE here than in the monolith: this container's PID 1
# is Che's wait-forever command, so a re-exec of this entrypoint (a postStart
# re-run, or a developer restarting the display by hand) inherits the whole of
# /tmp without the container ever restarting. Cleared here, where the session
# is provably new, exactly as container/entrypoint.sh does it.
if rmdir /tmp/che-as-session.lock 2>/dev/null; then
    log "removed a stale xstartup session lock"
fi

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
# PUBLISH THE X COOKIE WHERE THE DEV CONTAINER CAN READ IT.
#
# kasmvncserver starts Xvnc with `-auth ${HOME}/.Xauthority`, and X then rejects
# any client that cannot present the MIT-MAGIC-COOKIE from it. Under the split
# the client is Android Studio in ANOTHER container, which sees none of this
# container's HOME — so without this the handover fails with
#
#   java.awt.AWTError: Can't connect to X11 window server using ':1'
#
# on a display whose socket is present and healthy, which is a genuinely
# confusing pair of facts to be handed.
#
# The shared socket directory is the one path both containers already mount, so
# the cookie rides along beside the socket. Published in the BACKGROUND, after a
# wait, because kasmvncserver writes the cookie while starting and this script
# execs into it — there is no later point to do it from.
#
# Not a secret leak: this directory is inside the pod, both containers run as
# uid 1000, and anything able to read it can already reach the socket it sits
# next to. 0644 rather than 0600 because "same uid" is a property of the images
# we ship, not of an image a workspace brings.
(
    # KEEP IT IN STEP, do not copy once. kasmvncserver rewrites the cookie
    # while it starts, and a single copy loses the race: observed live with
    # the published copy and the live file differing in content while sharing
    # an mtime to the second, and the IDE failing every relaunch with
    #
    #   Invalid MIT-MAGIC-COOKIE-1 key
    #   java.awt.AWTError: Can't connect to X11 window server using ':1'
    #
    # which is a worse failure than the missing cookie it replaced: the file
    # exists, so everything looks configured.
    #
    # Compared by CONTENT rather than timestamp, precisely because the mtimes
    # matched while the bytes did not. The file is ~136 bytes, so this costs
    # nothing to run for the life of the container, and it also covers Xvnc
    # regenerating the cookie on a restart.
    published=0
    while true; do
        if [ -s "${HOME}/.Xauthority" ] && [ -S "/tmp/.X11-unix/X${DISPLAY_NUM#:}" ]; then
            if ! cmp -s "${HOME}/.Xauthority" /tmp/.X11-unix/.Xauthority 2>/dev/null; then
                if cp "${HOME}/.Xauthority" /tmp/.X11-unix/.Xauthority.tmp 2>/dev/null \
                    && chmod 0644 /tmp/.X11-unix/.Xauthority.tmp 2>/dev/null \
                    && mv /tmp/.X11-unix/.Xauthority.tmp /tmp/.X11-unix/.Xauthority 2>/dev/null; then
                    [ "${published}" = 0 ] && log "published the X cookie for the dev container"
                    published=1
                fi
            fi
        fi
        sleep 2
    done
) &

exec kasmvncserver "${DISPLAY_NUM}" \
    -interface 127.0.0.1 \
    -websocketPort 6901 \
    -SecurityTypes None \
    -DisableBasicAuth 1 \
    -select-de manual \
    -prompt no \
    -log "*:stderr:30" \
    -fg
