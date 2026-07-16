# Storage

che-android-studio itself only requires **one persistent volume per workspace**:
the per-user `$HOME`, which Che provisions automatically. Everything else
(large source trees, build output) is optional and depends on what you're
developing.

## Per-user `$HOME` (required)

| Mount | Type | Notes |
|---|---|---|
| `/home/user` | per-user PVC, RWO | Provisioned by Che on workspace start. Holds IntelliJ caches (`~/.cache/Google/AndroidStudio*/`), IDE config, shell history. Persists across pod restarts so the second launch doesn't re-index from scratch. |

The entrypoint keeps IDE **config + plugins** on this PVC, but relocates the
memory-mapped VFS/index/log paths to the container's `/tmp` overlay — mmap
`MAP_SHARED` writeback isn't coherent on some idmapped RWO volumes and corrupts
the VFS otherwise. Losing `/tmp` on restart only re-indexes (cheap); see
`CLAUDE.md` for the full rationale.

## Working against a large source tree (optional)

For platform-scale work (e.g. an AOSP checkout — hundreds of GB), add a volume to
the workspace devfile and mount it into your project. Considerations:

- **Read-only shared vs per-user.** A single shared tree mounted read-only keeps
  every user from dirtying it; IntelliJ indexing is read-only and stores its
  index on the per-user `$HOME` PVC, so a RO source mount is fine.
- **Access mode.** A one-node setup can use a hostPath / `ReadWriteOnce` PV
  (every workspace then schedules to that node — fine for a small team, doesn't
  scale). Multi-node needs **ReadWriteMany** (CephFS, NFS, JuiceFS, …) or a
  per-user clone (CephFS subvolume snapshot+clone is a clean fit).
- **Populate it out-of-band.** Seed the tree with whatever your source workflow
  is (`git`, `repo sync`, an rsync from a golden copy). che-android-studio does
  not prescribe a source layout.

## inotify limits (important for large trees)

Indexing a large tree exhausts the default `fs.inotify.max_user_watches` (often
8192–524288 depending on distro), and the IDE then fails to watch files. Raise
it at the node level (requires `CAP_SYS_ADMIN`, i.e. a privileged/`sysctl`
DaemonSet, or node config):

- `fs.inotify.max_user_watches=1048576`
- `fs.inotify.max_user_instances=1024`
- `fs.inotify.max_queued_events=32768`

This is a cluster-node concern, deliberately **not** bundled here — how you tune
nodes (a privileged DaemonSet, machine config, kernel args) is install-specific.

## Faster first launch (optional)

Because indexing is the slow part of the first launch, a "golden"
`~/.cache/Google/AndroidStudio*/` PVC — pre-populated by running the IDE's
indexing once against your target — can be cloned onto each new workspace's
`$HOME` so first launch is near-instant. This needs a CSI/storage class that
supports volume cloning (CephFS does; many local-path provisioners don't).
