#!/usr/bin/env bash
# Runs bybit-sim anchored to the recorded Bybit BTCUSDT minute in
# anchor/test/fixtures (21 seconds, replayed in real time), connects the market maker
# to it, and prints once a second the reference price, the simulator's best bid and
# ask (the shadow levels) and the market maker's own best quotes, which follow them.
#
#   scripts/anchor-demo.sh [SPEED [MARKET-MAKER FLAGS...]]
#
# SPEED paces the recording (default 1, real time); further arguments go to the market
# maker, e.g. `-half-spread-bps 0.5` to quote close enough for trade-replay fills. Needs a dune workspace root one level
# up with market-maker checked out next to bybit-sim (as for market-maker/scripts/e2e.sh),
# plus curl and python3.
set -euo pipefail

speed="${1:-1}"
shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-bybit-sim}"
if [[ ! -d "$root/market-maker" ]]; then
  echo "anchor-demo: $root/market-maker is missing; clone it next to bybit-sim" >&2
  exit 1
fi

echo "anchor-demo: building bybit-sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  bybit-sim/bin/main.exe market-maker/bin/main.exe 2>/dev/null)
sim_exe="$DUNE_BUILD_DIR/default/bybit-sim/bin/main.exe"
mm_exe="$DUNE_BUILD_DIR/default/market-maker/bin/main.exe"

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/anchor-demo.XXXXXX")"
port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"
key=anchor-demo

sim_pid=""
mm_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  for pid in "$mm_pid" "$sim_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "anchor-demo: bybit-sim on port $port, logs in $log_dir" >&2
"$sim_exe" -port "$port" -noise-traders 0 \
  -anchor bybit:BTCUSDT=BTCUSDT \
  -anchor-raw "$repo/anchor/test/fixtures" \
  -anchor-from 2026-10-12T15:05:00Z -anchor-to 2026-10-12T15:06:00Z \
  -anchor-speed "$speed" -input-journal "$log_dir/inputs.journal" \
  >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 50); do
  curl -sf "$base_url/v5/market/time" >/dev/null 2>&1 && break
  sleep 0.2
done

BYBIT_API_KEY="$key" "$mm_exe" -venue bybit -network local -base-url "$base_url" -symbol BTCUSDT \
  -run-for 22 "$@" >"$log_dir/report.txt" 2>"$log_dir/mm.log" &
mm_pid=$!

sample() {
  local anchor book orders ts
  anchor="$(curl -sf "$base_url/sim/anchor")"
  book="$(curl -sf "$base_url/v5/market/orderbook?category=linear&symbol=BTCUSDT&limit=1")"
  ts="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  orders="$(curl -sf -H "X-BAPI-API-KEY: $key" -H "X-BAPI-TIMESTAMP: $ts" \
    "$base_url/v5/order/realtime?category=linear&symbol=BTCUSDT")"
  python3 -I -c '
import json, sys
anchor, book, orders = (json.loads(a) for a in sys.argv[1:4])
a = anchor["anchors"][0]
b = book["result"]
best = lambda side: side[0][0] if side else "-"
mine = orders["result"]["list"]
bids = [float(o["price"]) for o in mine if o["side"] == "Buy"]
asks = [float(o["price"]) for o in mine if o["side"] == "Sell"]
print("%-6s %10s %10s %10s %10s %10s %6s %5s" % (
    "fresh" if a["fresh"] else "stale", a["reference_price"] or "-",
    best(b["b"]), best(b["a"]),
    "%.1f" % max(bids) if bids else "-", "%.1f" % min(asks) if asks else "-",
    a["shadow_levels"], a["replay_fills"]))
' "$anchor" "$book" "$orders"
}

printf "%-6s %10s %10s %10s %10s %10s %6s %5s\n" \
  state reference sim_bid sim_ask mm_bid mm_ask shadow fills
while kill -0 "$mm_pid" 2>/dev/null; do
  sample || true
  sleep 1
done
wait "$mm_pid" || true
mm_pid=""
echo
cat "$log_dir/report.txt"
