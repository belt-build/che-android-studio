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
│  Injector init container (asfp-editor / studio-editor):            │
│   - stages the relocatable IDE tree + relocated KasmVNC + assets    │
│     into the shared volume, then exits                              │
│  Toolchain container (the `sdk` base, or the user's own dev image): │
│   - the editor's container-contribution MERGES its endpoint/env in  │
│   - runs the STAGED entrypoint → staged KasmVNC (own X server        │
│     Xkasmvnc :1, loopback HTTP+WS 6901) → openbox → IDE, maximized   │
│   - provides the GUI/streaming RUNTIME LIBS + Android SDK + JCEF JBR │
└────────────────────────┬───────────────────────────────────────────┘
                         │
                         ▼
                ┌──────────────────┐
                │ /home/user       │  Per-user PVC (Che-provisioned):
                │ (per-user PVC)   │  IDE caches/config, persists across restarts
                └──────────────────┘
```

## The injector + container-contribution shape

This is the real Che container-contribution model (like che-code):

- The **injector** component (from `asfp-editor` / `studio-editor`) runs at
  `preStart` and `cp`'s the relocatable IDE `/opt` tree, the **relocated KasmVNC**
  (unpacked from its `.deb` — there is no portable tarball), a throwaway cert,
  openbox config, and the entrypoint + first-run seed assets into a shared
  `volume: {}` mounted at `/che-android-studio`.
- The **runtime** component, marked
  `controller.devfile.io/container-contribution: true`, is MERGED by the
  DevWorkspace controller into the workspace's toolchain (dev) container — the
  user's image wins (the editor's is a placeholder, the published `sdk` base). Its
  `postStart` command execs the staged entrypoint, which puts the staged KasmVNC on
  `PATH`/`PERL5LIB` and launches it.

So the split is by RELOCATABILITY, not by "IDE vs tools": the self-contained,
swappable pieces (IDE, KasmVNC binaries + www, cert, assets) ride the volume from
the tiny injector; the non-relocatable pieces they link against (GUI/streaming
runtime libs) plus the Android SDK + JCEF JBR live in the `sdk` toolchain image.
The user OWNS that toolchain container — the editor only contributes onto it.

### Standalone vs. merged

If the workspace has no dev container of its own, the contribution runs
**standalone** on the `sdk` placeholder image (GUI + SDK present → works). If the
workspace supplies its own dev container, the contribution **merges** into it and
that image wins — so it must be GUI-capable (build `FROM …/sdk`). See the BYO
toolchain contract in `DEVFILE.md`.

## Lifecycle

1. **Register the editors** (once per Che install): `hack/register-editors.sh`
   wraps each editor definition in a labeled ConfigMap; the dashboard serves them
   at `/dashboard/api/editors`.
2. **Workspace start** (per developer): the developer picks the editor (or a repo
   selects it via `.che/che-editor.yaml`). Che materializes the pod; the injector
   stages the IDE + relocated KasmVNC + assets into the shared volume; the merged
   contribution's entrypoint forces `HOME`/`XDG` to the PVC, seeds first-run state,
   places openbox config, starts dbus, writes `~/.vnc/xstartup`, and execs the
   STAGED KasmVNC (which starts its own X server and runs xstartup → openbox +
   auto-launched, maximized IDE).
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
