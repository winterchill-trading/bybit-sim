open! Core
open! Exchange_core

type t =
  { reference : Market_data.Instrument.t
  ; sim_symbol : Symbol.t
  }
[@@deriving sexp_of, compare, equal]

let of_string s =
  match String.lsplit2 s ~on:'=' with
  | None | Some (_, "") ->
    Or_error.error_s
      [%message "expected <venue>:<symbol>=<sim-symbol>" ~anchor:(s : string)]
  | Some (reference, sim_symbol) ->
    let%map.Or_error reference =
      Or_error.try_with (fun () -> Market_data.Instrument.of_string reference)
      |> Or_error.tag_s ~tag:[%message "bad reference" ~anchor:(s : string)]
    in
    { reference; sim_symbol = Symbol.of_string sim_symbol }
;;

let to_string t =
  Market_data.Instrument.to_string t.reference ^ "=" ^ Symbol.to_string t.sim_symbol
;;

let arg_type = Command.Arg_type.create (fun s -> ok_exn (of_string s))
