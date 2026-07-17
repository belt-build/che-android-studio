# Devfiles & selecting the editor

che-android-studio ships as a Che **editor definition**, not a full workspace
devfile. A workspace selects the editor; the editor supplies the streamed
desktop container. This keeps workspace devfiles minimal (just project +
volumes).

## Selecting the editor

The editor definitions register two ids:

- `che-android-studio/asfp/latest` — Android Studio for Platform
- `che-android-studio/android-studio/latest` — regular Android Studio

Once registered (see `hack/register-editors.sh`), select one of:

1. **Dashboard dropdown** — the editors appear on the "Create Workspace" page.
2. **By repo** — commit a `.che/che-editor.yaml` to your project:
   ```yaml
   id: che-android-studio/asfp/latest
   ```
3. **By URL** — append `?che-editor=che-android-studio/asfp/latest` when
   importing a repo in the dashboard.
4. **Cluster default** — set `spec.devEnvironments.defaultEditor` on the
   CheCluster CR to the editor id.

## Example workspace devfile

`examples/devfile.yaml` is a bare devfile (schema 2.2.0) with a persistent
`home` volume and no IDE container of its own — the editor supplies that. Start
a workspace from it via the dashboard's "Import from Git" / "from local devfile".

To work against a large source tree (e.g. an AOSP checkout), add a `volume`
component and mount it; for platform-scale trees prefer a ReadWriteMany storage
class or a pre-populated PVC (see `STORAGE.md`).

## Editor definition structure

Each `deploy/*-editor-definition.yaml` is a devfile (schema 2.2.2) with:

- `metadata` — `name` + `attributes.publisher` + `attributes.version` compose
  the editor id (`<publisher>/<name>/<version>` →
  `che-android-studio/asfp/latest`), plus the display name + SVG icon shown in
  the dropdown.
- `components`:
  - a shared `volume: {}` (`che-android-studio`, mounted at
    `/che-android-studio`),
  - an **injector** container (the `*-editor` image) that stages the IDE tree +
    the relocated KasmVNC + assets into the shared volume at `preStart`,
  - a **runtime** container marked
    `controller.devfile.io/container-contribution: true` (image: the `sdk` base as
    a placeholder) carrying the HTTPS endpoint on port 6901 + the `IDE_FLAVOR` env.
    The DevWorkspace controller MERGES this into the workspace's dev container (see
    the BYO contract below); with no dev container it runs standalone on `sdk`.
- `commands` + `events` wire the injector to `preStart` and the entrypoint to
  `postStart`.

## Bring your own toolchain container

Because the container-contribution merge keeps the USER's dev container image (the
editor's `sdk` image is only a placeholder), a workspace that supplies its own
dev/tools container must make it **GUI-capable**, or the desktop won't render.
Build it `FROM ghcr.io/kirkbrauer/che-android-studio/sdk` and add whatever tools
you need:

```Dockerfile
FROM ghcr.io/kirkbrauer/che-android-studio/sdk:latest
RUN sudo apt-get update && sudo apt-get install -y ripgrep …   # your tools
```

The `sdk` base carries the GUI/streaming runtime libs + the Android SDK + JCEF JBR
at their expected `/opt` paths. If you cannot base on `sdk`, replicate its
GUI/streaming apt set (see `container/sdk/Containerfile`) and provide the SDK/JBR.
If your workspace declares no dev container at all, nothing extra is needed — the
contribution runs standalone on `sdk`.

## Endpoint behavior

The runtime's single desktop endpoint (`asfp-desktop` / `studio-desktop`):

```yaml
- name: asfp-desktop      # studio-desktop in the Android Studio definition
  targetPort: 6901
  exposure: public
  protocol: https
  secure: true
  attributes:
    type: main
    cookiesAuthEnabled: true
    urlRewriteSupported: true
    discoverable: false
```

- `protocol: https` + `secure: true` — Che's gateway terminates TLS and wraps
  the endpoint in its JWT proxy; only the workspace owner's cookie reaches it.
  (The backend itself serves **plain HTTP** on loopback — see `CLAUDE.md`.)
- `cookiesAuthEnabled` — lets static-asset requests inside the KasmVNC iframe use
  the workspace cookie (otherwise they 401).
- `urlRewriteSupported` + the client-side sub-path fix — let the noVNC websocket
  target the per-workspace sub-path instead of the host root (see `CLAUDE.md`).
- `type: main` — marks the primary "Open" entrypoint.

## Schema reference

- Devfile 2.2.x spec: <https://devfile.io/docs/2.2.0/>
- Endpoints: <https://devfile.io/docs/2.3.0/defining-endpoints>
- Container components: <https://devfile.io/docs/2.3.0/adding-a-container-component>
