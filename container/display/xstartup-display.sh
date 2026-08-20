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
# --- Desktop dressing: wallpaper + DPI-aware window decorations ---------------
# Written as its own script because xstartup runs it under KasmVNC's DISPLAY,
# and because both jobs have to survive openbox being reconfigured.
#
# THE WALLPAPER. Until the IDE maps its first window the root window is plain
# black, which reads as a broken session rather than a starting one — and ASfP
# takes a while. KasmVNC already ships a splash image for its own connect
# screen, so reuse it: same artwork the developer just watched while the
# workspace started, no new asset, nothing to keep in sync. Its filename
# carries a content hash that changes between KasmVNC releases, hence the glob.
#
# THE DECORATIONS. openbox is an X client in THIS container and knows nothing
# about the IDE's scale, so at a 2x device pixel ratio the IDE scales and its
# dialog title bars do not — leaving close/maximise buttons a few device pixels
# across and genuinely hard to hit. openbox has no DPI setting; what it has is a
# titlebar sized from the label font and the theme's padding, so scaling those
# two scales the decorations. Config is read-only in the image, but openbox
# prefers ~/.config/openbox/rc.xml and ~/.themes, so the scaled copies go there.
#
# The ratio arrives from the BROWSER (see kasmvnc-subpath-fix.html) via the one
# directory this container shares with the workspace's own — the X11 socket
# volume. Watched rather than read once: it lands whenever the developer opens
# the workspace, which may be after this script starts, and it changes again if
# they move the window to a monitor with a different ratio.
cat >"${HOME}/.vnc/belt-desktop.sh" <<'BELT_DESKTOP'
#!/usr/bin/env bash
# Fails open at every step: a session with black wallpaper and unscaled
# decorations is worse-looking, not broken, and must never be worse than that.
set -u
DPR_FILE=/tmp/.X11-unix/.belt-dpr
OB_CFG="${HOME}/.config/openbox"
OB_THEME="${HOME}/.themes/StudioDark/openbox-3"
SRC_RC=/etc/xdg/openbox/rc.xml
SRC_THEME=/usr/share/themes/StudioDark/openbox-3/themerc

log() { printf '[%s] [desktop] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

set_wallpaper() {
    local img
    img="$(ls -1 /usr/share/kasmvnc/www/assets/splash-*.jpg 2>/dev/null | head -1)"
    # A solid backdrop FIRST, so even a missing/undecodable image leaves the
    # IDE's own background colour rather than black.
    xsetroot -solid '#2b2d30' 2>/dev/null || true
    if [ -n "${img}" ] && command -v feh >/dev/null 2>&1; then
        if feh --no-fehbg --bg-fill "${img}" 2>/dev/null; then
            log "wallpaper set from ${img}"
            return 0
        fi
    fi
    log "no splash image usable; left the solid backdrop"
}

# scale <dpr> — regenerate the openbox config and theme at that ratio.
scale_openbox() {
    local dpr="$1" font pad_w pad_h border
    # The 1x baselines, multiplied by the ratio. TUNED BY EYE against a
    # decorated window at 2x, not taken from openbox's defaults: those are 8pt
    # with 6px of horizontal padding, which scales to a title noticeably smaller
    # than the IDE's own chrome and to buttons packed hard against each other.
    # 10pt and 8px scale to a 20pt title and a comfortable gap. Overridable
    # because this is taste, and taste should not need a rebuild.
    #
    # padding.width is the ONLY spacing knob openbox offers here — it pads every
    # titlebar element, so raising it separates the buttons AND narrows the
    # label. 8 is the value where the buttons are comfortable and a real dialog
    # title still fits; going to 10 started ellipsizing short titles.
    # Round half-up without bc: openbox wants integers.
    font="$(awk -v d="${dpr}" -v b="${BELT_OB_FONT_PT:-10}" 'BEGIN{printf "%d", (b*d)+0.5}')"
    pad_w="$(awk -v d="${dpr}" -v b="${BELT_OB_PAD_W:-8}" 'BEGIN{printf "%d", (b*d)+0.5}')"
    pad_h="$(awk -v d="${dpr}" -v b="${BELT_OB_PAD_H:-4}" 'BEGIN{printf "%d", (b*d)+0.5}')"
    border="$(awk -v d="${dpr}" 'BEGIN{printf "%d", (1*d)+0.5}')"
    mkdir -p "${OB_CFG}" "${OB_THEME}" 2>/dev/null || return 1

    # The theme: same file with the three pixel dimensions scaled.
    if [ -r "${SRC_THEME}" ]; then
        sed -e "s/^padding\.width:.*/padding.width: ${pad_w}/" \
            -e "s/^padding\.height:.*/padding.height: ${pad_h}/" \
            -e "s/^border\.width:.*/border.width: ${border}/" \
            "${SRC_THEME}" > "${OB_THEME}/themerc" 2>/dev/null || return 1
    fi

    # The config: the shipped rc.xml with a <font> block per place, at the
    # scaled size. Any existing blocks are dropped first so this is idempotent.
    if [ -r "${SRC_RC}" ]; then
        python3 - "${SRC_RC}" "${OB_CFG}/rc.xml" "${font}" <<'PYEOF' || return 1
import re, sys
src, dst, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
xml = open(src).read()
# Drop any <font ...>...</font> we (or the image) put in before.
xml = re.sub(r"[ \t]*<font place=.*?</font>\n?", "", xml, flags=re.S)
places = ["ActiveWindow", "InactiveWindow", "MenuHeader", "MenuItem",
          "ActiveOnScreenDisplay", "InactiveOnScreenDisplay"]
block = "".join(
    '    <font place="%s">\n'
    "      <name>sans</name>\n"
    "      <size>%d</size>\n"
    "      <weight>normal</weight>\n"
    "      <slant>normal</slant>\n"
    "    </font>\n" % (p, size) for p in places)
# openbox requires the fonts inside <theme>; append just before it closes.
if "</theme>" in xml:
    xml = xml.replace("</theme>", block + "  </theme>", 1)
open(dst, "w").write(xml)
PYEOF
    fi
    # THE BUTTON GLYPHS. A scaled titlebar grows the buttons' clickable area
    # but NOT what is drawn in them: openbox renders close/iconify/maximise
    # from XBM masks at their native pixel size, and StudioDark ships none, so
    # it falls back to built-ins fixed at about 7px. At a 2x ratio that leaves
    # a correctly sized title next to glyphs a developer has to aim at. Themes
    # may supply their own masks (Bear2 in this image does), so generate them
    # at the scaled size — the one lever openbox actually offers here.
    # Sized against the TITLEBAR, not against the ratio directly. A flat 7*dpr
    # tracks the font but not the button it sits in: at dpr 2 that is a 14px
    # glyph inside a ~37px titlebar, which still reads as small and is still
    # fiddly to hit. openbox gives the button a box roughly the titlebar's inner
    # height (the label font plus its vertical padding), so derive from that and
    # take a little over half of it.
    local mask
    mask="$(awk -v f="${font}" -v p="${pad_h}" \
        'BEGIN{h=f*4/3+2*p; n=int(0.5*h+0.5); if(n<7)n=7; printf "%d", n}')"
    python3 - "${OB_THEME}" "${mask}" <<'PYEOF' || return 1
import os, sys
theme = sys.argv[1]
n = int(sys.argv[2])
t = max(1, int(round(n / 7.0)))          # stroke thickness, scaled with it

def xbm(name, hit):
    """Emit one XBM: rows padded to whole bytes, LSB = leftmost pixel."""
    rowbytes = (n + 7) // 8
    out = []
    for y in range(n):
        row = bytearray(rowbytes)
        for x in range(n):
            if hit(x, y):
                row[x // 8] |= 1 << (x % 8)
        out.extend(row)
    body = ", ".join("0x%02x" % b for b in out)
    with open(os.path.join(theme, name + ".xbm"), "w") as f:
        f.write("#define %s_width %d\n#define %s_height %d\n"
                "static unsigned char %s_bits[] = {\n %s };\n"
                % (name, n, name, n, name, body))

edge = n - 1
xbm("close",   lambda x, y: abs(x - y) < t or abs(x + y - edge) < t)
xbm("iconify", lambda x, y: y >= n - t - 1)
box = lambda x, y: x < t or x >= n - t or y < t or y >= n - t
xbm("max", box)
xbm("max_toggled", box)
xbm("shade",   lambda x, y: y < t)
xbm("desk",    box)
# Pressed/hover variants fall back to the base mask when absent, so the four
# above are the whole visible set.
PYEOF
    log "openbox scaled for dpr=${dpr} (font ${font}, padding ${pad_w}x${pad_h}, border ${border}, masks ${mask}px)"
    openbox --reconfigure 2>/dev/null || true
    start_compositor "${dpr}"
}

# start_compositor <dpr> — drop shadows under floating windows.
#
# WHY AT ALL. openbox draws a flat border in the theme's own colour, so a dialog
# over the IDE has almost nothing separating it from what is behind it — on a
# dark theme two stacked windows read as one surface, and it is genuinely hard
# to tell which one has focus. A shadow is the cheapest depth cue there is.
#
# xrender, NOT glx: this X server has RENDER and Composite but no GL worth
# speaking of, and picom on the glx backend against Xvnc either falls over or
# software-renders every frame. Fading and blur stay OFF — both repaint large
# regions continuously, and every repainted pixel here is a pixel KasmVNC has to
# encode and ship to a browser.
#
# Fails open, and can be turned off outright with BELT_DESKTOP_SHADOWS=0 if a
# session ever pays for it.
start_compositor() {
    local dpr="$1" radius offset
    [ "${BELT_DESKTOP_SHADOWS:-1}" = "0" ] && return 0
    command -v picom >/dev/null 2>&1 || return 0
    radius="$(awk -v d="${dpr}" 'BEGIN{printf "%d", (12*d)+0.5}')"
    offset="$(awk -v d="${dpr}" 'BEGIN{printf "%d", (-6*d)-0.5}')"
    # ~/.config need not exist yet: this runs before the first scale pass, which
    # is what otherwise creates it. Without this the heredoc below fails, picom
    # starts on its DEFAULTS — no shadows, and a compositor running for nothing.
    mkdir -p "${HOME}/.config" 2>/dev/null || return 0
    cat >"${HOME}/.config/picom.conf" <<PICOM
backend = "xrender";
shadow = true;
shadow-radius = ${radius};
shadow-opacity = 0.45;
shadow-offset-x = ${offset};
shadow-offset-y = ${offset};
fading = false;
# The root/desktop window must not cast one — the wallpaper is not a window
# floating over anything, and shadowing it just darkens the screen edges.
shadow-exclude = [
  "_NET_WM_WINDOW_TYPE@:a *= 'DESKTOP'",
  "class_g = 'desktop_window'"
];
PICOM
    # No config, no compositor. Starting one anyway gets picom's defaults, which
    # is the cost of compositing without the shadow that was the entire point.
    [ -s "${HOME}/.config/picom.conf" ] || {
        log "WARN: could not write picom.conf; leaving windows with flat borders"
        return 0
    }
    # Replace any picom from a previous ratio rather than stacking a second one;
    # two compositors on one display fight over every damage event.
    pkill -x picom 2>/dev/null || true
    sleep 1
    picom --config "${HOME}/.config/picom.conf" --daemon 2>/dev/null \
        && log "compositor up (shadow radius ${radius}, offset ${offset})" \
        || log "WARN: picom would not start; windows keep flat borders"
}

set_wallpaper
# At 1x to begin with, so a session that is never reported on still gets its
# depth cue; the watcher below re-tunes the radius once a ratio turns up.
start_compositor 1

# Watch for the ratio. Poll rather than inotify: one stat every two seconds for
# the life of a session costs nothing and adds no package.
last=""
while true; do
    if [ -s "${DPR_FILE}" ]; then
        dpr="$(cat "${DPR_FILE}" 2>/dev/null)"
        case "${dpr}" in
            ''|*[!0-9.]*) dpr="" ;;
        esac
        if [ -n "${dpr}" ] && [ "${dpr}" != "${last}" ]; then
            scale_openbox "${dpr}" && last="${dpr}"
            # openbox --reconfigure repaints the root, so restore the wallpaper.
            set_wallpaper
        fi
    fi
    sleep 2
done
BELT_DESKTOP
chmod +x "${HOME}/.vnc/belt-desktop.sh"
log "wrote ${HOME}/.vnc/belt-desktop.sh (wallpaper + DPI-aware decorations)"

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

# Wallpaper + DPI-aware decorations. Backgrounded and after openbox, because it
# reconfigures openbox and repaints the root window that openbox owns.
#
# Logged to a FILE, not /dev/null: everything in there fails open, so when it
# does fail the only evidence is a session that merely looks wrong — black
# behind the IDE, or title bars that stayed small — with nothing to read.
"${HOME}/.vnc/belt-desktop.sh" >/tmp/belt-desktop.log 2>&1 &

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
