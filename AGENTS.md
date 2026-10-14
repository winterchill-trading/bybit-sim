# AGENTS.md

## Purpose

A local Bybit v5 linear perpetual simulator: REST under `/v5`, the public stream
`/v5/public/linear` and the private stream `/v5/private`, built on the shared exchange engine.
`bybit-client` and the market maker run against it in tests and in local development.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Library `bybit_sim`: `Adapt`, `Orders` (order registry), `Venue` (engine plus registry), `Server` (see `lib/AGENTS.md`) |
| `anchor/` | Package `bybit-sim-anchor`: the `-anchor` flags, reference sources, anchored state (see `anchor/AGENTS.md`) |
| `bin/` | `bybit-sim` executable, default port 3400 (see `bin/AGENTS.md`) |
| `test/` | Expect tests of adaptation, the market simulation and the server over HTTP and websocket (see `test/AGENTS.md`) |
| `scripts/` | `anchor-demo.sh`: a short anchored run with `market-maker` (see `scripts/AGENTS.md`) |
| `.github/` | CI workflow (see `.github/AGENTS.md`) |
| `bybit-sim.opam`, `bybit-sim-anchor.opam`, `dune-project` | Two opam packages, generated from `dune-project` |

## Build, test, docs

Run from this directory. The workspace root `..` holds the sibling checkouts and the shared
`dune-workspace`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-sim/all
opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-sim/runtest
DUNE_BUILD_DIR=_build-bybit-sim opam exec --switch 5.2.0+ox -- dune build --root .. @bybit-sim/all
```

The last line is for parallel work: a private build directory avoids the lock shared with
other repositories in the workspace.

Run the simulator: `dune exec bybit-sim -- -port 3400`. Anchored to live Bybit mainnet public
streams (no keys): `dune exec bybit-sim -- -anchor bybit:BTCUSDT=BTCUSDT`. The README lists the
replay flags (`-anchor-raw`, `-anchor-norm`, `-anchor-from`, `-anchor-to`, `-anchor-speed`).

Standalone (outside the workspace), the `Build` section of `README.md` lists the opam pins
and the install commands.

## Conventions

- Formatting: `dune build --root .. @bybit-sim/fmt --auto-promote`, run after the tests pass.
  Never `dune fmt` at the workspace root; it reformats every sibling repository.
- Every module has an `.mli`. Use `open! Core`, labelled arguments and `ppx_jane`.
- Venue behaviour that the engine does not keep (order type, time in force, cumulative fills,
  reject reason) lives in `Orders`, fed once from the engine's event stream.
- `lib/` must not depend on `bybit-client`; only `anchor/` does. The client's tests depend on
  this library, so a cycle would break the build.
- Simulator behaviour is described in `../specs/design/simulators.md` and the README; update
  them with the code.
- Add a short comment at any non-obvious choice, such as why an amend is a cancel and replace.
- Document every public value in its `.mli` with odoc comments.

## Dependencies and dependents

- Depends on: `fixed-decimal`, `exchange-core`, `exchange-core-engine`, `bybit-protocol`,
  `order-book`. `anchor/` also needs `market-data`, `price-anchor`, `bybit-client` and
  `binance-client`.
- Used by: `bybit-client` (tests); `market-maker -venue bybit -network local`.
- CI pin order: `fixed-decimal`, `exchange-core`, `order-book`, `exchange-core-engine`,
  `parquet`, `market-data`, `price-anchor`, `venue-net`, `bybit-protocol`, `binance-protocol`,
  `mm-core`, `bybit-client`, `binance-client`.

## CI

`.github/workflows/ci.yml` runs the `ox-setup` action with the pins above (its opam switch is
cached between runs), then `dune build` and `dune test`. The `obj-magic` job calls the shared
reusable workflow. To check a run: `gh run list --limit 1`, then at most one
`gh run watch <id> --exit-status`. Do not poll in a loop.

## Pitfalls

- A Bybit order id stays the same across amends, but the engine implements amend as cancel and
  replace, so the order loses its queue position. Keep the id in `Orders`, not in the engine.
- Create returns only an acknowledgement. The order's outcome arrives on `/v5/order/realtime`
  and on the `order` topic; tests must wait for those.
- Drop finished orders from `Orders`, or noise flow makes the table grow without bound.
- Flush pending order book deltas before a new websocket subscriber registers, or its first
  message is a delta instead of the snapshot.
- In this Async version `Bus.iter_exn` does not exist; use `Bus.subscribe_permanently_exn`.
- `Cohttp.Code.meth` has no `equal`; use `Poly.equal`.
- The simulator does not check signatures, recv windows or rate limits. Do not write tests that
  depend on them failing.

## Where to read more

- `README.md` (endpoints, outcomes, websocket, differences from Bybit).
- `../specs/repos/bybit-sim.md` and `../specs/design/simulators.md`.
- `../specs/design/price-anchor.md` for the anchoring design.
- Skills in `../oxcaml-claude-skills/skills/`: `async-http-websocket`, `janestreet-ocaml-style`.
- `../oxcaml-claude-skills/AGENTS.md`: the workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the dated log these pitfalls come from.

## Never do

- Run `opam install`, `opam upgrade` or `opam pin` on the shared `5.2.0+ox` switch without a
  dry run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`. Abort if the plan touches
  `ocaml-variants`, `core`, `base`, `async` or `ppx_jane`.
- Publish, tag or release a version from this repository without the maintainers asking.
- Commit credentials or print secrets.
- Poll CI in a loop.
