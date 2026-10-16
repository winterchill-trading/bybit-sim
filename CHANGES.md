# Changes

Notable changes to the two packages of this repository (`bybit-sim` and
`bybit-sim-anchor`). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (before 1.0.0, a minor version may break the API).

## Unreleased

### Added

- The engine's price collar and halt rule as flags: `-collar-bps N` or `-collar-ticks N`,
  `-collar-reference last|mid|mark` (the mark by default when anchored, else the last
  trade), `-collar-action reject|reprice`, `-halt-levels "7:15m,13:15m,20:reopen"` and
  `-halt-scope market|symbol`. Off by default.
- `Guard`: the flags, applying them through the engine's recorded calls (an input journal
  replays them), Bybit's codes for the rejections and the status JSON.
- Collar rejections answer retCode 110003 (`Order price exceeds the allowable range: max
  buy price <bound>.` or `min sell price`), halt rejections 10001
  (`params error: symbol is halted`), on create, batch items and amend.
- `GET /sim/guard` (settings, halts, counters, the last 50 guard events) and
  `POST /sim/reopen` (optional `symbol`). Guard events are logged at `info`.
- `Venue.guard_events`.
- `scripts/collar-e2e.sh`: a market maker run against a collared simulator, checking the
  110003 refusal of a far-off buy.

### Compatibility

- Without the new flags the simulator behaves as before; `/v5` responses are unchanged.
