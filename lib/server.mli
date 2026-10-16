(** HTTP and websocket front end for the venue-neutral engine
    ({!Exchange_core_engine.Exchange}, wrapped by {!Venue}), speaking Bybit's v5 API for
    [category=linear] on a single port.

    REST (every response is the [{retCode, retMsg, result, retExtInfo, time}] envelope,
    with HTTP status 200 unless the route does not exist):
    - public: [GET /v5/market/time], [/v5/market/instruments-info],
      [/v5/market/orderbook], [/v5/market/tickers];
    - private: [POST /v5/order/create], [/v5/order/create-batch], [/v5/order/cancel],
      [/v5/order/cancel-all], [/v5/order/amend]; [GET /v5/order/realtime],
      [/v5/execution/list], [/v5/position/list], [/v5/account/wallet-balance].

    Simulator endpoints (plain JSON, no envelope): [GET /sim/guard], the price collar and
    halt rule status ({!Guard.status}), and [POST /sim/reopen] (optional [symbol] query
    parameter), which lifts halts ({!Exchange_core_engine.Exchange.reopen}) and answers
    the same status.

    Private requests are identified by the [X-BAPI-API-KEY] header: the key {e is} the
    account, and every key is credited [Config.initial_balance] the first time it is seen.
    [X-BAPI-SIGN] is not verified, but [X-BAPI-TIMESTAMP] must be present and within
    [X-BAPI-RECV-WINDOW] (default 5000ms) of the server clock, as on Bybit; otherwise
    10002 (a missing key gives 10003).

    Websocket ([Upgrade: websocket]):
    - [/v5/public/linear]: [orderbook.{1,50,200,1000}.SYMBOL] (a snapshot on subscribe,
      then deltas with consecutive [u]; depth 1 always pushes snapshots),
      [publicTrade.SYMBOL], [tickers.SYMBOL] (snapshot on subscribe, then deltas from
      {!start_periodic});
    - [/v5/private]: [{"op": "auth", "args": [apiKey, expires, signature]}] first (the
      signature is not checked, [expires] must be in the future), then [order],
      [execution], [position] (also [.linear]) and [wallet] for the account [apiKey].

    The exchange is owned by the server and mutated only from the Async scheduler thread;
    every mutation goes through {!mutate}, which advances the exchange clock and then
    publishes the resulting events to websocket subscribers. *)

open! Core
open! Async
open! Bybit_protocol
module Exchange := Exchange_core_engine.Exchange

module Config : sig
  type t =
    { initial_balance : Usd.t (** credited to each API key on first use *)
    ; book_interval : Time_ns.Span.t (** minimum spacing of orderbook pushes per symbol *)
    ; ticker_interval : Time_ns.Span.t (** period of ticker deltas *)
    ; step_interval : Time_ns.Span.t
    (** period of the clock step that charges funding and liquidates *)
    }
  [@@deriving sexp_of]

  (** 1,000,000 USDT, 20ms, 100ms, 1s. *)
  val default : t
end

type t

(** [now] returns the current time in nanoseconds since the epoch (default: the wall
    clock). The exchange is stepped to [now ()] before each request. Tests pass a constant
    to make timestamps deterministic. *)
val create : ?config:Config.t -> ?now:(unit -> int) -> Exchange.t -> t

val config : t -> Config.t
val venue : t -> Venue.t

(** Credits [initial_balance] to the account unless it has been seen before. *)
val ensure_account : t -> Exchange_core.Account.t -> unit

(** Steps the exchange clock, calls the {!on_step} hooks, runs [f], then logs and
    publishes the events it produced (the hooks' included). *)
val mutate : t -> f:(Venue.t -> 'a) -> 'a

(** Adds a hook called by every {!mutate} right after the clock step, with the exchange's
    time in nanoseconds. Hooks may mutate the exchange; they run in the order added. *)
val on_step : t -> (now:int -> unit) -> unit

(** Answers [GET path] with [f ()] as plain JSON (no envelope, HTTP 200), ahead of the
    Bybit routes. For simulator-only endpoints such as status pages. *)
val add_route : t -> path:string -> (unit -> Yojson.Safe.t) -> unit

(** Answers one REST request (exposed for tests; the HTTP server calls it). *)
val handle_http
  :  t
  -> meth:Cohttp.Code.meth
  -> uri:Uri.t
  -> headers:Cohttp.Header.t
  -> body:string
  -> Cohttp.Code.status_code * Yojson.Safe.t

(** {2 Network} *)

(** Starts the HTTP/websocket server; [port] 0 picks a free port (see {!port}). Does not
    start the periodic tasks. *)
val listen
  :  t
  -> port:int
  -> (Socket.Address.Inet.t, int) Cohttp_async.Server.t Deferred.t

val port : (Socket.Address.Inet.t, int) Cohttp_async.Server.t -> int

(** Starts the periodic tasks: ticker deltas and clock steps. *)
val start_periodic : t -> unit

(** Calls {!Exchange_core_engine.Market_sim.tick} every [tick_interval] through {!mutate}. *)
val run_market_sim : t -> Exchange_core_engine.Market_sim.t -> unit

val num_ws_connections : t -> int
