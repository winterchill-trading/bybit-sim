(** The Bybit exchange state around the engine: the engine itself, the {!Orders} registry,
    last trade prices and per-symbol book sequence numbers, and the REST endpoints in
    {!Bybit_protocol} types.

    Every operation that touches the engine drains its events right away, applies them to
    the registry and buffers them, with the changed orders and public trades, until
    {!drain}. Anything else that mutates the engine (clock steps, the market simulation)
    must be followed by {!sync}. *)

open! Core
open! Bybit_protocol
module Exchange := Exchange_core_engine.Exchange
module Account := Exchange_core.Account
module Api_error := Adapt.Api_error

type t

val create : Exchange.t -> t
val exchange : t -> Exchange.t
val orders : t -> Orders.t

(** {2 Events} *)

module Output : sig
  type t =
    { events : Exchange_core_engine.Event.t list (** oldest first *)
    ; orders : Orders.Order.t list
    (** orders that changed, in order of change; an order appears once, in its latest
        state *)
    ; trades : Public_trade.Trade.t list (** oldest first *)
    }
end

(** Drains the engine's events into the buffer. *)
val sync : t -> unit

(** The last 50 guard events of the price collar and the halt rule, oldest first. {!sync}
    drains them from the engine and logs each one. *)
val guard_events : t -> Exchange_core_engine.Guard_event.t list

(** Syncs, then returns and clears the buffer. *)
val drain : t -> Output.t

(** {2 Market data} *)

(** Incremented on every event that changes the symbol's book. *)
val book_seq : t -> Symbol.t -> int

(** [limit] defaults to 25. [None] for an unknown symbol. *)
val orderbook : ?limit:int -> t -> Symbol.t -> Orderbook.t option

(** All instruments, or only [symbol] (an unknown symbol gives an empty list). *)
val tickers : ?symbol:Symbol.t -> t -> Tickers.t

(** {2 Trading} *)

val create_order
  :  t
  -> Account.t
  -> Create_order.Params.t
  -> (Order_ack.t, Api_error.t) Result.t

(** At most 20 orders, else 10001 for the whole request. Per-order results in request
    order. *)
val create_batch
  :  t
  -> Account.t
  -> Create_order.Params.t list
  -> (Create_batch.Response.t * Create_batch.Ext_info.t, Api_error.t) Result.t

val cancel_order
  :  t
  -> Account.t
  -> Cancel_order.Request.t
  -> (Order_ack.t, Api_error.t) Result.t

(** Needs [symbol], [baseCoin] or [settleCoin] ([USDT]). *)
val cancel_all
  :  t
  -> Account.t
  -> Cancel_all.Request.t
  -> (Cancel_all.Response.t, Api_error.t) Result.t

(** Keeps the order id. [qty] is the new total, filled part included. The engine re-places
    the order (losing time priority); if the replacement is rejected, the old remainder is
    restored, also with a new queue position, and the error returned. *)
val amend_order
  :  t
  -> Account.t
  -> Amend_order.Request.t
  -> (Order_ack.t, Api_error.t) Result.t

(** {2 Account queries} *)

(** Open orders, plus with [open_only:false] up to 500 recent closed ones; with [order_id]
    or [order_link_id] both. Newest first. *)
val realtime
  :  ?symbol:Symbol.t
  -> ?order_id:Order_id.t
  -> ?order_link_id:Order_link_id.t
  -> t
  -> Account.t
  -> open_only:bool
  -> limit:int
  -> Realtime_order.t list

(** Newest first. *)
val executions
  :  ?symbol:Symbol.t
  -> ?order_id:Order_id.t
  -> ?order_link_id:Order_link_id.t
  -> t
  -> Account.t
  -> limit:int
  -> Execution.t list

(** The execution of one account's side of a fill. *)
val execution
  :  ?category:Category.t
  -> t
  -> Exchange_core_engine.Execution.t
  -> Execution.t

(** Open positions sorted by symbol, or the position in [symbol] (flat if none). *)
val positions : ?symbol:Symbol.t -> t -> Account.t -> Position.t list

(** The position in one symbol (flat if none), as pushed on the [position] topic. *)
val position : ?category:Category.t -> t -> Account.t -> Symbol.t -> Position.t

val wallet : t -> Account.t -> Wallet_balance.Account.t
