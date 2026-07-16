# che-android-studio

Run **Android Studio** and **Android Studio for Platform (ASfP)** as a streamed
desktop inside **Eclipse Che** / OpenShift Dev Spaces. Open a browser, pick the
editor, and a workspace pod boots with the IDE already running — no local
install, no per-developer Android SDK download.

[![ci](https://github.com/kirkbrauer/che-android-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/kirkbrauer/che-android-studio/actions/workflows/ci.yml)
&nbsp;Apache-2.0

## What it is

A self-contained **Che editor definition** (two, actually — ASfP and regular
Android Studio) that anyone can register in their own Che install. The desktop
is streamed with **KasmVNC** over HTTPS+WebSocket, which is exactly what Che's
gateway proxies, so it traverses any Che at a per-workspace sub-path with no
extra Service/Ingress.

```
browser ─▶ Che gateway (HTTPS/WS) ─▶ workspace pod ─▶ KasmVNC (own X server) ─▶ openbox + Android Studio / ASfP
```

The Android SDK (API 34 + 36 by default, configurable) and a JCEF-enabled
JetBrains Runtime are pre-baked into the image, and the first-run wizard /
analytics prompts are pre-answered — so the IDE opens straight into a usable
state.

## Image architecture (five images, injector + container-contribution)

Modeled on Che's desktop editors: an **injector** stages the relocatable IDE
into a shared volume, and a `controller.devfile.io/container-contribution`
**runtime** runs it — so the GUI + toolchain are co-located.

| Image | Role |
|---|---|
| `sdk` | Headless base: Ubuntu + Android SDK (configurable API levels, no emulator) + JDK + JCEF JBR. Reusable directly for headless Android CI builds. |
| `asfp-dev` / `studio-dev` | The contribution runtimes (`FROM sdk` + the desktop layer: KasmVNC + openbox + GUI libs). The GUI is contributed into these; the user's terminal lives here. |
| `asfp-editor` / `studio-editor` | The IDE injectors (`FROM ubuntu`, carry only the relocatable IDE `/opt` tree + entrypoint/seed assets), staged into the shared volume at workspace start. |

Published to `ghcr.io/kirkbrauer/che-android-studio/<image>`.

## Quick start

### 1. (Optional) build the images yourself

CI builds and publishes all five to GHCR on every push to `main`. To build
locally:

```bash
make images                                   # sdk → dev → editor, in order
make sdk-image ANDROID_API_LEVELS="33 34 35 36"   # custom API levels
```

### 2. Register the editors in your Che

```bash
./hack/register-editors.sh            # auto-detects the Che namespace
# or: ./hack/register-editors.sh -n eclipse-che
# or: kubectl apply -k deploy/        # (set the namespace in deploy/kustomization.yaml)
```

This wraps each editor definition in a labeled ConfigMap the dashboard reads.
"Android Studio for Platform" and "Android Studio" then appear in the editor
dropdown on the **Create Workspace** page.

### 3. Open a workspace

Select the editor when creating a workspace, or point a repo at it:

- `.che/che-editor.yaml` → `id: che-android-studio/asfp/latest`
- dashboard query `?che-editor=che-android-studio/asfp/latest`
- (cluster default) set `spec.devEnvironments.defaultEditor` on the CheCluster CR

Editor ids: `che-android-studio/asfp/latest`,
`che-android-studio/android-studio/latest`.

When the pod is Ready, click the desktop endpoint — the KasmVNC HTML5 client
opens with the IDE running.

## Layout

```
che-android-studio/
├── container/               Containerfiles + entrypoint.sh + desktop/seed assets
├── deploy/                  Editor definitions + getting-started samples (+ kustomization)
├── examples/                Example workspace devfile + optional Argo CD wiring
├── hack/                    register-editors.sh
├── docs/                    ARCHITECTURE / STREAMING / STORAGE / DEVFILE
├── .github/workflows/ci.yml Test → build → smoke, pushing images to GHCR
├── Makefile                 podman/docker build wrapper
└── CLAUDE.md                Operational gotchas (hard-won)
```

## Requirements

- An Eclipse Che (upstream) or OpenShift Dev Spaces install you can register an
  editor in.
- For AOSP indexing, a raised `fs.inotify.max_user_watches` on the nodes (large
  source trees exhaust the default). This is a node-level kernel setting — see
  `docs/STORAGE.md`.

## Not included (possible follow-ups)

- **WebRTC streaming** (Selkies) for GPU-accelerated H.264 + audio — needs its
  own Service/Ingress + TURN/STUN; see `docs/STREAMING.md`.
- **Android emulator** — needs `/dev/kvm` via a device plugin + a permissive SCC.
- **Heavy platform-build variant** — a dev image carrying a full AOSP build
  toolchain, layered on top of `sdk`.

## License

[Apache-2.0](LICENSE).

## Related

- [Android Studio for Platform docs](https://developer.android.com/studio/platform)
- [Eclipse Che](https://eclipse.dev/che/) · [KasmVNC](https://github.com/kasmtech/KasmVNC)
