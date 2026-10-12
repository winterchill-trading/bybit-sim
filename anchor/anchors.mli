(** The anchors of one running simulator: one {!Price_anchor.Anchor.t} per [-anchor]
    argument, wired into the {!Bybit_sim.Server}.

    - Every {!Bybit_sim.Server.mutate} steps the clock and then calls
      {!Price_anchor.Anchor.step} for each anchor (staleness, held-back marks, queue
      tracking of new client orders), on the scheduler thread.
    - Each reference item is applied by {!Price_anchor.Source.run} and followed by a
      [mutate], so the anchor's orders, fills and marks reach the websocket streams like
      any other change.
    - [GET /sim/anchor] ({!path}) answers {!status}; transitions between fresh and stale
      are logged at [info] as they happen. *)

open! Core
open! Async
open! Exchange_core_engine

module Config : sig
  type t =
    { levels : int (** shadow levels per side *)
    ; mark_interval : Time_ns.Span.t
    ; max_staleness : Time_ns.Span.t
    ; noise_traders : int
    (** noise traders kept on an anchored symbol (with a market simulation) *)
    ; price_factor : float
    ; size_factor : float
    ; speed : float
    (** pacing of recorded sources ([Raw], [Norm]): [1.] real time, [0.] no pacing; live
        and custom sources are never paced *)
    }
  [@@deriving sexp_of]

  (** 5 levels, 100ms, 5s, no noise traders, factors 1, speed 1. *)
  val default : t
end

(** Where the reference data comes from; the same kind for every anchor. *)
module Source : sig
  type t =
    | Live (** the reference venue's public stream, through its client *)
    | Raw of
        { dir : string (** the recorder's data directory, containing [raw/] *)
        ; from : Time_ns.t
        ; to_ : Time_ns.t
        }
    | Norm of
        { dir : string (** containing the normalized event logs *)
        ; from : Date.t
        ; to_ : Date.t
        }
    | Custom of (Spec.t -> Price_anchor.Source.t Deferred.Or_error.t)
    (** any other source, e.g. a test feed *)
  [@@deriving sexp_of]

  val open_ : t -> Spec.t -> Price_anchor.Source.t Deferred.Or_error.t

  (** The source chosen by the simulator's flags: [Live] without [raw] or [norm]. [from]
      and [to_] are required with either, as ISO 8601 times with a zone
      ([2026-10-12T15:05:00Z]) or UTC dates ([2026-10-12]). A [Raw] range is
      [[from, to_)], a date [to_] meaning the end of that day; a [Norm] range is the UTC
      days of [from] and [to_], inclusive. *)
  val of_flags
    :  raw:string option
    -> norm:string option
    -> from:string option
    -> to_:string option
    -> t Or_error.t
end

type t

(** Creates an anchor per spec. Fails on a simulated symbol the exchange does not list or
    a symbol anchored twice. With [market_sim], anchored symbols keep
    [config.noise_traders] noise traders and are handed back to them while stale. *)
val create
  :  ?config:Config.t
  -> ?market_sim:Market_sim.t
  -> Bybit_sim.Server.t
  -> Spec.t list
  -> t Or_error.t

val config : t -> Config.t
val anchors : t -> (Spec.t * Price_anchor.Anchor.t) list

(** Opens every anchor's source and applies it until it ends. A source that fails to open
    is logged and marked failed in {!status}; the others run. Determined when every source
    has ended. *)
val run : t -> Source.t -> unit Deferred.t

(** ["/sim/anchor"]. *)
val path : string

(** Per anchor: reference, simulated symbol, source state ([waiting], [running], [done] or
    [failed]), [fresh], [stale_reason], [stale_seconds] (simulated time spent stale),
    [went_stale], [gaps], [events], [reference_price], [shadow_levels] resting,
    [replay_fills], [replays_rejected], [marks_set]. *)
val status : t -> Yojson.Safe.t

(** One line per anchor, for the periodic log. *)
val summary : t -> Sexp.t

(** Logs {!summary} at [info] every [span]. *)
val log_summary_every : t -> Time_ns.Span.t -> unit
