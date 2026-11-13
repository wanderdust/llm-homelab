# Excalidraw canvas — 2026-11-13

## What was added
`apps/excalidraw/`: the canvas server from `yctimlin/mcp_excalidraw`
(`ghcr.io/yctimlin/mcp_excalidraw-canvas:2.2.0`) as one Deployment, a 1 Gi `local-path` PVC and a
LoadBalancer on `:3001`.

## In-cluster vs client-side MCP: client-side
The MCP server (v2.2.0) supports **stdio only**. Its README says it does not serve MCP at `/mcp`
or `/sse`. So it isn't deployed: each client starts it locally and points `EXPRESS_SERVER_URL`
at `http://192.168.1.245:3001`. Nothing listens on `:3002`. Adding a third-party stdio-to-HTTP
bridge would mean one more moving part to debug, for no gain on a LAN.

## Choices
- **Persistence on.** v2.2 added `EXCALIDRAW_DATA_DIR`, so elements, images and snapshots
  survive restarts. Set to `/data/canvas` (a subdir, because the server chmods its data dir 700).
- **Stale lock removed at start.** The server takes a lock dir that records its pid. In a container
  that pid is always 1, so after an unclean stop (power cut) the next pod would see the "owner"
  as still running and refuse to start. The container command deletes the lock before
  `exec node dist/server.js`. This is safe with 1 replica and `Recreate`.
- **`PORT=3001` inside the container too,** so the port is the same everywhere.
- No node rules, no GPU: it can move to a non-GPU node (the PVC data would need copying or be lost).

## Verified
- `/health` shows `durable_state_enabled: true`; `/` serves the UI.
- `POST /api/elements` reached a WebSocket client live (`element_created` message).
- State survived a force-deleted pod. Re-running `deploy.sh` printed only `unchanged`.
- `npx -y mcp-excalidraw-server@2.2.0` on the laptop over stdio listed 27 tools, and
  `create_element` drew on the cluster canvas.

## Outdated items in the original spec
- The canvas listens on 3000 by default and binds `127.0.0.1` outside Docker (the image sets
  `HOST=0.0.0.0`).
- Persistence exists now (opt-in); older versions were memory-only.
