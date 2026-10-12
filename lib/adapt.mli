(** Bybit front end of the venue-neutral engine ({!Exchange_core_engine.Exchange}): the
    linear-perpetual universe with Bybit's trading rules, request validation, the mapping
    of engine rejections to [retCode]s or [rejectReason]s, and the conversions from engine
    views and events to {!Bybit_protocol} wire types.

    Everything here is a pure function of its arguments. The engine counts time in
    nanoseconds; every Bybit-facing timestamp is in milliseconds. *)

open! Core
open! Bybit_protocol
module Exchange := Exchange_core_engine.Exchange

(** {2 Universe} *)

(** BTCUSDT (tick 0.1, qty step 0.001), ETHUSDT (0.01, 0.01) and SOLUSDT (0.01, 0.1), all
    100x with [minOrderQty = qtyStep] and a 5 USDT minimum notional. *)
val default_instruments : Instruments_info.Instrument.t list

(** Bybit's base VIP0 tier for perpetuals: taker 5.5 bps, maker 2 bps. *)
val fees : Exchange_core.Fee_schedule.t

(** {!Instruments_info.Instrument.to_exchange_core} with {!fees}. *)
val instrument : Instruments_info.Instrument.t -> Exchange_core.Instrument.t

(** {!Exchange.Config.default} with the given instruments (default
    {!default_instruments}), 10x default leverage, 8-hourly funding at 0.01%, a 5 USDT
    minimum order value and 25 book levels. *)
val config : ?instruments:Instruments_info.Instrument.t list -> unit -> Exchange.Config.t

val create_exchange
  :  ?instruments:Instruments_info.Instrument.t list
  -> unit
  -> Exchange.t

(** ["BTC"] for ["BTCUSDT"]: the symbol without its [USDT] suffix. *)
val base_coin : Symbol.t -> string

(** {!Exchange_core_engine.Market_sim.Config.default} with orders up to 20000 USDT. *)
val market_sim_config : Exchange_core_engine.Market_sim.Config.t

(** The instruments of the exchange in Bybit's format, optionally only [symbol]. *)
val instruments_info : ?symbol:Symbol.t -> Exchange.t -> Instruments_info.t

(** {2 Errors} *)

module Api_error : sig
  (** A non-zero [retCode] with its [retMsg]. *)
  type t =
    { code : Envelope.Error.t
    ; msg : string
    }
  [@@deriving sexp_of, compare, equal]

  (** [10001] with [msg]. *)
  val params : string -> t

  val order_not_exists : t
end

module Rejection : sig
  type t =
    | Api_error of Api_error.t
    (** rejected synchronously: the request fails with this [retCode] *)
    | Cancelled of Reject_reason.t
    (** accepted, then cancelled at once with this [rejectReason] (post-only crossing,
        IOC/FOK/market with nothing to fill, self-match) *)
  [@@deriving sexp_of, compare, equal]
end

(** How Bybit reports each engine rejection:
    - unknown symbol, unsupported order, bad price or qty: 10001;
    - reduce-only with nothing to reduce: 110017;
    - below the minimum notional: 110094;
    - insufficient margin: 110007;
    - duplicate [orderLinkId]: 110072;
    - order not found (amend): 110001;
    - post-only crossing: [EC_PostOnlyWillTakeLiquidity];
    - no liquidity: [EC_NoImmediateQtyToFill];
    - self-match: [EC_BySelfMatch]. *)
val rejection : Exchange_core.Reject_reason.t -> Rejection.t

(** {2 Requests} *)

(** The effective time in force: [IOC] for market orders, else the request's or [GTC]. *)
val time_in_force : Create_order.Params.t -> Time_in_force.t

(** The engine request for a Bybit order. Fails with 10001 for an unknown symbol, a limit
    order without price, an [UNKNOWN] order type, [RPI] or a hedge-mode [positionIdx].
    [FOK] becomes an engine IOC order; check {!fok_fillable} first. *)
val order_request
  :  Exchange.t
  -> Create_order.Params.t
  -> (Exchange_core.Order_request.t, Api_error.t) Result.t

(** Whether the opposite side of the book holds at least [size] at prices no worse than
    [px] (own orders included). *)
val fok_fillable
  :  Exchange.t
  -> symbol:Symbol.t
  -> side:Side.t
  -> px:Price.t
  -> size:Size.t
  -> bool

(** {2 Conversions} *)

(** Nanoseconds to milliseconds. *)
val ms : int -> Timestamp_ms.t

val book_levels : Exchange_core.L2.Level.t list -> Book_level.t list

(** The REST snapshot; [ts] is [now] (ns), [cts] the book time. *)
val orderbook : now:int -> u:int -> seq:int -> Exchange_core.L2.t -> Orderbook.t

(** The levels that differ between two snapshots of one book, as [(bids, asks)] in Bybit's
    delta form: changed or new levels with their new size, removed ones with size 0. Bids
    best first, asks best first. *)
val orderbook_delta
  :  prev:Exchange_core.L2.t
  -> Exchange_core.L2.t
  -> Book_level.t list * Book_level.t list

(** Bybit's tick direction of a trade at [px] after a trade at [prev_px] whose direction
    was [prev] ([PlusTick], [ZeroPlusTick], [MinusTick], [ZeroMinusTick]). *)
val tick_direction : prev:(Price.t * string) option -> Price.t -> string

(** A public trade; [i] is the engine trade id, [seq] the trade id too. *)
val public_trade : tick_direction:string -> Order_book.Fill.t -> Public_trade.Trade.t

(** The ticker of [symbol]: [lastPrice] is [last_price] (else the mark), [indexPrice] the
    mark, best bid and ask from the book, the configured funding rate and the next funding
    boundary. [None] for an unknown symbol or one without any price yet. *)
val ticker
  :  Exchange.t
  -> last_price:Price.t option
  -> Symbol.t
  -> Tickers.Ticker.t option

val ws_ticker_data : Tickers.Ticker.t -> Ws_ticker.Data.t

(** The fields of [next] that differ from [prev] (with [symbol]); [None] if nothing
    changed. *)
val ticker_delta : prev:Ws_ticker.Data.t -> Ws_ticker.Data.t -> Ws_ticker.Data.t option

(** Size of the position closed by a fill, [None] when it only opened or increased. *)
val closed_size : Exchange_core_engine.Position.Change.t -> Size.t -> Size.t option

(** One account's execution. [order_id] is the Bybit id of the account's order; [fee_rate]
    the rate actually charged. *)
val execution
  :  ?category:Category.t
  -> order_id:Order_id.t
  -> fee_rate:Decimal.t
  -> Exchange_core_engine.Execution.t
  -> Execution.t

(** A one-way position. [cum_realised_pnl] is closed PnL minus funding minus [cum_fees];
    [created_time] and [updated_time] are [time] (ns). *)
val position
  :  ?category:Category.t
  -> cum_fees:Usd.t
  -> mark:Price.t
  -> time:int
  -> Exchange_core.Position_view.t
  -> Position.t

(** An empty position ([side = ""], size 0), as Bybit returns for a queried symbol without
    a position. *)
val flat_position
  :  ?category:Category.t
  -> mark:Price.t
  -> time:int
  -> Symbol.t
  -> Position.t

(** The [UNIFIED] account with a single USDT coin entry. *)
val wallet : Exchange_core.Account_view.t -> Wallet_balance.Account.t
