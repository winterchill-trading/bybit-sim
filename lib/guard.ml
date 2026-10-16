open! Core
open! Bybit_protocol
module Exchange = Exchange_core_engine.Exchange
module Price_collar = Exchange_core_engine.Price_collar
module Halt_rule = Exchange_core_engine.Halt_rule
module Guard_event = Exchange_core_engine.Guard_event

let parse_level s : Halt_rule.Level.t Or_error.t =
  match String.lsplit2 (String.strip s) ~on:':' with
  | None -> Or_error.error_s [%message "halt level is not PERCENT:DURATION" s]
  | Some (pct, duration) ->
    Or_error.try_with_join (fun () ->
      let pct = Float.of_string (String.strip pct) in
      let move_bps = Float.iround_nearest_exn (pct *. 100.) in
      let duration_ns =
        match String.strip duration with
        | "reopen" -> None
        | span -> Some (Time_ns.Span.to_int_ns (Time_ns.Span.of_string span))
      in
      Ok { Halt_rule.Level.move_bps; duration_ns })
    |> Or_error.tag_s ~tag:[%message "invalid halt level" s]
;;

let parse_levels s =
  String.split s ~on:',' |> List.map ~f:parse_level |> Or_error.combine_errors
;;

let reference_of_string = function
  | "last" -> Ok Price_collar.Reference.Last_trade
  | "mid" -> Ok Mid
  | "mark" -> Ok Mark
  | s -> Or_error.error_s [%message "-collar-reference must be last, mid or mark" s]
;;

let action_of_string = function
  | "reject" -> Ok Price_collar.Action.Reject
  | "reprice" -> Ok Reprice
  | s -> Or_error.error_s [%message "-collar-action must be reject or reprice" s]
;;

let scope_of_string = function
  | "market" -> Ok Halt_rule.Scope.Market_wide
  | "symbol" -> Ok Per_symbol
  | s -> Or_error.error_s [%message "-halt-scope must be market or symbol" s]
;;

module Config = struct
  type t =
    { collar : Price_collar.Config.t option
    ; halt_rule : Halt_rule.Config.t option
    }
  [@@deriving sexp_of]

  let off = { collar = None; halt_rule = None }

  let of_flags
    ?collar_bps
    ?collar_ticks
    ?collar_reference
    ?collar_action
    ?halt_levels
    ?halt_scope
    ~anchored
    ()
    =
    let open Or_error.Let_syntax in
    let%bind collar =
      let band : Price_collar.Band.t option Or_error.t =
        match collar_bps, collar_ticks with
        | Some _, Some _ ->
          Or_error.error_string "-collar-bps and -collar-ticks exclude each other"
        | Some n, None -> Ok (Some (Bps n))
        | None, Some n -> Ok (Some (Ticks n))
        | None, None -> Ok None
      in
      match%bind band with
      | None ->
        if Option.is_some collar_reference || Option.is_some collar_action
        then
          Or_error.error_string
            "-collar-reference and -collar-action need -collar-bps or -collar-ticks"
        else Ok None
      | Some band ->
        let%bind reference =
          match collar_reference with
          | Some s -> reference_of_string s
          | None -> Ok (if anchored then Price_collar.Reference.Mark else Last_trade)
        in
        let%bind action =
          Option.value_map
            collar_action
            ~default:(Ok Price_collar.Action.Reject)
            ~f:action_of_string
        in
        let config = { Price_collar.Config.reference; band; action } in
        let%map () = Price_collar.Config.validate config in
        Some config
    in
    let%map halt_rule =
      match halt_levels with
      | None ->
        if Option.is_some halt_scope
        then Or_error.error_string "-halt-scope needs -halt-levels"
        else Ok None
      | Some levels ->
        let%bind levels = parse_levels levels in
        let%bind scope =
          Option.value_map
            halt_scope
            ~default:(Ok Halt_rule.Scope.Market_wide)
            ~f:scope_of_string
        in
        let config =
          { Halt_rule.Config.levels
          ; scope
          ; watch = []
          ; observe = Mark
          ; reopen = Automatic
          }
        in
        let%map () = Halt_rule.Config.validate config in
        Some config
    in
    { collar; halt_rule }
  ;;

  let param =
    let open Command.Let_syntax in
    let%map_open collar_bps =
      flag
        "-collar-bps"
        (optional int)
        ~doc:"N reject aggressive orders priced more than N bps from the collar reference"
    and collar_ticks =
      flag "-collar-ticks" (optional int) ~doc:"N the collar band in ticks instead of bps"
    and collar_reference =
      flag
        "-collar-reference"
        (optional string)
        ~doc:"REF last, mid or mark (default: mark when anchored, else last)"
    and collar_action =
      flag
        "-collar-action"
        (optional string)
        ~doc:"ACTION reject (default) or reprice: move the limit to the band"
    and halt_levels =
      flag
        "-halt-levels"
        (optional string)
        ~doc:
          "SPEC circuit breaker levels, e.g. 7:15m,13:15m,20:reopen (move in percent of \
           the session reference : halt duration, or reopen for POST /sim/reopen)"
    and halt_scope =
      flag
        "-halt-scope"
        (optional string)
        ~doc:
          "SCOPE market (default: halt every symbol) or symbol (only the one that moved)"
    in
    fun ~anchored ->
      of_flags
        ?collar_bps
        ?collar_ticks
        ?collar_reference
        ?collar_action
        ?halt_levels
        ?halt_scope
        ~anchored
        ()
  ;;
end

let apply (config : Config.t) ex =
  let open Or_error.Let_syntax in
  let%bind () =
    match config.collar with
    | None -> Ok ()
    | Some collar ->
      List.map (Exchange.instruments ex) ~f:(fun (i : Exchange_core.Instrument.t) ->
        Exchange.set_collar ex i.symbol (Some collar))
      |> Or_error.combine_errors_unit
  in
  match config.halt_rule with
  | None -> Ok ()
  | Some rule -> Exchange.set_halt_rule ex (Some rule)
;;

let collar_rejected ex = (Exchange.guard_stats ex).collar_rejected

let collar_error ex ~symbol ~side : Adapt.Api_error.t =
  let bound =
    match
      ( Exchange.collar ex symbol
      , Exchange.instrument ex symbol
      , Exchange.collar_reference ex symbol )
    with
    | Some config, Some instrument, Some reference ->
      Some (Price_collar.bound config instrument ~reference ~side)
    | _ -> None
  in
  let msg =
    match bound with
    | None -> "Order price exceeds the allowable range."
    | Some bound ->
      (match side with
       | Buy ->
         sprintf
           "Order price exceeds the allowable range: max buy price %s."
           (Price.to_string bound)
       | Sell ->
         sprintf
           "Order price exceeds the allowable range: min sell price %s."
           (Price.to_string bound))
  in
  { code = Price_out_of_range; msg }
;;

(* The engine's halt rejection; see [Exchange.halt_status]. *)
let halted_reason = "trading halted"

let rejection
  ex
  ~collar_rejected_before
  ~symbol
  ~side
  (reason : Exchange_core.Reject_reason.t)
  : Adapt.Rejection.t
  =
  match reason with
  | Invalid_price when collar_rejected ex > collar_rejected_before ->
    Api_error (collar_error ex ~symbol ~side)
  | Unsupported msg when String.equal msg halted_reason ->
    Api_error (Adapt.Api_error.params "params error: symbol is halted")
  | reason -> Adapt.rejection reason
;;

let ms ns = `Int (ns / 1_000_000)
let price px = `String (Price.to_string px)

let reference_to_string : Price_collar.Reference.t -> string = function
  | Last_trade -> "last"
  | Mid -> "mid"
  | Mark -> "mark"
;;

let kind_to_yojson : Guard_event.Kind.t -> (string * Yojson.Safe.t) list = function
  | Collar_rejected { side; limit_px; reference; bound } ->
    [ "kind", `String "collar_rejected"
    ; "side", `String (Side.to_wire side)
    ; "limit_px", price limit_px
    ; "reference", price reference
    ; "bound", price bound
    ]
  | Collar_repriced { side; limit_px; repriced_px; reference } ->
    [ "kind", `String "collar_repriced"
    ; "side", `String (Side.to_wire side)
    ; "limit_px", price limit_px
    ; "repriced_px", price repriced_px
    ; "reference", price reference
    ]
  | Halt_rejected { side } ->
    [ "kind", `String "halt_rejected"; "side", `String (Side.to_wire side) ]
  | Halted { trigger_symbol; level; reference; px; move_bps; until } ->
    [ "kind", `String "halted"
    ; "trigger_symbol", `String (Symbol.to_string trigger_symbol)
    ; "level", `Int level
    ; "reference", price reference
    ; "px", price px
    ; "move_bps", `Int move_bps
    ; "until_ms", Option.value_map until ~default:`Null ~f:ms
    ]
  | Reopen_pending -> [ "kind", `String "reopen_pending" ]
  | Reopened -> [ "kind", `String "reopened" ]
;;

let event_to_yojson (e : Guard_event.t) : Yojson.Safe.t =
  `Assoc
    ([ "time_ms", ms e.time; "symbol", `String (Symbol.to_string e.symbol) ]
     @ kind_to_yojson e.kind
     @ (match e.account with
        | None -> []
        | Some a -> [ "account", `String (Exchange_core.Account.to_string a) ])
     @
     match e.order_id with
     | None -> []
     | Some id -> [ "order_id", `String (Exchange_core.Order_id.to_string id) ])
;;

let collar_to_yojson : Price_collar.Config.t option -> Yojson.Safe.t = function
  | None -> `Null
  | Some { reference; band; action } ->
    `Assoc
      [ (match band with
         | Bps n -> "band_bps", `Int n
         | Ticks n -> "band_ticks", `Int n)
      ; "reference", `String (reference_to_string reference)
      ; ( "action"
        , `String
            (match action with
             | Reject -> "reject"
             | Reprice -> "reprice") )
      ]
;;

let halt_rule_to_yojson : Halt_rule.Config.t option -> Yojson.Safe.t = function
  | None -> `Null
  | Some rule ->
    `Assoc
      [ ( "levels"
        , `List
            (List.map rule.levels ~f:(fun (l : Halt_rule.Level.t) ->
               `Assoc
                 [ "move_bps", `Int l.move_bps
                 ; ( "duration_s"
                   , Option.value_map l.duration_ns ~default:`Null ~f:(fun ns ->
                       `Int (ns / 1_000_000_000)) )
                 ])) )
      ; ( "scope"
        , `String
            (match rule.scope with
             | Market_wide -> "market"
             | Per_symbol -> "symbol") )
      ]
;;

let stats_to_yojson (s : Guard_event.Stats.t) : Yojson.Safe.t =
  `Assoc
    [ "collar_rejected", `Int s.collar_rejected
    ; "collar_repriced", `Int s.collar_repriced
    ; "collar_unreferenced", `Int s.collar_unreferenced
    ; "halt_rejected", `Int s.halt_rejected
    ; "halts", `Int s.halts
    ; "reopens", `Int s.reopens
    ]
;;

let status ?(recent = []) ex : Yojson.Safe.t =
  let instruments = Exchange.instruments ex in
  let collar =
    List.find_map instruments ~f:(fun (i : Exchange_core.Instrument.t) ->
      Exchange.collar ex i.symbol)
  in
  let symbols =
    List.map instruments ~f:(fun (i : Exchange_core.Instrument.t) ->
      let opt f = Option.value_map ~default:`Null ~f in
      `Assoc
        [ "symbol", `String (Symbol.to_string i.symbol)
        ; "collar_reference", opt price (Exchange.collar_reference ex i.symbol)
        ; "session_reference", opt price (Exchange.session_reference ex i.symbol)
        ; ( "halt"
          , opt
              (function
                | `Until ns -> `Assoc [ "until_ms", ms ns ]
                | `Until_reopen -> `String "until_reopen"
                | `Reopen_pending -> `String "reopen_pending")
              (Exchange.halt_status ex i.symbol) )
        ])
  in
  `Assoc
    [ "collar", collar_to_yojson collar
    ; "halt_rule", halt_rule_to_yojson (Exchange.halt_rule ex)
    ; "symbols", `List symbols
    ; "stats", stats_to_yojson (Exchange.guard_stats ex)
    ; "recent", `List (List.map recent ~f:event_to_yojson)
    ]
;;
