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
  - an **injector** container (the `*-editor` image) that stages the IDE tree
    into the shared volume at `preStart`,
  - a **runtime** container (the `*-dev` image,
    `controller.devfile.io/container-contribution: true`) carrying the
    KasmVNC/HTTPS endpoint on port 6901.
- `commands` + `events` wire the injector to `preStart` and the entrypoint to
  `postStart`.

## Endpoint behavior

The runtime's single desktop endpoint:

```yaml
- name: asfp-desktop
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
