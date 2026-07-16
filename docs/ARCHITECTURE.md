# Architecture

che-android-studio delivers Android Studio / Android Studio for Platform (ASfP)
as Eclipse Che `DevWorkspace` pods, with the desktop streamed to the browser via
KasmVNC.

## Components

```
┌────────────────────────────────────────────────────────────────────┐
│                     Developer's browser                             │
└────────────────────────┬───────────────────────────────────────────┘
                         │ HTTPS (TLS at gateway)
                         │ JWT cookie scoped to the workspace
                         ▼
┌────────────────────────────────────────────────────────────────────┐
│ Eclipse Che gateway (Traefik)                                       │
│  /dashboard/                          → che-dashboard pod           │
│  /<workspace-subpath>/6901/           → DevWorkspace pod, port 6901 │
└────────────────────────┬───────────────────────────────────────────┘
                         │ HTTP+WS (plain, on loopback — TLS terminates at edge)
                         ▼
┌────────────────────────────────────────────────────────────────────┐
│ DevWorkspace pod (per user)                                         │
│  Runtime container (asfp-dev / studio-dev):                        │
│   - KasmVNC server (own X server Xkasmvnc :1, loopback HTTP+WS 6901)│
│   - openbox  (minimal stacking WM, via ~/.vnc/xstartup)            │
│   - Android Studio / ASfP auto-launched, maximized                 │
│   - Android SDK + JCEF JBR baked in the image (/opt/android-sdk)   │
│  Injector container (asfp-editor / studio-editor):                 │
│   - stages the relocatable IDE tree into the shared volume         │
└────────────────────────┬───────────────────────────────────────────┘
                         │
                         ▼
                ┌──────────────────┐
                │ /home/user       │  Per-user PVC (Che-provisioned):
                │ (per-user PVC)   │  IDE caches/config, persists across restarts
                └──────────────────┘
```

## The injector + container-contribution shape

This mirrors Che's bundled desktop editors:

- The **injector** component (from `asfp-editor` / `studio-editor`) runs at
  `preStart` and `cp -a`'s the relocatable IDE `/opt` tree plus the entrypoint +
  first-run seed assets into a shared `volume: {}` mounted at
  `/che-android-studio`.
- The **runtime** component (from `asfp-dev` / `studio-dev`, marked
  `controller.devfile.io/container-contribution: true`) provides KasmVNC,
  openbox, the GUI libs, the Android SDK, and the JCEF JBR. Its `postStart`
  command execs the injected entrypoint.

So the heavy, non-relocatable pieces (KasmVNC, apt packages, the SDK) live in the
dev image, while the swappable IDE payload lives in the tiny injector image.

## Lifecycle

1. **Register the editors** (once per Che install): `hack/register-editors.sh`
   wraps each editor definition in a labeled ConfigMap; the dashboard serves them
   at `/dashboard/api/editors`.
2. **Workspace start** (per developer): the developer picks the editor (or a repo
   selects it via `.che/che-editor.yaml`). Che materializes the pod, the injector
   stages the IDE, and the runtime's entrypoint forces `HOME`/`XDG` to the PVC,
   seeds first-run state, starts dbus, writes `~/.vnc/xstartup`, and execs KasmVNC
   (which starts its own X server and runs xstartup → openbox + auto-launched,
   maximized IDE).
3. **Use**: the developer clicks the desktop endpoint and lands in the KasmVNC
   HTML5 client with the IDE already running.
4. **Stop**: the pod is removed; the per-user PVC persists, so IDE caches survive
   a restart.

## Why these choices

See:
- `STREAMING.md` for the KasmVNC vs Selkies tradeoffs.
- `STORAGE.md` for the per-user cache PVC + large-source-tree considerations.
- `DEVFILE.md` for how to author and apply devfiles / select the editor.
- `CLAUDE.md` for the operational gotchas list.

## Out of scope

- Android emulator (needs `/dev/kvm`).
- WebRTC / Selkies / GPU-accelerated streaming.
- A bundled multi-node shared source-tree filesystem (bring your own storage
  class; see `STORAGE.md`).
