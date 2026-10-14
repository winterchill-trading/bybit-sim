# AGENTS.md (scripts/)

`anchor-demo.sh` runs the simulator anchored to a recorded Bybit BTCUSDT minute under
`anchor/test/fixtures`, connects `market-maker` to it and prints the shadow levels and the
maker's quotes as they follow the recording. `SPEED` paces the replay (default 1, real time);
further arguments go to `market-maker`.

- It needs `market-maker` checked out next to this repository in one dune workspace; the header
  comment lists the environment overrides (`DUNE_BUILD_DIR`, `OPAM_SWITCH`).
- Keep scripts free of hard-coded absolute paths; take them from the environment.
