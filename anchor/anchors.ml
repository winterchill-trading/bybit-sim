open! Core
open! Async
open! Exchange_core
open! Exchange_core_engine
module Anchor = Price_anchor.Anchor
module Server = Bybit_sim.Server

module Config = struct
  type t =
    { levels : int
    ; mark_interval : Time_ns.Span.t
    ; max_staleness : Time_ns.Span.t
    ; noise_traders : int
    ; price_factor : float
    ; size_factor : float
    ; speed : float
    }
  [@@deriving sexp_of]

  let default =
    { levels = 5
    ; mark_interval = Time_ns.Span.of_int_ms 100
    ; max_staleness = Time_ns.Span.of_int_sec 5
    ; noise_traders = 0
    ; price_factor = 1.
    ; size_factor = 1.
    ; speed = 1.
    }
  ;;
end

module Source = struct
  type t =
    | Live
    | Raw of
        { dir : string
        ; from : Time_ns.t
        ; to_ : Time_ns.t
        }
    | Norm of
        { dir : string
        ; from : Date.t
        ; to_ : Date.t
        }
    | Custom of ((Spec.t -> Price_anchor.Source.t Deferred.Or_error.t)[@sexp.opaque])
  [@@deriving sexp_of]

  let open_ t (spec : Spec.t) =
    match t with
    | Live ->
      let%map.Deferred.Or_error feed = Reference.live_feed spec.reference in
      Price_anchor.Source.of_feed feed
    | Raw { dir; from; to_ } ->
      return
        (let%map.Or_error normalizer = Reference.normalizer spec.reference.venue in
         Price_anchor.Source.of_raw
           ~dir
           ~symbol:(Market_data.Symbol.to_string spec.reference.symbol)
           ~from
           ~to_
           ~normalizer
           ())
    | Norm { dir; from; to_ } ->
      Price_anchor.Source.of_norm ~dir spec.reference ~from ~to_
    | Custom f -> f spec
  ;;

  (* A date or a time; [`Date] keeps a date apart so [to_] can mean its end. *)
  let parse_time s =
    match Date.of_string s with
    | date -> Ok (`Date date)
    | exception _ ->
      (match Time_ns.of_string_with_utc_offset s with
       | time -> Ok (`Time time)
       | exception _ -> Or_error.error_s [%message "expected a time or a UTC date" s])
  ;;

  let start_of_day date =
    Time_ns.of_date_ofday ~zone:Time_float.Zone.utc date Time_ns.Ofday.start_of_day
  ;;

  let date_of = function
    | `Date date -> date
    | `Time time -> Time_ns.to_date time ~zone:Time_float.Zone.utc
  ;;

  let of_flags ~raw ~norm ~from ~to_ =
    let open Or_error.Let_syntax in
    let range () =
      match from, to_ with
      | Some from, Some to_ ->
        let%bind from = parse_time from in
        let%map to_ = parse_time to_ in
        from, to_
      | _ ->
        Or_error.error_string
          "-anchor-raw and -anchor-norm need -anchor-from and -anchor-to"
    in
    match raw, norm with
    | None, None ->
      if Option.is_some from || Option.is_some to_
      then
        Or_error.error_string
          "-anchor-from and -anchor-to need -anchor-raw or -anchor-norm"
      else Ok Live
    | Some _, Some _ -> Or_error.error_string "-anchor-raw and -anchor-norm are exclusive"
    | Some dir, None ->
      let%map from, to_ = range () in
      let from =
        match from with
        | `Date date -> start_of_day date
        | `Time time -> time
      in
      let to_ =
        match to_ with
        | `Date date -> start_of_day (Date.add_days date 1)
        | `Time time -> time
      in
      Raw { dir; from; to_ }
    | None, Some dir ->
      let%map from, to_ = range () in
      Norm { dir; from = date_of from; to_ = date_of to_ }
  ;;
end

module Source_state = struct
  type t =
    | Waiting
    | Running
    | Done
    | Failed of Error.t

  let to_string = function
    | Waiting -> "waiting"
    | Running -> "running"
    | Done -> "done"
    | Failed _ -> "failed"
  ;;
end

module Entry = struct
  type t =
    { spec : Spec.t
    ; anchor : Anchor.t
    ; mutable source : Source_state.t
    }
end

type t =
  { config : Config.t
  ; server : Server.t
  ; entries : Entry.t list
  }

let path = "/sim/anchor"
let config t = t.config
let anchors t = List.map t.entries ~f:(fun e -> e.spec, e.anchor)

let check_specs exchange specs =
  let open Or_error.Let_syntax in
  let%bind () =
    List.find_map specs ~f:(fun (spec : Spec.t) ->
      Option.some_if
        (Option.is_none (Exchange.instrument exchange spec.sim_symbol))
        (Error.create_s
           [%message "unknown simulated symbol" ~anchor:(Spec.to_string spec)]))
    |> Option.value_map ~default:(Ok ()) ~f:Result.fail
  in
  match
    List.find_a_dup specs ~compare:(fun (a : Spec.t) b ->
      Symbol.compare a.sim_symbol b.sim_symbol)
  with
  | Some spec ->
    Or_error.error_s
      [%message "symbol anchored twice" ~symbol:(spec.sim_symbol : Symbol.t)]
  | None -> return ()
;;

let run_entry t source (e : Entry.t) =
  match%bind Source.open_ source e.spec with
  | Error err ->
    e.source <- Failed err;
    Log.Global.error_s
      [%message "anchor source failed" ~anchor:(Spec.to_string e.spec) ~_:(err : Error.t)];
    return ()
  | Ok items ->
    e.source <- Running;
    let speed =
      match source with
      | Raw _ | Norm _ -> t.config.speed
      | Live | Custom _ -> 0.
    in
    let%map () =
      Price_anchor.Source.run ~speed items ~anchor:e.anchor ~on_item:(fun _ ->
        Server.mutate t.server ~f:ignore)
    in
    e.source <- Done;
    Log.Global.info_s [%message "anchor source ended" ~anchor:(Spec.to_string e.spec)]
;;

let run t source = Deferred.List.iter ~how:`Parallel t.entries ~f:(run_entry t source)

let stale_reason (stats : Anchor.Stats.t) =
  Option.map stats.stale ~f:(fun r ->
    match r with
    | Waiting_for_book -> "waiting_for_book"
    | Silent -> "silent"
    | Gap reason -> "gap: " ^ Sexp.to_string [%sexp (reason : Market_data.Gap.Reason.t)])
;;

let stale_seconds (stats : Anchor.Stats.t) = Float.of_int stats.stale_ns /. 1e9
let string_option = Option.value_map ~default:`Null ~f:(fun s -> `String s)

let status t =
  `Assoc
    [ ( "anchors"
      , `List
          (List.map t.entries ~f:(fun e ->
             let stats = Anchor.stats e.anchor in
             `Assoc
               [ "reference", `String (Market_data.Instrument.to_string e.spec.reference)
               ; "symbol", `String (Symbol.to_string e.spec.sim_symbol)
               ; "source", `String (Source_state.to_string e.source)
               ; ( "source_error"
                 , match e.source with
                   | Failed err -> `String (Error.to_string_hum err)
                   | Waiting | Running | Done -> `Null )
               ; "fresh", `Bool (Option.is_none stats.stale)
               ; "stale_reason", string_option (stale_reason stats)
               ; "stale_seconds", `Float (stale_seconds stats)
               ; "went_stale", `Int stats.went_stale
               ; "gaps", `Int stats.gaps
               ; "events", `Int stats.events
               ; ( "reference_price"
                 , string_option
                     (Option.map (Anchor.reference_price e.anchor) ~f:Price.to_string) )
               ; "shadow_levels", `Int (List.length (Anchor.shadow_orders e.anchor))
               ; "replay_fills", `Int stats.replays
               ; "replays_rejected", `Int stats.replays_rejected
               ; "marks_set", `Int stats.marks_set
               ])) )
    ]
;;

let summary t =
  [%sexp
    (List.map t.entries ~f:(fun e ->
       let stats = Anchor.stats e.anchor in
       [%message
         ""
           ~anchor:(Spec.to_string e.spec)
           ~source:(Source_state.to_string e.source)
           ~stale:(stale_reason stats : string option)
           ~stale_seconds:(stale_seconds stats : float)
           ~events:(stats.events : int)
           ~price:(Anchor.reference_price e.anchor : Price.t option)
           ~shadow_levels:(List.length (Anchor.shadow_orders e.anchor) : int)
           ~replay_fills:(stats.replays : int)])
     : Sexp.t list)]
;;

let create ?(config = Config.default) ?market_sim server specs =
  let exchange = Bybit_sim.Venue.exchange (Server.venue server) in
  let%map.Or_error () = check_specs exchange specs in
  let entries =
    Server.mutate server ~f:(fun _ ->
      List.map specs ~f:(fun spec ->
        let name = Spec.to_string spec in
        let anchor =
          Anchor.create
            ~price_factor:config.price_factor
            ~size_factor:config.size_factor
            ~levels:config.levels
            ~mark_interval:config.mark_interval
            ~max_staleness:config.max_staleness
            ~noise_traders:config.noise_traders
            ~log:(fun s -> Log.Global.info_s [%message "anchor" name ~_:(s : Sexp.t)])
            ?market_sim
            ~exchange
            ~reference:spec.reference
            ~sim_symbol:spec.sim_symbol
            ()
        in
        { Entry.spec; anchor; source = Waiting }))
  in
  let t = { config; server; entries } in
  Server.on_step server (fun ~now ->
    List.iter entries ~f:(fun e -> Anchor.step e.anchor ~now));
  Server.add_route server ~path (fun () -> status t);
  t
;;
