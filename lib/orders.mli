(** Bybit's view of the orders placed through the simulator: what the engine does not keep
    (order type, time in force, original qty, cumulative execution, closed PnL, status,
    reject reason) and Bybit order ids that stay the same across amends, although the
    engine re-places an amended order under a new engine id.

    The Bybit id of an order is its first engine id in decimal, or, for an order that the
    engine rejected before assigning one (post-only crossing, nothing to fill), a
    UUID-shaped id from a separate counter.

    Orders are registered by {!placed} right after [Exchange.place] returns and before the
    events of that call are passed to {!apply}. Events of orders that were never
    registered (e.g. the market simulation's) are ignored. *)

open! Core
open! Bybit_protocol

module Order : sig
  type t

  val id : t -> Order_id.t
  val account : t -> Exchange_core.Account.t
  val symbol : t -> Symbol.t
  val side : t -> Side.t
  val order_link_id : t -> Order_link_id.t option
  val order_type : t -> Order_type.t
  val time_in_force : t -> Time_in_force.t
  val price : t -> Price.t
  val qty : t -> Size.t
  val cum_exec_qty : t -> Size.t

  (** [qty - cum_exec_qty] while open, else zero. *)
  val leaves_qty : t -> Size.t

  val status : t -> Order_status.t
  val is_open : t -> bool

  (** The engine id of the order's current incarnation. *)
  val engine_oid : t -> Exchange_core.Order_id.t option

  (** The REST encoding, or with [~ws:true] the [order] topic's (adds [category] and
      [closedPnl]). *)
  val to_realtime : ?ws:bool -> t -> Realtime_order.t
end

type t

(** Up to [closed_history] (default 500) closed orders are kept per account. *)
val create : ?closed_history:int -> unit -> t

(** Registers an order that the engine accepted (rested or filled) under [engine_oid]. *)
val placed
  :  t
  -> Exchange_core.Account.t
  -> Create_order.Params.t
  -> Exchange_core.Order_id.t
  -> time:int
  -> Order.t

(** Records an order that Bybit would accept and cancel at once with [reason]; it is
    closed from the start. *)
val rejected
  :  t
  -> Exchange_core.Account.t
  -> Create_order.Params.t
  -> Reject_reason.t
  -> time:int
  -> Order.t

(** Records that an open order now lives under [engine_oid] with total [qty] (filled part
    included) and limit [price]. Call it before applying the events of the replacement. *)
val amended
  :  t
  -> Order.t
  -> engine_oid:Exchange_core.Order_id.t
  -> qty:Size.t
  -> price:Price.t
  -> time:int
  -> unit

(** Marks an open order cancelled outside the event flow (an amend whose replacement and
    restore both failed). *)
val cancelled : t -> Order.t -> time:int -> unit

(** Applies an engine event; returns the registered orders it changed, in order. Cancels
    caused by a modify are ignored (see {!amended}). *)
val apply : t -> Exchange_core_engine.Event.t -> Order.t list

(** Open orders of the account, newest first. *)
val open_orders : t -> Exchange_core.Account.t -> Order.t list

(** Closed orders of the account, newest first. *)
val closed_orders : t -> Exchange_core.Account.t -> Order.t list

(** An open order of the account by Bybit id or [orderLinkId]. *)
val find_open
  :  t
  -> Exchange_core.Account.t
  -> [ `Id of Order_id.t | `Link of Order_link_id.t ]
  -> Order.t option

(** The Bybit id of the order an engine id belongs to (the engine id itself unless the
    order was amended). *)
val order_id : t -> Exchange_core.Order_id.t -> Order_id.t
