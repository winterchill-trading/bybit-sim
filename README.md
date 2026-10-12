# bybit-sim

Bybit v5 linear perpetual exchange simulator.

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core,
Async). bybit-sim is a Bybit adapter over the venue-neutral engine in
[exchange-core](https://github.com/winterchill-trading/exchange-core)
(`exchange-core-engine`: matching, clearinghouse, margin, funding, liquidation and
synthetic order flow). Requests and responses use the wire types from
[bybit-protocol](https://github.com/winterchill-trading/bybit-protocol). It is the Bybit
counterpart of [hl-sim](https://github.com/winterchill-trading/hl-sim).

## Running

```sh
dune exec bybit-sim -- -port 3400
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `-port` | 3400 | HTTP and websocket port |
| `-seed` | 0 | market simulation random seed |
| `-vol-bps` | 5 | reference price volatility per second, in basis points |
| `-symbols` | all | comma-separated symbols the noise traders trade |
| `-noise-traders` | 10 | noise trader accounts; 0 disables the market simulation |
| `-initial-balance` | 1000000 | USDT credited to any API key on first use |
| `-log-level` | info | `debug`, `info`, `warn` or `error` |

Logs go to stderr: fills and liquidations at `info`, every event and websocket
(un)subscription at `debug`.

The universe is BTCUSDT, ETHUSDT and SOLUSDT (see `/v5/market/instruments-info`):

| Symbol | tickSize | qtyStep = minOrderQty | max leverage |
| --- | --- | --- | --- |
| BTCUSDT | 0.1 | 0.001 | 100 |
| ETHUSDT | 0.01 | 0.01 | 100 |
| SOLUSDT | 0.01 | 0.1 | 100 |

All have a 5 USDT minimum order value, Bybit's base fees (taker 0.055%, maker 0.02%),
10x leverage and funding every 8 hours at 0.01%.

## Authentication

Signatures are not verified. On private REST endpoints:

- `X-BAPI-API-KEY` is the account. Any key works; the first request with a new key
  credits it `-initial-balance` USDT. Missing: retCode 10003.
- `X-BAPI-TIMESTAMP` (ms) must be present and, as on Bybit, within
  `X-BAPI-RECV-WINDOW` (default 5000) of the server clock: `server - recvWindow <= ts <
  server + 1000`. Otherwise retCode 10002.
- `X-BAPI-SIGN` is ignored, so real signing code works unchanged.

On the private websocket, `{"op": "auth", "args": [apiKey, expires, signature]}` is
accepted with any signature as long as `expires` is in the future; the account is
`apiKey`.

## REST

Every response is Bybit's envelope `{"retCode", "retMsg", "result", "retExtInfo",
"time"}`, with HTTP 200 (404 only for an unknown route). `category` must be `linear`.

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/v5/market/time` | `timeSecond`, `timeNano` |
| GET | `/v5/market/instruments-info` | optional `symbol` |
| GET | `/v5/market/orderbook` | `symbol`, `limit` (default 25) |
| GET | `/v5/market/tickers` | optional `symbol`; symbols without any price yet are omitted |
| POST | `/v5/order/create` | `Limit` (GTC, IOC, FOK, PostOnly) and `Market`, `reduceOnly`, `orderLinkId` |
| POST | `/v5/order/create-batch` | up to 20; per-order status in `retExtInfo.list` |
| POST | `/v5/order/cancel` | `orderId` or `orderLinkId` |
| POST | `/v5/order/cancel-all` | `symbol`, `baseCoin` or `settleCoin=USDT` |
| POST | `/v5/order/amend` | `qty` (new total) and/or `price`; keeps the `orderId` |
| GET | `/v5/order/realtime` | needs `symbol`, `baseCoin` or `settleCoin`; `openOnly=1` adds up to 500 closed orders |
| GET | `/v5/execution/list` | optional `symbol`, `orderId`, `orderLinkId`, `limit` |
| GET | `/v5/position/list` | needs `symbol` (flat entry if no position) or `settleCoin` |
| GET | `/v5/account/wallet-balance` | `accountType=UNIFIED`, one USDT coin |

```sh
auth() {
  echo "-H X-BAPI-API-KEY:alice -H X-BAPI-TIMESTAMP:$(python3 -c 'import time; print(int(time.time() * 1000))')"
}

curl -s 'localhost:3400/v5/market/instruments-info?category=linear'
curl -s 'localhost:3400/v5/market/orderbook?category=linear&symbol=BTCUSDT&limit=5'
curl -s 'localhost:3400/v5/market/tickers?category=linear&symbol=BTCUSDT'

# Rest a post-only bid
curl -s localhost:3400/v5/order/create $(auth) -d '{"category": "linear",
  "symbol": "BTCUSDT", "side": "Buy", "orderType": "Limit", "qty": "0.01",
  "price": "99000", "timeInForce": "PostOnly", "orderLinkId": "bid-1"}'

# Amend it, then cancel it
curl -s localhost:3400/v5/order/amend $(auth) -d '{"category": "linear",
  "symbol": "BTCUSDT", "orderLinkId": "bid-1", "price": "99100"}'
curl -s localhost:3400/v5/order/cancel $(auth) -d '{"category": "linear",
  "symbol": "BTCUSDT", "orderLinkId": "bid-1"}'

# Buy at market
curl -s localhost:3400/v5/order/create $(auth) -d '{"category": "linear",
  "symbol": "BTCUSDT", "side": "Buy", "orderType": "Market", "qty": "0.01"}'

curl -s 'localhost:3400/v5/order/realtime?category=linear&symbol=BTCUSDT&openOnly=1' $(auth)
curl -s 'localhost:3400/v5/execution/list?category=linear' $(auth)
curl -s 'localhost:3400/v5/position/list?category=linear&symbol=BTCUSDT' $(auth)
curl -s 'localhost:3400/v5/account/wallet-balance?accountType=UNIFIED' $(auth)
```

### Order outcomes

As on Bybit, create returns only an acknowledgement (`orderId`, `orderLinkId`); the
order's fate is in `/v5/order/realtime` and on the `order` topic.

- Rejected synchronously, no order created: unknown symbol, bad price or qty, RPI,
  hedge-mode `positionIdx` (10001), insufficient margin (110007), duplicate
  `orderLinkId` (110072), reduce-only with nothing to reduce (110017), below 5 USDT
  (110094).
- Accepted, then `Cancelled` with a `rejectReason`: post-only crossing
  (`EC_PostOnlyWillTakeLiquidity`), IOC or market order with nothing to fill
  (`EC_NoImmediateQtyToFill`), FOK that cannot fill completely (`EC_NoEnoughQtyToFill`),
  self-match (`EC_BySelfMatch`). These orders get a UUID-shaped `orderId`
  (`00000000-0000-4000-8000-...`) because the engine never assigned them one.
- Otherwise the `orderId` is the engine's order id in decimal (`"1"`, `"2"`, ...).

## Websocket

Both streams are served on the same port.

```sh
websocat ws://localhost:3400/v5/public/linear
{"op": "subscribe", "args": ["orderbook.50.BTCUSDT", "publicTrade.BTCUSDT", "tickers.BTCUSDT"]}
{"op": "ping"}

websocat ws://localhost:3400/v5/private
{"op": "auth", "args": ["alice", 4102444800000, "unchecked"]}
{"op": "subscribe", "args": ["order", "execution", "position", "wallet"]}
{"req_id": "1", "op": "ping"}
```

- Subscribe acks: `{"success": true, "ret_msg": "subscribe", "conn_id", "req_id",
  "op": "subscribe"}` (public; `ret_msg` is `""` on the private stream). An unknown topic
  fails the whole request with `"error:handler not found,topic:..."`; private topics
  before `auth` fail with `"Request not authorized"`.
- Pongs: public `{"success": true, "ret_msg": "pong", "conn_id", "req_id": "", "op":
  "ping"}`, private `{"req_id", "op": "pong", "args": ["<server ms>"], "conn_id"}`.
- `orderbook.{1,50,200,1000}.SYMBOL`: a snapshot on subscribe, then deltas (changed
  levels, size `"0"` for removed ones) with `u` increasing by one per message and `seq`
  the symbol's book change counter; depth 1 pushes snapshots only. Changes are coalesced
  per symbol, at most every 20ms.
- `publicTrade.SYMBOL`: trades as they happen, with tick direction; `i` is the engine
  trade id.
- `tickers.SYMBOL`: a snapshot on subscribe (once the symbol has a price), then deltas of
  the changed fields every 100ms.
- `order`, `execution`, `position`, `wallet` (also `order.linear`, ...): pushed after
  every request or simulation tick that changes them, for the authenticated key only.
  `position` and `wallet` are pushed for accounts that traded, were liquidated or paid
  funding.

## Differences from Bybit

- Only `category=linear`, one-way mode, cross margin, USDT perpetuals. No conditional,
  TP/SL, trailing or RPI orders, no SMP settings (self-matches are cancelled), no
  leverage endpoint (10x everywhere), no `maxOrderQty` enforcement.
- Signatures, rate limits and API key permissions are not checked.
- Amends are implemented as cancel and replace in the engine: the order keeps its
  `orderId` but loses its queue position. A rejected amend restores the old remainder,
  also at the back of the queue.
- `/v5/order/realtime` returns closed orders only with `openOnly=1` (and for lookups by
  id); pagination cursors are always `""`; `execution/list` ignores `startTime`,
  `endTime` and `execType`.
- Tickers have no 24h statistics or open interest; `indexPrice` equals `markPrice`.
  `fundingRate` is the configured rate.
- `closedSize` and `cumRealisedPnl` (closed PnL minus fees and funding) are computed by
  the simulator; `cumRealisedPnl` is lost once a position is closed and reopened. Wallet
  coin lists hold only USDT.
- The liquidation price is the engine's estimate and may be far out of range instead of
  `""`.
- Error texts for 10001 are the simulator's own.

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core https://github.com/winterchill-trading/exchange-core.git --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git --no-action
opam pin add exchange-core-engine https://github.com/winterchill-trading/exchange-core.git --no-action
opam pin add bybit-protocol https://github.com/winterchill-trading/bybit-protocol.git --no-action
opam install . --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains the sibling repos, dune uses their sources and
the pins are not needed.

## Modules

All modules live under `Bybit_sim`.

| Module | Description |
| --- | --- |
| `Adapt` | Universe and Bybit trading rules, request validation, engine rejection to retCode or rejectReason, conversions to bybit-protocol types (orderbook and deltas, trades, tickers, executions, positions, wallet) |
| `Orders` | Order registry: Bybit order ids stable across amends, order type and time in force, cumulative fills, status and reject reason, closed order history |
| `Venue` | The engine plus the registry: Bybit's trading and account endpoints, event buffering for the streams |
| `Server` | cohttp-async server for the REST routes and both websocket streams (async_websocket); drives the clock and the market simulation |

All engine access happens on the Async scheduler thread, so there is no locking. Before
each request the exchange clock is stepped to the wall clock (funding and liquidation run
then and on a 1s timer); events produced by a request are published to websocket
subscribers right after it. The market simulation ticks every 100ms through the same
path.

## Tests

`dune test` runs the server over HTTP and websocket on a free port with a fixed clock
(market data, order outcomes, amend, cancel, batch, executions, positions, wallet,
authentication, public and private streams), unit tests of the conversions, and a seeded
market simulation on the Bybit universe.
