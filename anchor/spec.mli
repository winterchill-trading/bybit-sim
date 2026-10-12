(** One [-anchor] argument: [<venue>:<symbol>=<sim-symbol>], e.g.
    [binance:BTCUSDT=BTCUSDT]. The reference is a market on any venue (its own symbol
    spelling); the simulated symbol is one of the simulator's instruments. *)

open! Core
open! Exchange_core

type t =
  { reference : Market_data.Instrument.t
  ; sim_symbol : Symbol.t
  }
[@@deriving sexp_of, compare, equal]

val of_string : string -> t Or_error.t

(** ["binance:BTCUSDT=BTCUSDT"]. *)
val to_string : t -> string

val arg_type : t Command.Arg_type.t
