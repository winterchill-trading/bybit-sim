# AGENTS.md (lib/)

Library `bybit_sim`: the Bybit-shaped front end over the shared engine.

- `Adapt` validates requests, maps engine rejections to `retCode` or `rejectReason`, and converts
  to `bybit-protocol` types. Bybit rules belong here, not in the engine.
- `Orders` is the order registry: Bybit order ids, cumulative fills, status, reject reason and the
  closed history.
- `Venue` joins the engine and the registry; it buffers events for the streams.
- `Server` runs cohttp-async for REST and both websockets and drives the clock.
- Build: `dune build --root .. @bybit-sim/all` from the repository root.
