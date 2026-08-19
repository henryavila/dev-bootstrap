# syncthing

P2P file sync daemon for cross-machine folders.

`syncthing/syncthing` is tagged `membership: mesh` — under `--no-mesh` /
`MESH_NO_MESH=1` it is **omitted from the catalog**. Mesh nodes select it in
Blink / `selections.list` or via `--bundle syncthing/syncthing`.
