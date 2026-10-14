# AGENTS.md (test/)

Tests for `bybit_sim`: adaptation and validation (`test_adapt.ml`), the market simulation
(`test_market_sim.ml`) and the server over HTTP and websocket on a free port (`test_server.ml`).

- The server runs with a fixed clock; keep it fixed so outputs do not depend on wall time.
- Run: `dune build --root .. @bybit-sim/runtest` from the repository root.
- Promote expect output with `dune promote` only after reading the diff.
