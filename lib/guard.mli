(** The engine's price collar and halt rule as simulator settings: the command-line flags,
    how they are applied to the exchange, Bybit's view of their rejections and the
    [GET /sim/guard] status.

    Both are off unless a flag turns them on, so a run without the flags behaves exactly
    as before. *)

open! Core
open! Bybit_protocol
module Exchange := Exchange_core_engine.Exchange
module Price_collar := Exchange_core_engine.Price_collar
module Halt_rule := Exchange_core_engine.Halt_rule
module Guard_event := Exchange_core_engine.Guard_event

module Config : sig
  type t =
    { collar : Price_collar.Config.t option (** set on every instrument *)
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of, equal]

  (** No collar, no halt rule. *)
  val off : t

  (** The settings from the flags' values. [-collar-reference], [-collar-action] need a
      band ([-collar-bps] or [-collar-ticks], not both); [-halt-scope] needs
      [-halt-levels]. The reference defaults to the mark when [anchored], else the last
      trade. The halt rule watches every symbol's mark and reopens automatically, except
      after a level without a duration, which waits for [POST /sim/reopen]. *)
  val of_flags
    :  ?collar_bps:int
    -> ?collar_ticks:int
    -> ?collar_reference:string
    -> ?collar_action:string
    -> ?halt_levels:string
    -> ?halt_scope:string
    -> anchored:bool
    -> unit
    -> t Or_error.t

  (** The flags [-collar-bps], [-collar-ticks], [-collar-reference], [-collar-action],
      [-halt-levels] and [-halt-scope]; apply the result to whether the run is anchored. *)
  val param : (anchored:bool -> t Or_error.t) Command.Param.t
end

(** Halt levels from ["7:15m,13:15m,20:reopen"]: a move in percent of the session
    reference (decimals allowed) and how long trading halts, a span ([30s], [15m], [1h])
    or [reopen] (until {!Exchange.reopen}). *)
val parse_levels : string -> Halt_rule.Level.t list Or_error.t

(** Sets the collar on every instrument and the halt rule, through the engine's recorded
    calls (an input journal attached before keeps them). Does nothing for {!Config.off}. *)
val apply : Config.t -> Exchange.t -> unit Or_error.t

(** The collar rejection counter, read before an order goes to the engine for
    {!rejection}. *)
val collar_rejected : Exchange.t -> int

(** How Bybit reports a rejection of an order on [symbol] and [side]: an [Invalid_price]
    that raised the collar counter above [collar_rejected_before] is 110003 (price out of
    range, with the bound), a halt rejection is 10001; anything else is
    {!Adapt.rejection}. *)
val rejection
  :  Exchange.t
  -> collar_rejected_before:int
  -> symbol:Symbol.t
  -> side:Side.t
  -> Exchange_core.Reject_reason.t
  -> Adapt.Rejection.t

val event_to_yojson : Guard_event.t -> Yojson.Safe.t

(** [{"collar", "halt_rule", "symbols", "stats", "recent"}]: the settings, each symbol's
    collar reference, session reference and halt, the counters and [recent] events (oldest
    first). *)
val status : ?recent:Guard_event.t list -> Exchange.t -> Yojson.Safe.t
