#!/usr/bin/env bash
# Install the che-android-studio streamed-desktop layer into a dev image.
#
# This is the shared TOP layer applied (as root, at build time) on top of a base
# that already has the Android SDK + JDK. It is reused by BOTH dev images
# (asfp-dev, studio-dev) so the desktop is identical and there's no copy-paste
# drift. Buildah has no native Dockerfile `include`, so reuse is via this COPY'd
# script rather than a shared fragment.
#
# Installs: GUI runtime libs + openbox (WM) + KasmVNC (web VNC), a throwaway TLS
# cert to satisfy KasmVNC's readability gate, the noVNC sub-path websocket fix,
# the /tmp/.X11-unix pre-create, and the arbitrary-UID passwd/group fix.
#
# Expects these to already be COPY'd into the image before it runs:
#   /usr/share/che-android-studio/kasmvnc-subpath-fix.html
#   /usr/local/bin/che-android-studio-inject-subpath   (the python injector)
#   /etc/xdg/openbox/rc.xml
#
# Usage (from a dev Containerfile): RUN /usr/local/bin/che-android-studio-setup-desktop

set -eux

KASMVNC_VERSION="${KASMVNC_VERSION:-1.4.0}"

export DEBIAN_FRONTEND=noninteractive
# Always take the package maintainer's version of any conffile non-interactively
# (openbox ships /etc/xdg/openbox/rc.xml; we overwrite it with our own AFTER this
# script in the Containerfile, so taking the maintainer default here is correct
# and, crucially, never prompts on stdin — an interactive conffile prompt with
# no TTY fails the build).
APT_CONF_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confnew'

# --- GUI runtime libs -------------------------------------------------------
# What ASfP/IntelliJ + openbox + KasmVNC need to render. NO Xvfb (KasmVNC ships
# its own X server). fonts-noto-cjk provides CJK glyph coverage.
#
# git/git-lfs: the IDE's VCS integration shells out to `git`, and a workspace
# whose entire purpose is editing a git checkout was shipping without one — the
# editor reported no executable found. git-lfs comes along because AOSP-adjacent
# repos use it and a half-working clone is worse than an obvious failure.
# THE AOSP BUILD TOOLCHAIN, because ASfP BUILDS IN THIS CONTAINER.
#
# The Containerfile above notes that "a heavier variant carrying a full Android
# platform (AOSP) build toolchain can be layered on top of this base as a future
# addition" — but ASfP does not shell out to some other container. A project
# open runs `m` right here, so anything the build needs and this image lacks
# fails a batch mid-sync, in the editor, at the point a developer is watching.
#
# Found the slow way: a build batch died on "/bin/sh: 1: rsync: not found" while
# the same build succeeded in the pipeline, whose aaos-tools image has it. An
# audit of the container then turned up FOURTEEN missing, `make`, `bison`, `flex`
# and `zip` among them — so this is the documented AOSP host set rather than the
# one tool that happened to fail first.
#
# KEPT IN STEP WITH belt's examples/toolchains/aaos/Containerfile, which is the
# authoritative AOSP host set. The two lists live in different repositories and
# had drifted in BOTH directions — this image was missing eleven the build image
# has, and carried eight the build image does not. The eleven are added below;
# the eight stay, because ASfP execs them here and the build image not needing
# them is not evidence this one does not.
#
# `python-is-python3` is the quiet one: Soong wraps python3 as `python`, so
# anything exec'ing bare `python` fails with no hint that a package is missing.
# The 32-bit and X11 dev packages are the documented host set from
# source.android.com "Establish a build environment" — host prebuilts link
# against them.
#
# Belt's session preflight (aaosToolPreflight, internal/cli/aaossession.go)
# names anything still missing at open, so the next drift arrives as one list
# rather than as a build batch dying an hour in.
AOSP_BUILD_TOOLS="rsync zip bc bison flex build-essential m4 gperf ccache xxd \
                  lz4 zstd patch file libssl-dev zlib1g-dev libxml2-utils xsltproc \
                  wget gnupg procps python-is-python3 fontconfig \
                  libc6-dev-i386 lib32z1-dev lib32ncurses-dev \
                  x11proto-core-dev libx11-dev libgl1-mesa-dev"

apt-get update
apt-get install -y --no-install-recommends ${APT_CONF_OPTS} \
    openbox \
    dbus-x11 \
    x11-xserver-utils x11-utils \
    libgl1 libgl1-mesa-dri \
    libxtst6 libxrender1 libxi6 libxss1 libxcomposite1 \
    libxrandr2 libxdamage1 libxfixes3 libxkbfile1 \
    libgtk-3-0 libnss3 libcups2 libasound2 libpango-1.0-0 \
    fonts-dejavu-core fonts-noto-cjk fonts-noto-color-emoji \
    ca-certificates curl unzip python3 openssl \
    desktop-file-utils \
    git git-lfs \
    ${AOSP_BUILD_TOOLS}

# --- KasmVNC (apt; non-relocatable, hence baked into the dev image) ---------
deb=/tmp/kasmvncserver.deb
curl -fsSL -o "${deb}" \
    "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_jammy_${KASMVNC_VERSION}_amd64.deb"
apt-get install -y --no-install-recommends ${APT_CONF_OPTS} "${deb}"
rm -f "${deb}"

# --- AOSP host compatibility, mirroring belt's examples/toolchains/aaos ------
#
# ncurses .so.5 compat. Ubuntu 22.04 ships only the .so.6 runtimes and a few
# AOSP host prebuilts still link libncurses.so.5 / libtinfo.so.5. Symlink the .6
# runtimes to the .5 names so those tools load; harmless when unused. Absent
# here, they fail with a loader error that names a library nobody installed.
for lib in libncurses libncursesw libtinfo; do
    so6="$(find /usr/lib /lib -name "${lib}.so.6" 2>/dev/null | head -n1)"
    if [ -n "${so6}" ] && [ ! -e "$(dirname "${so6}")/${lib}.so.5" ]; then
        ln -s "$(basename "${so6}")" "$(dirname "${so6}")/${lib}.so.5"
    fi
done

# The Google git-repo tool. A development checkout is what an AAOS session
# exists to produce, and `repo start` / `repo status` are how a developer moves
# around ~1000 projects; without it the session opens on a tree it cannot
# navigate. Same pin as belt's toolchain, and it FAILS CLOSED if the tag does
# not resolve to the pinned commit.
REPO_TOOL_REF="${REPO_TOOL_REF:-v2.65}"
REPO_TOOL_COMMIT="${REPO_TOOL_COMMIT:-35bbf701d04de5c6a71937279bc3d16f6ce36808}"
git clone --quiet --branch "${REPO_TOOL_REF}" \
    https://gerrit.googlesource.com/git-repo /opt/git-repo
head="$(git -C /opt/git-repo rev-parse HEAD)"
if [ "${head}" != "${REPO_TOOL_COMMIT}" ]; then
    echo "git-repo ${REPO_TOOL_REF} HEAD ${head} != pinned ${REPO_TOOL_COMMIT}" >&2
    exit 1
fi
install -m 0755 /opt/git-repo/repo /usr/local/bin/repo

# safe.directory '*' so git trusts the fsGroup-mounted, differently-owned sealed
# checkout (Soong shells out to git for version stamping); LFS filters
# registered system-wide for prebuilt-carrying trees.
git config --system safe.directory '*'
git lfs install --system --skip-repo

apt-get clean
rm -rf /var/lib/apt/lists/*

# --- X11 socket dir ---------------------------------------------------------
# The X server creates its socket under /tmp/.X11-unix. Under the restricted SCC
# the arbitrary UID can't mkdir it at runtime — pre-create it sticky/world-writable.
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# --- Throwaway TLS cert (satisfies KasmVNC's unconditional cert gate) --------
# kasmvncserver always checks its configured cert+key exist and are READABLE,
# even with require_ssl: false. The Debian snakeoil key lives under
# /etc/ssl/private (0710), untraversable by the arbitrary UID. Generate our own
# under a 0755 dir; the cert is NEVER used for TLS (the wire is plain HTTP).
mkdir -p /etc/che-android-studio/pki
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=localhost" \
    -keyout /etc/che-android-studio/pki/snakeoil.key \
    -out /etc/che-android-studio/pki/snakeoil.pem
chmod 0755 /etc/che-android-studio /etc/che-android-studio/pki
chmod 0644 /etc/che-android-studio/pki/snakeoil.key /etc/che-android-studio/pki/snakeoil.pem
test -r /etc/che-android-studio/pki/snakeoil.pem
test -r /etc/che-android-studio/pki/snakeoil.key

# --- noVNC sub-path websocket fix -------------------------------------------
# Inject the path-from-location script into KasmVNC's index.html/vnc.html so the
# websocket targets Che's per-workspace sub-path instead of the host root.
python3 /usr/local/bin/che-android-studio-inject-subpath
grep -q 'che-android-studio: sub-path websocket fix' /usr/share/kasmvnc/www/index.html

# --- Arbitrary-UID passwd/group fix -----------------------------------------
# Under OpenShift's restricted SCC the container runs as an arbitrary UID in
# group 0 with no /etc/passwd entry → `groups: cannot find name for group ID
# 1000` in the terminal. Make the DBs group-writable so the entrypoint can
# append an entry at runtime as the (group-0) arbitrary UID.
chmod g=u /etc/passwd /etc/group

# ...and BAKE the uid-1000 entry, because group-0 writability does not help the
# deployment we actually run on. Che on vanilla Kubernetes starts this container
# as uid=1000 GID=1000 — not group 0 — so the entrypoint's append fails with
# `/etc/passwd: Permission denied` and every getpwuid() caller is left without a
# user. Observed live, in three places at once:
#
#   * the terminal prompt reads `I have no name!@…`, which is bash printing \u
#     when getpwuid(1000) fails;
#   * Soong logs `Failed to get current user: user: unknown userid 1000` and
#     then `Build sandboxing disabled due to nsjail error` — AOSP's nsjail
#     genrules need that sandbox;
#   * and Soong resolves BUILD_USERNAME to "unknown", which lands in the
#     environment it hashes, so a warm out/ tree is re-analysed from scratch by
#     an editor that merely opened it.
#
# Baking the entry fixes all three before anything runs, and costs nothing on
# OpenShift: an arbitrary UID is not 1000, getent misses, and the runtime append
# path above still applies.
if ! getent passwd 1000 >/dev/null 2>&1; then
    echo 'developer:x:1000:1000:che-android-studio:/tmp/che-home:/bin/bash' >> /etc/passwd
fi
if ! getent group 1000 >/dev/null 2>&1; then
    echo 'developer:x:1000:' >> /etc/group
fi

echo "[setup-desktop] che-android-studio desktop layer installed"
