# AGENTS.md (anchor/)

Package `bybit-sim-anchor`: makes the simulator follow reference markets (Bybit and Binance).

- `Spec` parses the `-anchor` flags; `Reference` builds the live feeds and raw normalizers from
  `bybit-client` and `binance-client`; `Anchors` holds the running anchors, steps them on the
  server clock and serves `GET /sim/anchor`.
- A recorded source steps the clock at `-anchor-speed` times wall time. Keep that rule when the
  clock hook changes.
- `test/` runs against a recorded minute under `test/fixtures/raw/`. Fixtures are data.
- Build: `dune build --root .. @bybit-sim/all` from the repository root.
