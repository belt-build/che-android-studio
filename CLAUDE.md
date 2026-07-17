# CLAUDE.md — che-android-studio

Operational notes and hard-won quirks. Skim this before making non-trivial
changes — most of these are subtle failures that cost real debugging time.

## What this repo is

Android Studio / Android Studio for Platform (ASfP) + KasmVNC delivered as a
selectable **Eclipse Che editor** (works on upstream Che and OpenShift Dev
Spaces). Streamed desktop, browser-only, SDK pre-baked.

### Image architecture (FOUR images: 1 toolchain base + 2 injectors)

The real Che container-contribution model (like che-code): the editor CONTRIBUTES
the IDE + streaming onto the workspace's TOOLCHAIN container — it does not ship its
own. The user owns the toolchain; the editor is thin and swappable.

- **`sdk`** (`container/sdk/Containerfile`) — the GUI-capable, flavor-NEUTRAL
  **toolchain base**: Ubuntu + Android SDK (configurable API levels, no emulator)
  + JDK + JCEF JBR + the GUI/streaming RUNTIME LIBS (X libs, mesa/DRI, fonts,
  openbox, dbus, perl + the KasmVNC .deb's Perl-module deps) + `/tmp/.X11-unix`
  1777 + arbitrary-UID passwd fix. It plays THREE roles: (1) the workspace dev
  container the contribution merges into; (2) the contribution's placeholder image
  (so a workspace with no dev container runs the desktop standalone); (3) the base
  users EXTEND (`FROM …/sdk`) to add their own SDK levels + tools. Also usable
  directly, headless, for Android CI.
- **Injector images** (`container/editor/Containerfile`, param by `IDE_FLAVOR`):
  `asfp-editor` and `studio-editor` — carry the PORTABLE payload staged into the
  shared volume at start: the relocatable IDE `/opt` tree, the **relocated KasmVNC**
  (unpacked from its `.deb` — there is no portable tarball; see below), the
  throwaway cert, openbox config, entrypoint + skel.

Why no `*-dev` images anymore: KasmVNC + the IDE are now PORTABLE (staged on the
volume), so there is nothing flavor-specific left to bake into a runtime image —
the contribution merges onto whatever toolchain container the workspace has. The
NON-relocatable pieces (GUI/streaming runtime libs) live in `sdk`.

**The portable/apt split (load-bearing):** anything resolved by
`ld.so`/fontconfig/xkb path lookup or exec'd by bare name → `sdk` image (apt).
Anything self-contained + prefix-relocatable → shared volume (from the injector).
Keep the `sdk` GUI/streaming apt set in sync with the KasmVNC `.deb`'s `Depends:`
(pinned by `KASMVNC_VERSION` in `container/editor/Containerfile`).

Images publish to `ghcr.io/<owner>/che-android-studio/<image>`.

Two editor definitions → two dashboard entries: `che-android-studio/asfp/latest`
and `che-android-studio/android-studio/latest`
(`deploy/asfp-editor-definition.yaml`, `deploy/studio-editor-definition.yaml`).

**BYO toolchain contract:** because the contribution merge keeps the USER's dev
container image (the editor's is a placeholder), a user-supplied dev container must
be GUI-capable — build it `FROM ghcr.io/<owner>/che-android-studio/sdk` (or replicate
its GUI/streaming apt set + the SDK/JBR at their `/opt` paths). A non-GUI dev
container will start but the desktop won't render.

## Configurable Android API levels

The SDK image installs whatever `ANDROID_API_LEVELS` lists (default `"34 36"`),
with matching `ANDROID_BUILD_TOOLS`. Override at build:
`make sdk-image ANDROID_API_LEVELS="33 34 35 36"`. The level set is recorded as
an image ENV; the entrypoint reads it (or enumerates
`$ANDROID_SDK_ROOT/platforms/android-*`) and **generates `jdk.table.xml` at
runtime** — one "Android API <L> Platform" entry per installed level. Do NOT
re-add a static `skel/ide-options/jdk.table.xml`; a single hardcoded level can't
represent a multi-level SDK.

## Hard-won quirks (operational)

### KasmVNC owns the X server — do NOT run Xvfb

`kasmvncserver` is a TigerVNC-derived wrapper that STARTS its own X server
(`Xkasmvnc`). It is NOT a client that attaches to an external X server. Running
`Xvfb :0` first then `kasmvncserver :0` makes KasmVNC abort with **"A VNC server
is already running as :0"** → CrashLoopBackOff. The entrypoint runs NO Xvfb;
KasmVNC creates the display itself.

The session is driven by `~/.vnc/xstartup`, KasmVNC's standard hook.
`-select-de manual` keeps our xstartup intact: `kasmvncserver` calls
`select-de.sh`, and any other value OVERWRITES `~/.vnc/xstartup` with a stock DE
launcher.

KasmVNC 1.x needs a WRITE-ACCESS USER to exist before it serves, even with
`-SecurityTypes None`. With no such user and no TTY it loops forever on an
interactive "Create a new user" prompt (reading empty stdin). Symptom: container
stays Running but never opens 6901, so Che sits at "Waiting for editor to start".
The entrypoint pre-creates a throwaway write-access user non-interactively
(`kasmvncpasswd -u chestudio -wo ~/.kasmpasswd`); the password is never checked
once basic auth is disabled. `-prompt no` is also passed.

`-DisableBasicAuth 1` is REQUIRED — `-SecurityTypes None` is NOT enough.
`-SecurityTypes None` only disables the RFB (VNC-protocol) security layer;
KasmVNC's HTTP/websocket server still enforces BASIC AUTH on every request,
returning **401 on EVERYTHING including `/healthz`**. That breaks Che two ways:
the gateway's editor health probe gets 401 (→ "no IDE URL", workspace never
opens) and the user sees a login prompt inside the iframe. Che's gateway is the
sole authenticator (JWT/cookie at the edge), so all KasmVNC-side auth must be
off. `DisableBasicAuth` has no kasmvncserver config-key mapping, so it's passed
as a raw Xvnc arg (kasmvncserver forwards unknown `-Foo` args straight through).
Verified: `curl localhost:6901/` went 401 → 200 with the flag.

`/tmp/.X11-unix` is pre-created `1777` in the image: under OpenShift's restricted
SCC the container is a non-root arbitrary UID and can't mkdir it at runtime — the
X server logs "euid != 0, directory will not be created" and fails otherwise.

### KasmVNC serves PLAIN HTTP on 6901, NOT HTTPS

Che's gateway (Traefik) connects to the editor endpoint over
`http://127.0.0.1:6901` — it does TLS + JWT/cookie auth at the EDGE, then talks
plain HTTP to the backend on loopback. (`protocol: https` + `secure: true` in the
editor definition control the browser-facing endpoint + edge auth, NOT the
backend scheme — the bundled che-code / che-idea-server editors also declare
`protocol: https` yet their backends serve plain HTTP. Keep ours matching them;
do NOT flip it to http.) KasmVNC defaults to `require_ssl: true`, which would
HTTPS-handshake against the gateway's HTTP request → editor never goes healthy.
The entrypoint writes `~/.vnc/kasmvnc.yaml` with `network.ssl.require_ssl: false`
(config file, NOT a flag — `-sslOnly` isn't in kasmvncserver's CLI parse list).

SEPARATELY: kasmvncserver ALWAYS checks its configured cert+key exist and are
READABLE and `exit 1`s otherwise — even with `require_ssl: false` (the
`RequireSslCertsToBeReadable` check is unconditional). The Debian snakeoil pair
can't satisfy this for an arbitrary UID: `/etc/ssl/private` is `0710
root:ssl-cert`, so the restricted-SCC UID can't even TRAVERSE into the dir to
stat the key → "cert file doesn't exist or isn't a file" → crash. (Inspecting the
image as root hides this — root ignores dir perms.) Fix: the `*-editor` image
generates a throwaway self-signed pair under `/opt/che-android-studio/pki`, the
injector stages it into the shared volume (`/che-android-studio/pki`), and the
entrypoint's `~/.vnc/kasmvnc.yaml` points at it. Shipping the cert on the VOLUME
(not the base image) keeps the gate independent of the user's toolchain container.
The cert is never used for TLS (wire is HTTP) — it only passes the gate.

Also SEPARATELY (relocated-KasmVNC quirk): the `kasmvncserver` Perl launcher reads
a hardcoded defaults + system config (`/usr/share/kasmvnc/kasmvnc_defaults.yaml`,
`/etc/kasmvnc/kasmvnc.yaml`) and `die`s if either is unreadable — and in the
relocated/merged toolchain container NEITHER exists. `-config a,b` REPLACES that
list, so the entrypoint passes the STAGED defaults + our `~/.vnc/kasmvnc.yaml`
(last wins). The user yaml also sets `server.http.httpd_directory` to the staged
`www` (the default points at the non-existent `/usr/share/kasmvnc/www`), and the
entrypoint sets `PATH`/`PERL5LIB` to the staged prefix so the launcher finds
`Xkasmvnc` (relative to `$0`) and its `KasmVNC::*` modules.

### KasmVNC websocket must use the Che sub-path (the `/websockify` 418)

KasmVNC's noVNC client builds its websocket URL from the host ROOT plus the
`path` setting — `wss://<host>/websockify`. But Che serves the editor at a
per-workspace sub-path and its gateway only routes the websocket under that
`PathPrefix`. So the root path fails ("can't establish a connection to
wss://host/websockify"), and the gateway returns 418 (its unmatched-route
teapot). `urlRewriteSupported: true` does NOT fix this — the client computes the
URL itself, client-side, from `location.host`.

noVNC reads `path` from `?path=`/`#path=` before connecting. So
`container/kasmvnc-subpath-fix.html` is an inline script injected into
`index.html` + `vnc.html` BEFORE the module bundle; it sets `path` from
`location.pathname` (e.g. `/<ws-subpath>/6901/` → `<ws-subpath>/6901/websockify`)
via `history.replaceState`. Workspace-agnostic — no hardcoded ID. If KasmVNC is
upgraded, re-confirm the injection marker still lands before the module
`<script>` (the injector greps for it and fails the build otherwise).

### Arbitrary-UID passwd/group entry (the `groups: cannot find name` fix)

Under OpenShift's restricted SCC the workspace runs as an arbitrary UID in group
0 with NO `/etc/passwd`/`/etc/group` entry, so a terminal shows `groups: cannot
find name for group ID 1000` and `getpwuid()`-based tools misbehave. The fix is
the OpenShift-standard pattern: `/etc/passwd` is made group-writable (mode 0664)
at build time (`container/sdk/Containerfile` runs `chmod g=u /etc/passwd
/etc/group`), and `entrypoint.sh`'s `ensure_passwd_entry` appends
`developer:x:<uid>:<gid>:...:<HOME>:/bin/bash` at runtime if `getent passwd
<uid>` is empty.

### Auto-launches the IDE (kiosk model)

The streamed desktop is a single-app kiosk. `entrypoint.sh`: forces
`HOME`+`XDG_*` to a writable persistent home (prefers `/home/user`, Che's
`persistUserHome` mount) → waits for it to be writable → starts dbus → writes
`~/.vnc/xstartup` → `exec`s `kasmvncserver`. The xstartup launches openbox and
then the IDE (`bin/studio`) in a restart loop. openbox ships a system-wide
`rc.xml` (`container/openbox/rc.xml`) whose rule maximizes the IDE window and
removes WM decorations (the IDE draws its own header via
`-Dide.win.frame.decorations=true`). There is NO panel/menu/launcher — the IDE
*is* the desktop. `HOME` must be forced: under the restricted SCC the arbitrary
UID has no passwd entry, so `HOME` defaults to `/` (unwritable) and openbox/the
IDE fail to write config.

Why KasmVNC stays PID 1 (not the IDE): the stream is the service that must stay
reachable; if it dies the pod should restart. The IDE runs under the xstartup
restart loop, so an IDE crash relaunches it rather than stranding the user.

The launcher is the NATIVE `bin/studio` ELF, NOT `bin/studio.sh` — ASfP flags the
shell wrapper as unsupported. Both read the same vmoptions; extra options (window
chrome) come via the `STUDIO_VM_OPTIONS` env var, not by editing the vendored
`studio64.vmoptions`.

The ASfP `.deb`'s postinst needs `desktop-file-utils` and a `sudo` binary on PATH
(it runs `sudo sed`), both installed in the editor Containerfile.

### mmap VFS must live OFF an idmapped RWO PVC

IntelliJ's VFS stores file-records + attributes in memory-mapped append-logs.
When `idea.system.path` lives on an idmapped RWO PVC, mmap `MAP_SHARED` writeback
is not coherent there: the VFS silently accumulates errors mid-session
(`java.nio.BufferUnderflowException` in `AttributesStorageOverBlobStorage`) and
then can't append new records → "Cannot create child file …" + "Multiple internal
errors in the file system cache". Quota/space is NOT the cause. Fix: the
entrypoint puts `idea.system.path` (VFS, indexes, caches) + `idea.log.path` on
`/tmp` (the container overlay — local, not idmapped). These are rebuildable;
losing them on restart only re-indexes. `idea.config.path` + `idea.plugins.path`
STAY on `$HOME` so settings/plugins persist (small, not mmap'd).

### Clear stale IDE locks

IntelliJ takes a DirectoryLock (`.lock` unix socket) on the config + system dirs.
On an unclean shutdown (pod killed), the `.lock` on the persistent PVC survives
and the next start fails with "Cannot lock config directory …
FileAlreadyExistsException: …/.lock". Since only ONE IDE ever runs per pod, any
`.lock` at start is stale by definition — the entrypoint removes it before
launching.

### First-run state seeded at runtime; SDK baked in the image

`$HOME` is the per-user PVC mount; it is EMPTY on first start and MASKS anything
baked into the image under that path. So:

- **Anything large/shared/identical-per-user goes in the IMAGE outside `$HOME`.**
  The Android SDK is pre-baked at **`/opt/android-sdk`** (configurable API
  levels, no emulator) and made world-readable for the arbitrary SCC UID.
  `ANDROID_SDK_ROOT`/`ANDROID_HOME` are image ENV. This kills the first-run setup
  wizard + the multi-hundred-MB SDK download. A custom-built platform can be
  injected via the `TODO(custom-android-sdk)` hook + the `CUSTOM_ANDROID_SDK_DIR`
  runtime drop-in.
- **Per-user first-run STATE is seeded into the PVC at runtime** by the
  entrypoint's `seed_first_run_state()` — `cp` from templates the injector staged
  into the shared volume at `/che-android-studio/skel/` (the entrypoint resolves
  `SKEL_DIR` under `ASSET_BASE`, falling back to the in-image
  `/opt/che-android-studio/skel/` for a local/monolith run) into `$HOME`, ONLY if
  the target is absent (never clobber a user's later choices). Seeded: consent (opted
  OUT), analytics opt-out, skip-wizard, SDK path (→ `/opt/android-sdk`, absolute),
  and IDE custom window decorations. `jdk.table.xml` is GENERATED (not seeded) per
  installed API level. The config dir name embeds the IDE version; the entrypoint
  derives it from `product-info.json`'s `dataDirectoryName` (falling back to
  `ASFP_MAJOR_MINOR`).

The JCEF-enabled JBR (Cuttlefish view needs JCEF; the bundled IDE JBR lacks it)
is baked at `/opt/che-android-studio/jbr-jcef` and pointed at via a seeded
`studio.jdk`. `JAVA_HOME` is aligned to the IDE's bundled JBR at runtime so Gradle
and the IDE share one JDK (otherwise the IDE warns about + spawns a second Gradle
daemon).

### Devfile endpoints can only be `http/https/ws/wss`

Che's gateway only documents these protocols. KasmVNC was chosen because it
speaks HTTPS+WebSocket; raw VNC TCP would not traverse the gateway. Selkies wants
UDP/WebRTC and would need its own Service+Ingress + TURN/STUN — see STREAMING.md.

### Remote desktop: bare window chrome, no forced scaling/resolution

- `openbox/rc.xml` sets `<decor>no</decor>` on the IDE window (single-app kiosk);
  the IDE draws its own header via `-Dide.win.frame.decorations=true` (passed via
  `STUDIO_VM_OPTIONS`). Dialogs keep decorations so they stay movable/closable.
- **NO forced UI scaling / font size** — an earlier version forced
  `-Dsun.java2d.uiScale`; it rendered poorly over the stream (chrome scaled, editor
  font didn't). Users set their own.
- **NO forced native resolution** — noVNC persists `resize` in localStorage so a
  forced URL default was unreliable. Users pick the mode from the noVNC control bar.

## Deferred / possible follow-ups

1. **Selkies (WebRTC) streaming** — GPU H.264 + audio; needs its own
   Service/Ingress (Che's gateway can't proxy UDP) + TURN/STUN + GStreamer + an
   NVIDIA device plugin.
2. **Android emulator** — per-pod `/dev/kvm` via a KVM device plugin + a
   permissive SCC.
3. **Heavy platform-build toolchain** — this is now just the BYO-toolchain path:
   a user builds `FROM sdk` adding a full AOSP build toolchain (build-essential,
   `repo`, JDKs) and points their workspace's dev container at it; the editor
   contributes the IDE + streaming onto it. Kept out of the lean default.
4. **Pre-warmed IDE cache template PVC** — clone-on-create so first launch is
   instant (indexes already built). Needs a CSI that supports volume cloning.
5. **Restore `.deb` checksum gates** — KasmVNC + ASfP `.deb` downloads currently
   install without `sha256sum -c` verification (dev-time shortcut). Re-add
   `ARG *_DEB_SHA256` + a verify step, plumbed from CI, before treating this as
   production — a floating release download can silently change behavior across
   rebuilds.
