# Streaming

v1 streams the IDE desktop with **KasmVNC**. Selkies (WebRTC) is the v2
target. This doc explains the choice and what's involved in switching.

## Why KasmVNC for v1

- **Speaks HTTPS+WebSocket only.** That's exactly what Che's gateway is
  documented to proxy: devfile endpoints support `http/https/ws/wss`,
  with no path for raw VNC TCP. KasmVNC's "noVNC over HTTPS" wire is
  proxy-friendly and traverses Che's gateway as just another HTTPS
  endpoint.
- **Unprivileged.** Runs as the workspace user; no `/dev/kvm`, no
  privileged container, no custom SCC. Fits restricted-v2 on OpenShift.
- **GPU-acceleration available.** KasmVNC supports DRI3 with open-source
  drivers (Intel, AMDGPU, ARM). For v1 we run swrast (no GPU), but the
  upgrade path doesn't require swapping the streaming server.
- **Active.** 1.4.0 release (Oct 2025), kasmtech maintains, GPL-2.0.

### X11, not Wayland (and why)

The desktop is **X11** (KasmVNC's own `Xkasmvnc` server + openbox), and that's
a constraint, not a preference. KasmVNC is an X11 technology — a
TigerVNC/TurboVNC fork that ships and starts its own X server; there is no
Wayland-native KasmVNC. (It starts that X server itself — see CLAUDE.md for
why we must NOT also run Xvfb.) A Wayland
desktop would mean dropping KasmVNC for `wayvnc` + a wlroots compositor
(sway), or going straight to the WebRTC/Selkies path (v2). Separately, the
ASfP/IntelliJ JetBrains Runtime only has *experimental* native-Wayland
support and would run through XWayland in practice anyway. So X11 is correct
for v1; Wayland only re-enters the picture if/when v2 moves to Selkies.

What we give up vs Selkies:
- No H.264/H.265 hw encode in v1. KasmVNC's roadmap mentions H.264 as
  a "future goal" — not present today.
- No audio. KasmVNC's docs don't list audio as a supported feature.
  IDE doesn't need it; users wanting Slack-in-the-streamed-desktop will
  notice.
- Higher bandwidth than Selkies for fast-changing screen content
  (animations, scrolling). Tolerable for IDE work.

## Container layout

The desktop layer (`container/desktop/setup-desktop.sh`, applied in the dev
images) installs the KasmVNC `.deb` (pinned by `KASMVNC_VERSION`).
`container/entrypoint.sh` execs `kasmvncserver` on
`127.0.0.1:6901` — it starts its own X server and runs `~/.vnc/xstartup`,
which brings up openbox and auto-launches ASfP (kiosk model — see
ARCHITECTURE.md / CLAUDE.md).

Key flags from `entrypoint.sh`:

```
kasmvncserver :1 \
    -interface 127.0.0.1 \   # only Che's gateway can reach the port
    -websocketPort 6901 \    # HTTP+WS endpoint, no separate VNC port
    -SecurityTypes None \    # Che gateway already authenticated
    -select-de manual \      # keep our ~/.vnc/xstartup (openbox + ASfP)
    -fg                       # foreground; pid 1 of the pod
```

The editor definition's runtime component (`deploy/*-editor-definition.yaml`)
declares the endpoint:

```yaml
endpoints:
  - name: asfp-desktop
    targetPort: 6901
    exposure: public
    protocol: https
    secure: true            # JWT-proxied by Che's gateway
    attributes:
      cookiesAuthEnabled: true
      urlRewriteSupported: true
      type: main            # marks as primary entrypoint
```

`secure: true` puts the endpoint behind Che's JWT proxy — only the
workspace owner's session cookie can reach the iframe. `cookiesAuthEnabled`
lets static-asset requests inside the iframe use the workspace cookie
instead of going through OAuth (otherwise images fail with 401).

## v2: Selkies

Selkies is WebRTC over UDP — much better latency and bandwidth, audio
support, hardware H.264/HEVC encode via NVIDIA NVENC. It's MPL-2.0 and
was started by Google engineers (it's likely what Cloud Workstations
uses for graphics-accelerated streaming, though that's never been
publicly confirmed).

Migration cost:
1. **Separate Service + Ingress** — Che's gateway only proxies
   `http/https/ws/wss`. Selkies' UDP traffic needs to bypass the gateway
   via its own LoadBalancer/Ingress. That breaks Che's "single workspace
   URL" model and complicates JWT auth.
2. **TURN/STUN deployment** — for clients behind NAT/corporate firewalls
   that can't accept UDP, Selkies needs a TURN relay. coturn is the
   canonical choice; needs its own pod + Service + auth token rotation.
3. **GStreamer pipeline** — Selkies' encoder is GStreamer-based.
   Container needs the gstreamer-1.0 packages + (for hw encode) the
   nvidia-cuda-toolkit + libnvenc.
4. **NVIDIA device plugin** — for hw encode. Adds a node label / taint
   plan and a device-plugin DaemonSet.
5. **Authentication shim** — Selkies wraps a basic-auth or token path
   that's not Che JWT-aware. Either run Selkies behind Che's gateway as
   HTTPS-only (sacrificing the WebRTC win) or write a small auth shim.

The work is substantial — that's why Selkies is v2, not v1. v1 ships
something that works in days; v2 ships something that delights.
