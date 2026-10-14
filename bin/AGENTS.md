# AGENTS.md (bin/)

`bybit-sim` executable. Flags are listed in the README and the spec; the default port is 3400.
Add a flag in `main.ml` and in the README in the same commit.

- Check the port before starting a second instance: `lsof -iTCP:3400 -sTCP:LISTEN`.
- Build: `dune build --root .. @bybit-sim/all` from the repository root.
