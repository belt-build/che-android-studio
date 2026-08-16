#!/usr/bin/env bash
# che-android-studio desktop-session entrypoint.
#
# Runs in the DEV/runtime container (asfp-dev or studio-dev) after the editor
# definition's container-contribution merges the injected IDE in. The IDE
# payload + these assets were staged into the shared volume (/che-android-studio)
# by the injector image; the dev image provides KasmVNC, openbox, the GUI libs,
# the Android SDK, and the JCEF JBR.
#
# IMPORTANT: KasmVNC owns the X server. `kasmvncserver` STARTS its own X server
# (Xkasmvnc) — do NOT run Xvfb (it would abort with "A VNC server is already
# running"). The WM + IDE come up under ~/.vnc/xstartup, which KasmVNC runs.
#
# Order: resolve assets → passwd entry for the arbitrary UID → writable HOME/XDG
# → seed first-run state → dbus → xstartup (openbox + IDE restart loop) →
# kasmvnc write-user + config → exec kasmvncserver (PID-1 of the session).

set -euo pipefail

log() { printf '[%s] [entrypoint] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

DISPLAY_NUM=":1"

# --- Asset resolution (shared volume injected by the editor, else image) ----
# The injector copies skel/vmoptions/openbox-rc into the shared volume root.
# Prefer that; fall back to the image-resident /opt/che-android-studio for a
# non-split (monolith-style) run or local testing.
ASSET_BASE="/che-android-studio"
[ -d "${ASSET_BASE}/skel" ] || ASSET_BASE="/opt/che-android-studio"
SKEL_DIR="${ASSET_BASE}/skel"
STUDIO_VM_OPTIONS="${ASSET_BASE}/studio.vmoptions"

# --- IDE flavor -------------------------------------------------------------
# IDE_FLAVOR is set by the dev/injector image (asfp|studio). It selects the
# launcher path, the IDE config-dir name, and which first-run options apply.
IDE_FLAVOR="${IDE_FLAVOR:-asfp}"
# The injector copied the IDE tree into the shared volume at
# ${ASSET_BASE}/ide (dereferenced — NOT a symlink). The native ELF launcher is
# bin/studio for both ASfP and regular Android Studio (NOT bin/studio.sh, which
# ASfP flags as unsupported). Fall back to the in-image /opt path for a
# non-split/local run.
if [ -x "${ASSET_BASE}/ide/bin/studio" ]; then
    IDE_HOME="${ASSET_BASE}/ide"
else
    IDE_HOME="/opt/che-ide"
fi
STUDIO_BIN="${IDE_HOME}/bin/studio"

# Per-flavor IDE config dir under $XDG_CONFIG_HOME/Google/. The AUTHORITATIVE
# name is product-info.json's "dataDirectoryName" (e.g. AndroidStudio2025.1.1 —
# Android Studio uses THREE version components, NOT two). Hand-deriving it from
# ASFP_MAJOR_MINOR drifts: we once built "AndroidStudio2025.1" while the IDE used
# "AndroidStudio2025.1.1", so EVERY seeded first-run file (skip-wizard, SDK path,
# jdk.table, studio.jdk) landed in the wrong dir and was silently ignored. Read
# it from product-info.json; only fall back to the ENV-derived guess if absent.
derive_config_dirname() {
    local pi="${IDE_HOME}/product-info.json" name=""
    if [ -r "${pi}" ]; then
        name="$(grep -oE '"dataDirectoryName"[[:space:]]*:[[:space:]]*"[^"]*"' "${pi}" \
                | head -1 | sed -E 's/.*"dataDirectoryName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
    fi
    if [ -n "${name}" ]; then echo "${name}"; return 0; fi
    case "${IDE_FLAVOR}" in
        studio) echo "AndroidStudio${ASFP_MAJOR_MINOR:-2025.1}" ;;
        *)      echo "AndroidStudioForPlatform${ASFP_MAJOR_MINOR:-2025.3.2}" ;;
    esac
}
IDE_CONFIG_DIRNAME="$(derive_config_dirname)"
log "IDE config dir = ${IDE_CONFIG_DIRNAME} (from product-info.json dataDirectoryName)"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
# JCEF-enabled JBR (Cuttlefish view needs JCEF; the bundled IDE JBR lacks it).
JCEF_JBR_DIR="${JCEF_JBR_DIR:-/opt/che-android-studio/jbr-jcef}"
# The name the bundled JBR is registered under in jdk.table.xml, and referenced
# by from the default project's project-jdk-name. The two must agree exactly —
# a mismatch is silent and leaves the project JDK undefined, which is the bug
# this exists to fix.
JBR_SDK_NAME="${JBR_SDK_NAME:-JBR-21}"

# Align JAVA_HOME to the IDE's bundled JBR so Gradle's JDK == JAVA_HOME. Android
# Studio runs Gradle under its bundled JBR (${IDE_HOME}/jbr); if JAVA_HOME points
# elsewhere (the OS java-17), the IDE warns "Multiple Gradle daemons might be
# spawned because the Gradle JDK and JAVA_HOME locations are different" and
# actually starts a second daemon. Point JAVA_HOME at the bundled JBR (it's a
# full JDK 17+ — fine for AGP/Gradle). The JCEF JBR is a SEPARATE concern (boot
# runtime, via studio.jdk) and stays as-is.
if [ -x "${IDE_HOME}/jbr/bin/java" ]; then
    export JAVA_HOME="${IDE_HOME}/jbr"
    log "JAVA_HOME aligned to IDE bundled JBR: ${JAVA_HOME}"
fi

# --- Arbitrary-UID passwd/group entry ---------------------------------------
# Under the restricted SCC we run as an arbitrary UID in group 0 with no
# /etc/passwd entry → `groups: cannot find name for group ID 1000` and tools
# that call getpwuid() misbehave. The desktop image made /etc/passwd group-
# writable (chmod g=u); append an entry if ours is missing. HOME is finalized
# just below, so use the resolved value.
ensure_passwd_entry() {
    local home="$1" uid gid
    uid="$(id -u)"; gid="$(id -g)"
    if ! getent passwd "${uid}" >/dev/null 2>&1; then
        echo "developer:x:${uid}:${gid}:che-android-studio:${home}:/bin/bash" >> /etc/passwd 2>/dev/null \
            && log "added /etc/passwd entry for uid=${uid}" \
            || log "WARN: could not append /etc/passwd entry for uid=${uid}"
    fi
    if ! getent group "${gid}" >/dev/null 2>&1; then
        echo "developer:x:${gid}:" >> /etc/group 2>/dev/null || true
    fi
}

# --- HOME / XDG -------------------------------------------------------------
# Must run from a writable, PERSISTENT HOME (openbox, ~/.vnc, IDE config/caches,
# and the IDE's DirectoryLock .lock). Candidate order matters:
#   1. /home/user — where Che's persistUserHome mounts the per-user PVC
#      (subPath persistent-home). This is the writable, RESTART-PERSISTENT home.
#      Using it fixes both no-persistence AND the stale-".lock" crash on
#      stop/start (IntelliJ couldn't lock a config dir that lived in ephemeral
#      /tmp and carried a stale lock from an unclean shutdown).
#   2. /home/developer — alternate mount (bare image dir if the PVC isn't here).
#   3. /tmp/che-home — last-resort so the desktop still comes up (non-persistent).
pick_writable_home() {
    local explicit="${WORKSPACE_HOME:-}" candidates
    if [ -n "${explicit}" ]; then candidates="${explicit}"; else candidates="/home/user /home/developer /tmp/che-home"; fi
    for cand in ${candidates}; do
        for _ in $(seq 1 50); do   # up to ~5s each
            if mkdir -p "${cand}" 2>/dev/null && touch "${cand}/.asfp-write-test" 2>/dev/null; then
                rm -f "${cand}/.asfp-write-test"; echo "${cand}"; return 0
            fi
            sleep 0.1
        done
    done
    return 1
}

if HOME="$(pick_writable_home)"; then
    log "using writable HOME=${HOME}"
else
    HOME="/tmp/che-home"; mkdir -p "${HOME}" 2>/dev/null || true
    log "WARN: no preferred HOME was writable; falling back to ${HOME}"
fi
export HOME
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_DATA_HOME="${HOME}/.local/share"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}" "${HOME}/.vnc" 2>/dev/null || true

ensure_passwd_entry "${HOME}"

# Export SDK so the IDE (launched from xstartup) inherits it.
export ANDROID_SDK_ROOT ANDROID_HOME="${ANDROID_SDK_ROOT}"

# --- Relocate the IDE's memory-mapped VFS/caches OFF the idmapped PVC --------
# The single most damaging bug: IntelliJ's VFS stores its file-records +
# attributes in memory-mapped append-logs (StreamlinedBlobStorageOverMMappedFile,
# "VFS uses OverMMappedFile … storage"). When idea.system.path lives on the
# per-user PVC (/home/user — XFS, `idmapped`, RWO), mmap MAP_SHARED writeback is
# not coherent there: the VFS silently accumulates errors mid-session
# (idea.log: "VFS accumulated N errors", java.nio.BufferUnderflowException in
# AttributesStorageOverBlobStorage.readAttributeValue) and the IDE then can't
# append new file records → "Cannot create child file 'local.properties'" +
# "Multiple internal errors in the file system cache". ("Self-causation not
# permitted" is just the logger choking on the chained exception — a red
# herring.) Quota/space is NOT the cause (file creation at the OS level works).
#
# Fix: put idea.system.path (VFS, indexes, caches) + idea.log.path on /tmp,
# which is the container OVERLAY root — local, NOT idmapped, ~45 GB free. These
# are rebuildable; losing them on pod restart only re-indexes (cheaper than
# corruption). idea.config.path + idea.plugins.path STAY on the PVC ($HOME) so
# settings/plugins persist — they're small, not mmap'd, and don't corrupt.
# Per-flavor subdir keeps ASfP and Studio from sharing a system dir.
IDE_SYSTEM_PATH="/tmp/che-ide/${IDE_CONFIG_DIRNAME}/system"
IDE_LOG_PATH="/tmp/che-ide/${IDE_CONFIG_DIRNAME}/log"
mkdir -p "${IDE_SYSTEM_PATH}" "${IDE_LOG_PATH}" 2>/dev/null || true
log "IDE system/caches relocated off idmapped PVC → ${IDE_SYSTEM_PATH}"

# Assemble the runtime vmoptions: the static studio.vmoptions (window chrome)
# plus the idea.*.path overrides. STUDIO_VM_OPTIONS is the verified injection
# channel (the native launcher reads <PRODUCT>_VM_OPTIONS). config/plugins stay
# under $HOME; system/log move to /tmp.
# UI SCALE. A streamed desktop at the browser's native resolution renders the
# IDE too small to read — every developer's first act was to find the zoom
# setting.
#
# THE SETTING THE UI READS IS NotRoamableUiSettings/ideScale, seeded from
# skel/ide-options/other.xml. This property is kept because it applies before
# any settings file is loaded, but on its own it is NOT enough: set only here,
# Appearance > Accessibility > Zoom still reads 100%. Verified by changing the
# zoom in a live IDE and finding where it landed. Keep the two values equal.
IDE_UI_SCALE="${IDE_UI_SCALE:-1.25}"

RUNTIME_VM_OPTIONS="${HOME}/.vnc/studio-runtime.vmoptions"
{
    [ -r "${STUDIO_VM_OPTIONS}" ] && cat "${STUDIO_VM_OPTIONS}"
    printf '%s\n' \
        "-Didea.config.path=${XDG_CONFIG_HOME}/Google/${IDE_CONFIG_DIRNAME}" \
        "-Didea.plugins.path=${XDG_CONFIG_HOME}/Google/${IDE_CONFIG_DIRNAME}/plugins" \
        "-Didea.system.path=${IDE_SYSTEM_PATH}" \
        "-Didea.log.path=${IDE_LOG_PATH}" \
        "-Dide.ui.scale=${IDE_UI_SCALE}"
} > "${RUNTIME_VM_OPTIONS}" 2>/dev/null \
    && { STUDIO_VM_OPTIONS="${RUNTIME_VM_OPTIONS}"; export STUDIO_VM_OPTIONS; \
         log "wrote ${RUNTIME_VM_OPTIONS} (VFS off PVC, config on PVC)"; } \
    || { [ -r "${STUDIO_VM_OPTIONS}" ] && export STUDIO_VM_OPTIONS; \
         log "WARN: could not write runtime vmoptions; using static ${STUDIO_VM_OPTIONS}"; }

# --- First-run state seeding ------------------------------------------------
# $HOME (PVC) is empty on first start; seed templates from the (injected)
# SKEL_DIR into $HOME, ONLY if absent (never clobber a user's later choices).
# Skips the data-collection consent dialog (opted OUT) + the setup wizard and
# points the IDE at the pre-baked /opt/android-sdk + the JCEF JBR.
seed_if_absent() {
    local src="${SKEL_DIR}/$1" dst="$2"
    [ -e "${dst}" ] && return 0
    [ -e "${src}" ] || { log "WARN: skel missing: ${src}"; return 0; }
    mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
    cp -a "${src}" "${dst}" 2>/dev/null && log "seeded ${dst}" || log "WARN: failed to seed ${dst}"
}

# jdk.table.xml can't be a static template: the SDK image may carry any set of
# API levels (ANDROID_API_LEVELS, e.g. "34 36"). Generate one "Android API <L>
# Platform" <jdk> entry per level actually present under $ANDROID_SDK_ROOT.
generate_jdk_table() {
    local dst="$1" levels="${ANDROID_API_LEVELS:-}" lvl plat entries=""
    [ -e "${dst}" ] && return 0
    # Fall back to enumerating installed platforms if the env didn't list them.
    if [ -z "${levels}" ]; then
        for plat in "${ANDROID_SDK_ROOT}"/platforms/android-*; do
            [ -d "${plat}" ] && levels="${levels} ${plat##*/android-}"
        done
    fi
    # A JAVA SDK, first. Every entry this function used to write was an
    # `Android SDK`, so the table registered no JDK at all and a freshly
    # generated project opened on "Project JDK is not defined" — the developer
    # then picked one by hand, every time, in every session. The bundled JBR is
    # the JDK the IDE already runs on, so it is the only defensible default.
    local jbr="${IDE_HOME}/jbr" jdk_entry=""
    if [ -x "${jbr}/bin/java" ]; then
        jdk_entry="    <jdk version=\"2\">
      <name value=\"${JBR_SDK_NAME}\" />
      <type value=\"JavaSDK\" />
      <homePath value=\"${jbr}\" />
      <roots>
        <annotationsPath><root type=\"composite\" /></annotationsPath>
        <classPath><root type=\"composite\" /></classPath>
        <javadocPath><root type=\"composite\" /></javadocPath>
        <sourcePath><root type=\"composite\" /></sourcePath>
      </roots>
      <additional />
    </jdk>
"
    else
        log "WARN: no bundled JBR at ${jbr}; project JDK will be undefined"
    fi
    entries="${jdk_entry}"

    [ -n "${levels}" ] || {
        log "WARN: no Android platforms found for jdk.table.xml"
        [ -n "${jdk_entry}" ] || return 0
    }
    for lvl in ${levels}; do
        [ -d "${ANDROID_SDK_ROOT}/platforms/android-${lvl}" ] || continue
        entries="${entries}    <jdk version=\"2\">
      <name value=\"Android API ${lvl} Platform\" />
      <type value=\"Android SDK\" />
      <homePath value=\"${ANDROID_SDK_ROOT}\" />
      <roots>
        <annotationsPath>
          <root type=\"composite\">
            <root url=\"jar://${ANDROID_SDK_ROOT}/platforms/android-${lvl}/data/annotations.zip!/\" type=\"simple\" />
          </root>
        </annotationsPath>
        <classPath>
          <root type=\"composite\">
            <root url=\"jar://${ANDROID_SDK_ROOT}/platforms/android-${lvl}/android.jar!/\" type=\"simple\" />
            <root url=\"file://${ANDROID_SDK_ROOT}/platforms/android-${lvl}/data/res\" type=\"simple\" />
          </root>
        </classPath>
        <javadocPath>
          <root type=\"composite\" />
        </javadocPath>
        <sourcePath>
          <root type=\"composite\">
            <root url=\"file://${ANDROID_SDK_ROOT}/sources/android-${lvl}\" type=\"simple\" />
          </root>
        </sourcePath>
      </roots>
      <additional sdk=\"android-${lvl}\" />
    </jdk>
"
    done
    mkdir -p "$(dirname "${dst}")" 2>/dev/null || true
    printf '%s\n' "<application>" "  <component name=\"ProjectJdkTable\">" "${entries}  </component>" "</application>" \
        > "${dst}" 2>/dev/null \
        && log "generated ${dst} (levels:${levels})" \
        || log "WARN: failed to generate ${dst}"
}

seed_first_run_state() {
    local cfg="${XDG_CONFIG_HOME}/Google/${IDE_CONFIG_DIRNAME}"
    local opts="${cfg}/options"
    # Data-collection consent → opted out ("Don't Send").
    seed_if_absent "local-share/Google/consentOptions/accepted" \
        "${XDG_DATA_HOME}/Google/consentOptions/accepted"
    seed_if_absent "android/analytics.settings" "${HOME}/.android/analytics.settings"
    # Skip wizard + SDK path + IDE custom decorations. jdk.table.xml is generated
    # per installed API level (below), not seeded from a static template.
    seed_if_absent "ide-options/androidStudioFirstRun.xml" "${opts}/androidStudioFirstRun.xml"
    seed_if_absent "ide-options/android.sdk.path.xml"      "${opts}/android.sdk.path.xml"
    generate_jdk_table                                     "${opts}/jdk.table.xml"
    seed_if_absent "ide-options/ide.general.xml"           "${opts}/ide.general.xml"
    seed_if_absent "ide-options/project.default.xml"       "${opts}/project.default.xml"
    seed_if_absent "ide-options/other.xml"                 "${opts}/other.xml"
    # Boot the IDE on the JCEF-enabled JBR (Cuttlefish view needs JCEF). The
    # *.jdk file is a one-line path to the runtime dir; create if absent.
    if [ -d "${JCEF_JBR_DIR}" ] && [ ! -e "${cfg}/studio.jdk" ]; then
        mkdir -p "${cfg}" 2>/dev/null || true
        printf '%s\n' "${JCEF_JBR_DIR}" > "${cfg}/studio.jdk" 2>/dev/null \
            && log "seeded ${cfg}/studio.jdk → ${JCEF_JBR_DIR}" \
            || log "WARN: failed to seed studio.jdk"
    fi
}
seed_first_run_state

# --- Clear stale IDE locks --------------------------------------------------
# IntelliJ/ASfP take a DirectoryLock (a .lock unix socket) on the config + system
# dirs. On an unclean shutdown (workspace stop/kill — the pod just dies) the
# .lock files survive on the persistent PVC, and the next start fails with
# "Cannot lock config directory … FileAlreadyExistsException: …/.lock". Since
# only ONE IDE instance ever runs per workspace pod, any .lock present at
# container start is stale by definition — remove it before launching.
clear_stale_locks() {
    find "${XDG_CONFIG_HOME}/Google" "${XDG_CACHE_HOME}/Google" "${XDG_DATA_HOME}/Google" \
        -maxdepth 2 -name '.lock' -type f -delete 2>/dev/null || true
    log "cleared any stale IDE .lock files"
}
clear_stale_locks

# --- D-Bus ------------------------------------------------------------------
mkdir -p /tmp/dbus
# A CONTAINER RESTART INHERITS /tmp, so the socket from the previous — dead —
# session is still sitting there and dbus-daemon fails with
#   Failed to bind socket "/tmp/dbus/session-bus": Address already in use
# which exits the entrypoint, which restarts the container, which finds the same
# socket. One crash for any reason becomes a permanent CrashLoopBackOff, and the
# only clue is a bind error for a session nobody is running. Observed live.
#
# Safe because this runs before anything else in the session exists: a socket
# with no dbus-daemon behind it is by definition an orphan.
if [ -S /tmp/dbus/session-bus ] && ! pgrep -f 'dbus-daemon.*session-bus' >/dev/null 2>&1; then
    rm -f /tmp/dbus/session-bus /tmp/dbus/session-addr
    log "removed a stale D-Bus socket left by a previous session"
fi

# The xstartup single-instance lock is stale for exactly the same reason, and
# fails WORSE: its EXIT trap does not run when the container is SIGKILLed, so a
# surviving lock directory would park BOTH invocations and start no IDE at all.
# Cleared here, where the session is provably new, rather than trusted to a trap.
rmdir /tmp/che-as-session.lock 2>/dev/null \
    && log "removed a stale xstartup session lock" || true
DBUS_ADDR_FILE=/tmp/dbus/session-addr
dbus-daemon --session --print-address=3 --fork \
    --address="unix:path=/tmp/dbus/session-bus" 3>"${DBUS_ADDR_FILE}"
DBUS_SESSION_BUS_ADDRESS="$(cat "${DBUS_ADDR_FILE}")"
export DBUS_SESSION_BUS_ADDRESS
log "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}"

# --- xstartup ---------------------------------------------------------------
# KasmVNC runs ~/.vnc/xstartup once Xkasmvnc is up (-select-de manual keeps it
# ours). Brings up openbox, then auto-launches the IDE in a restart loop (the
# kiosk has no menu — a dead IDE would otherwise strand the user).
cat > "${HOME}/.vnc/xstartup" <<XSTARTUP
#!/usr/bin/env bash
export HOME="${HOME}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME}"
export XDG_DATA_HOME="${XDG_DATA_HOME}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT}"
export ANDROID_HOME="${ANDROID_SDK_ROOT}"
export STUDIO_VM_OPTIONS="${STUDIO_VM_OPTIONS}"

# SINGLE INSTANCE. KasmVNC runs this script TWICE — once from the server process
# and once from its child — so without a guard every session starts two window
# managers and two IDEs, which then race for IntelliJ's DirectoryLock. One wins;
# the loser reports "Process (NNN) is still running and does not respond" at the
# user. It usually resolves, which is exactly why it survived this long: it is a
# race, not a failure, until the day the winner is slow and neither can claim the
# lock.
#
# mkdir is the atomic primitive here — no flock dependency, and the loser is
# unambiguous. It must NOT exit: KasmVNC tears the X server down when xstartup
# returns, so the second invocation stays parked instead.
if ! mkdir "/tmp/che-as-session.lock" 2>/dev/null; then
    echo "[xstartup] another invocation already owns this session; parking"
    exec sleep infinity
fi
trap 'rmdir /tmp/che-as-session.lock 2>/dev/null || true' EXIT

# Window manager (backgrounded; long-lived).
openbox &

# Auto-launch the IDE via the NATIVE launcher (bin/studio), relaunching if it exits.
if [ -x "${STUDIO_BIN}" ]; then
    while true; do
        echo "[xstartup] starting ${STUDIO_BIN}"
        "${STUDIO_BIN}" || echo "[xstartup] IDE exited (\$?); relaunching in 2s"
        sleep 2
    done &
else
    echo "[xstartup] ERROR: ${STUDIO_BIN} not found/executable — IDE not injected?"
fi

# Keep the session alive so KasmVNC doesn't tear down the X server.
wait
XSTARTUP
chmod +x "${HOME}/.vnc/xstartup"
log "wrote ${HOME}/.vnc/xstartup (flavor=${IDE_FLAVOR}, launcher=${STUDIO_BIN})"

# --- KasmVNC write-access user ----------------------------------------------
# KasmVNC 1.x needs a write-access user to exist or it loops on an interactive
# prompt and never opens 6901. Pre-create one non-interactively (the password is
# irrelevant once basic auth is disabled).
KASM_PASSWD_FILE="${HOME}/.kasmpasswd"
if command -v kasmvncpasswd >/dev/null 2>&1; then
    printf '%s\n%s\n' "chestudio" "chestudio" \
        | kasmvncpasswd -u chestudio -wo "${KASM_PASSWD_FILE}" >/dev/null 2>&1 \
        && log "created KasmVNC write-access user 'chestudio'" \
        || log "WARN: kasmvncpasswd failed; KasmVNC may prompt for a user"
fi

# --- KasmVNC config: serve plain HTTP on loopback ---------------------------
# Che's gateway connects over http://127.0.0.1:6901 (TLS/auth at the edge), so
# KasmVNC must NOT require SSL. The unconditional cert-readability gate is
# satisfied by the world-readable throwaway pair under /etc/che-android-studio/pki.
cat > "${HOME}/.vnc/kasmvnc.yaml" <<KASMYAML
network:
  protocol: http
  ssl:
    require_ssl: false
    pem_certificate: /etc/che-android-studio/pki/snakeoil.pem
    pem_key: /etc/che-android-studio/pki/snakeoil.key
KASMYAML
log "wrote ${HOME}/.vnc/kasmvnc.yaml (require_ssl: false)"

# --- KasmVNC ----------------------------------------------------------------
# -DisableBasicAuth 1 is REQUIRED: -SecurityTypes None only covers the RFB layer;
# the websocket server otherwise 401s every request (incl. /healthz) → Che never
# goes healthy. kasmvncserver forwards unknown -Foo args to Xkasmvnc.
exec kasmvncserver "${DISPLAY_NUM}" \
    -interface 127.0.0.1 \
    -websocketPort 6901 \
    -SecurityTypes None \
    -DisableBasicAuth 1 \
    -select-de manual \
    -prompt no \
    -log "*:stderr:30" \
    -fg
