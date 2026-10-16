#!/usr/bin/env bash
# End-to-end run with a price collar and a halt rule: starts bybit-sim (seeded noise
# traders) with -collar-bps 50 and -halt-levels 7:15m,13:15m,20:reopen, runs market-maker
# against it, then sends one buy far above the market and checks that it is refused with
# Bybit's price-out-of-range code (110003). Prints the maker's report, the refusal, the
# GET /sim/guard status and the answer to POST /sim/reopen.
#
#   scripts/collar-e2e.sh [SECONDS [MARKET-MAKER FLAGS...]]
#
# SECONDS is the market maker's run (default 30). Needs a dune workspace root one level
# up with market-maker checked out next to bybit-sim, plus curl and python3. Environment
# overrides: WORKSPACE, OPAM_SWITCH (5.2.0+ox), DUNE_BUILD_DIR (<root>/_build-bybit-sim),
# SEED (42), PORT (a free port), COLLAR_BPS (50), LOG_DIR (a temporary directory).
set -euo pipefail

run_for="${1:-30}"
shift || true
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="${WORKSPACE:-$(cd "$repo/.." && pwd)}"
switch="${OPAM_SWITCH:-5.2.0+ox}"
export DUNE_BUILD_DIR="${DUNE_BUILD_DIR:-$root/_build-bybit-sim}"
seed="${SEED:-42}"
collar_bps="${COLLAR_BPS:-50}"
if [[ ! -d "$root/market-maker" ]]; then
  echo "collar-e2e: $root/market-maker is missing; clone it next to bybit-sim" >&2
  exit 1
fi

echo "collar-e2e: building bybit-sim and market-maker (switch $switch)" >&2
(cd "$root" && opam exec --switch "$switch" -- dune build --root . \
  bybit-sim/bin/main.exe market-maker/bin/main.exe 2>/dev/null)
sim_exe="$DUNE_BUILD_DIR/default/bybit-sim/bin/main.exe"
mm_exe="$DUNE_BUILD_DIR/default/market-maker/bin/main.exe"

log_dir="${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/collar-e2e.XXXXXX")}"
mkdir -p "$log_dir"
port="${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
base_url="http://127.0.0.1:$port"

sim_pid=""
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  if [[ -n "$sim_pid" ]] && kill -0 "$sim_pid" 2>/dev/null; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "collar-e2e: starting bybit-sim on port $port (seed $seed), logs in $log_dir" >&2
"$sim_exe" -port "$port" -seed "$seed" -collar-bps "$collar_bps" \
  -halt-levels 7:15m,13:15m,20:reopen >"$log_dir/sim.log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 100); do
  curl -sf "$base_url/v5/market/time" >/dev/null 2>&1 && break
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "collar-e2e: bybit-sim exited early:" >&2
    cat "$log_dir/sim.log" >&2
    exit 1
  fi
  sleep 0.2
done
# Let the noise traders build a two-sided book and trade.
sleep 2

echo "collar-e2e: running market-maker for ${run_for}s" >&2
status=0
"$mm_exe" -venue bybit -network local -base-url "$base_url" -run-for "$run_for" "$@" \
  >"$log_dir/report.txt" 2>"$log_dir/mm.log" || status=$?
echo "--- market-maker report ---"
cat "$log_dir/report.txt"
if [[ $status -ne 0 ]]; then
  echo "collar-e2e: market-maker exited with $status; last log lines:" >&2
  tail -20 "$log_dir/mm.log" >&2
fi

# A buy 5% above the best ask: marketable, and far outside a 50 bps collar.
ask="$(curl -sf "$base_url/v5/market/orderbook?category=linear&symbol=BTCUSDT&limit=1" |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["a"][0][0])')"
px="$(python3 -c "print(round(float('$ask') * 1.05, 1))")"
now_ms="$(python3 -c 'import time; print(int(time.time() * 1000))')"
reply="$(curl -sf -X POST "$base_url/v5/order/create" \
  -H "X-BAPI-API-KEY: collar-e2e" -H "X-BAPI-TIMESTAMP: $now_ms" -H "X-BAPI-SIGN: unchecked" \
  -H "Content-Type: application/json" \
  -d "{\"category\":\"linear\",\"symbol\":\"BTCUSDT\",\"side\":\"Buy\",\"orderType\":\"Limit\",\"qty\":\"0.001\",\"price\":\"$px\"}")"
echo "--- buy at $px (best ask $ask) ---"
echo "$reply"
code="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["retCode"])' "$reply")"

echo "--- GET /sim/guard ---"
curl -sf "$base_url/sim/guard" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"collar": s["collar"], "halt_rule": s["halt_rule"], "stats": s["stats"],
                  "recent": s["recent"][-3:]}, indent=2))'
echo "--- POST /sim/reopen ---"
curl -sf -X POST "$base_url/sim/reopen" | python3 -c '
import json, sys
s = json.load(sys.stdin)
print(json.dumps({"stats": s["stats"], "halted": [x["symbol"] for x in s["symbols"] if x["halt"]]}))'

if [[ "$code" != 110003 ]]; then
  echo "collar-e2e: FAILED: expected retCode 110003, got $code" >&2
  exit 1
fi
if [[ $status -ne 0 ]]; then
  exit "$status"
fi
echo "collar-e2e: passed" >&2
