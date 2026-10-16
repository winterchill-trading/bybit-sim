(* The price collar and the halt rule through the HTTP handler: Bybit's codes for their
   rejections, the [/sim/guard] status, [/sim/reopen], and journal replays reproducing the
   guard events. *)

open! Core
open! Bybit_sim
module Exchange = Exchange_core_engine.Exchange
module Price_collar = Exchange_core_engine.Price_collar
module Halt_rule = Exchange_core_engine.Halt_rule

let start = 1_700_000_000_000_000_000
let btc = Exchange_core.Symbol.of_string "BTCUSDT"

type sim =
  { server : Server.t
  ; exchange : Exchange.t
  ; clock : int ref
  ; inputs : Exchange_core_engine.Input.t Queue.t
  }

let create (guard : Guard.Config.t) =
  Async.Log.Global.set_output [];
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  Guard.apply guard exchange |> ok_exn;
  let clock = ref start in
  let server = Server.create ~now:(fun () -> !clock) exchange in
  { server; exchange; clock; inputs }
;;

let request ?(print = true) sim meth path body =
  let status, json =
    Server.handle_http
      sim.server
      ~meth
      ~uri:(Uri.of_string path)
      ~headers:
        (Cohttp.Header.of_list
           [ "X-BAPI-API-KEY", "k"
           ; "X-BAPI-TIMESTAMP", Int.to_string (!(sim.clock) / 1_000_000)
           ; "X-BAPI-SIGN", "unchecked"
           ])
      ~body
  in
  if print
  then (
    let json =
      match json with
      | `Assoc fields ->
        `Assoc
          (List.filter_map fields ~f:(fun (k, v) ->
             match k with
             | "retCode" | "retMsg" -> Some (k, v)
             | "result" | "retExtInfo" | "time" -> None
             | _ -> Some (k, v)))
      | json -> json
    in
    printf
      "%d %s\n"
      (Cohttp.Code.code_of_status status)
      (Yojson.Safe.pretty_to_string json))
;;

let order ?print ?(key = "k") sim ~side ~px ~qty =
  let status, json =
    Server.handle_http
      sim.server
      ~meth:`POST
      ~uri:(Uri.of_string "/v5/order/create")
      ~headers:
        (Cohttp.Header.of_list
           [ "X-BAPI-API-KEY", key
           ; "X-BAPI-TIMESTAMP", Int.to_string (!(sim.clock) / 1_000_000)
           ; "X-BAPI-SIGN", "unchecked"
           ])
      ~body:
        (sprintf
           {|{"category":"linear","symbol":"BTCUSDT","side":"%s","orderType":"Limit","qty":"%s","price":"%s","timeInForce":"GTC"}|}
           side
           qty
           px)
  in
  ignore (status : Cohttp.Code.status_code);
  if Option.value print ~default:true
  then (
    let field k = Yojson.Safe.Util.member k json in
    printf
      "%s %s: %s %s\n"
      side
      px
      (Yojson.Safe.to_string (field "retCode"))
      (Yojson.Safe.to_string (field "retMsg")))
;;

let guard_status sim = request sim `GET "/sim/guard" ""

(* BTCUSDT's halt and the counters from [/sim/guard]. *)
let guard_summary sim =
  let _, json =
    Server.handle_http
      sim.server
      ~meth:`GET
      ~uri:(Uri.of_string "/sim/guard")
      ~headers:(Cohttp.Header.init ())
      ~body:""
  in
  let open Yojson.Safe.Util in
  let btc = json |> member "symbols" |> index 0 in
  printf
    "halt %s, stats %s\n"
    (Yojson.Safe.to_string (member "halt" btc))
    (Yojson.Safe.to_string (member "stats" json))
;;

let set_mark sim px =
  Server.mutate sim.server ~f:(fun _ ->
    Exchange.set_mark sim.exchange btc (Exchange_core.Price.of_string px))
;;

(* A trade at 60000 for the last price, then asks at 60200 and 60350 and bids at 59800 and
   59650 from another account. *)
let seed_book sim =
  order ~print:false ~key:"maker" sim ~side:"Sell" ~px:"60000" ~qty:"0.01";
  order ~print:false ~key:"taker" sim ~side:"Buy" ~px:"60000" ~qty:"0.01";
  List.iter
    [ "Sell", "60200"; "Sell", "60350"; "Buy", "59800"; "Buy", "59650" ]
    ~f:(fun (side, px) -> order ~print:false ~key:"maker" sim ~side ~px ~qty:"0.01")
;;

let collar action : Guard.Config.t =
  { collar = Some { reference = Last_trade; band = Bps 50; action }; halt_rule = None }
;;

let%expect_test "flags" =
  let show
    ?collar_bps
    ?collar_ticks
    ?collar_reference
    ?collar_action
    ?halt_levels
    ?halt_scope
    ?(anchored = false)
    ()
    =
    print_s
      [%sexp
        (Guard.Config.of_flags
           ?collar_bps
           ?collar_ticks
           ?collar_reference
           ?collar_action
           ?halt_levels
           ?halt_scope
           ~anchored
           ()
         : Guard.Config.t Or_error.t)]
  in
  show ();
  [%expect {| (Ok ((collar ()) (halt_rule ()))) |}];
  show ~collar_bps:50 ();
  show ~collar_bps:50 ~anchored:true ();
  show ~collar_ticks:20 ~collar_reference:"mid" ~collar_action:"reprice" ();
  [%expect
    {|
    (Ok
     ((collar (((reference Last_trade) (band (Bps 50)) (action Reject))))
      (halt_rule ())))
    (Ok
     ((collar (((reference Mark) (band (Bps 50)) (action Reject))))
      (halt_rule ())))
    (Ok
     ((collar (((reference Mid) (band (Ticks 20)) (action Reprice))))
      (halt_rule ())))
    |}];
  show ~halt_levels:"7:15m,13.5:1h,20:reopen" ~halt_scope:"symbol" ();
  [%expect
    {|
    (Ok
     ((collar ())
      (halt_rule
       (((levels
          (((move_bps 700) (duration_ns (900000000000)))
           ((move_bps 1350) (duration_ns (3600000000000)))
           ((move_bps 2000) (duration_ns ()))))
         (scope Per_symbol) (watch ()) (observe Mark) (reopen Automatic))))))
    |}];
  show ~collar_bps:50 ~collar_ticks:3 ();
  show ~collar_action:"reject" ();
  show ~halt_scope:"market" ();
  show ~collar_bps:0 ();
  show ~collar_bps:5 ~collar_reference:"oracle" ();
  show ~halt_levels:"13:15m,7:15m" ();
  show ~halt_levels:"7" ();
  [%expect
    {|
    (Error "-collar-bps and -collar-ticks exclude each other")
    (Error
     "-collar-reference and -collar-action need -collar-bps or -collar-ticks")
    (Error "-halt-scope needs -halt-levels")
    (Error
     ("Price_collar: band must be positive"
      (t ((reference Last_trade) (band (Bps 0)) (action Reject)))))
    (Error ("-collar-reference must be last, mid or mark" oracle))
    (Error
     ("Halt_rule: invalid levels"
      (t
       ((levels
         (((move_bps 1300) (duration_ns (900000000000)))
          ((move_bps 700) (duration_ns (900000000000)))))
        (scope Market_wide) (watch ()) (observe Mark) (reopen Automatic)))))
    (Error ("halt level is not PERCENT:DURATION" 7))
    |}]
;;

let%expect_test "collar rejections are 110003, inside the band orders trade" =
  let sim = create (collar Reject) in
  seed_book sim;
  order sim ~side:"Buy" ~px:"60400" ~qty:"0.01";
  order sim ~side:"Sell" ~px:"59600" ~qty:"0.01";
  order sim ~side:"Buy" ~px:"60250" ~qty:"0.01";
  (* Passive orders beyond the band rest. *)
  order sim ~side:"Buy" ~px:"50000" ~qty:"0.01";
  [%expect
    {|
    Buy 60400: 110003 "Order price exceeds the allowable range: max buy price 60300."
    Sell 59600: 110003 "Order price exceeds the allowable range: min sell price 59700."
    Buy 60250: 0 "OK"
    Buy 50000: 0 "OK"
    |}];
  guard_status sim;
  [%expect
    {|
    200 {
      "collar": { "band_bps": 50, "reference": "last", "action": "reject" },
      "halt_rule": null,
      "symbols": [
        {
          "symbol": "BTCUSDT",
          "collar_reference": "60200",
          "session_reference": null,
          "halt": null
        },
        {
          "symbol": "ETHUSDT",
          "collar_reference": null,
          "session_reference": null,
          "halt": null
        },
        {
          "symbol": "SOLUSDT",
          "collar_reference": null,
          "session_reference": null,
          "halt": null
        }
      ],
      "stats": {
        "collar_rejected": 2,
        "collar_repriced": 0,
        "collar_unreferenced": 2,
        "halt_rejected": 0,
        "halts": 0,
        "reopens": 0
      },
      "recent": [
        {
          "time_ms": 1700000000000,
          "symbol": "BTCUSDT",
          "kind": "collar_rejected",
          "side": "Buy",
          "limit_px": "60400",
          "reference": "60000",
          "bound": "60300",
          "account": "k",
          "order_id": "7"
        },
        {
          "time_ms": 1700000000000,
          "symbol": "BTCUSDT",
          "kind": "collar_rejected",
          "side": "Sell",
          "limit_px": "59600",
          "reference": "60000",
          "bound": "59700",
          "account": "k",
          "order_id": "8"
        }
      ]
    }
    |}]
;;

let%expect_test "an amend beyond the band is 110003 and keeps the order" =
  let sim = create (collar Reject) in
  seed_book sim;
  let call path body =
    let _, json =
      Server.handle_http
        sim.server
        ~meth:`POST
        ~uri:(Uri.of_string path)
        ~headers:
          (Cohttp.Header.of_list
             [ "X-BAPI-API-KEY", "k"
             ; "X-BAPI-TIMESTAMP", Int.to_string (!(sim.clock) / 1_000_000)
             ; "X-BAPI-SIGN", "unchecked"
             ])
        ~body
    in
    json
  in
  let created =
    call
      "/v5/order/create"
      {|{"category":"linear","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","qty":"0.01","price":"59000"}|}
  in
  let order_id =
    Yojson.Safe.Util.(created |> member "result" |> member "orderId" |> to_string)
  in
  let amended =
    call
      "/v5/order/amend"
      (sprintf
         {|{"category":"linear","symbol":"BTCUSDT","orderId":"%s","price":"60400"}|}
         order_id)
  in
  let open Yojson.Safe.Util in
  printf
    "%s %s\n"
    (Yojson.Safe.to_string (member "retCode" amended))
    (Yojson.Safe.to_string (member "retMsg" amended));
  print_s
    [%sexp
      (Exchange.open_orders sim.exchange (Exchange_core.Account.of_string "k")
       |> List.map ~f:(fun (o : Exchange_core.Open_order.t) -> o.px)
       : Exchange_core.Price.t list)];
  [%expect
    {|
    110003 "Order price exceeds the allowable range: max buy price 60300."
    (59000)
    |}]
;;

let%expect_test "re-pricing stops the order at the band" =
  let sim = create (collar Reprice) in
  seed_book sim;
  order sim ~side:"Buy" ~px:"60400" ~qty:"0.02";
  [%expect {| Buy 60400: 0 "OK" |}];
  print_s
    [%sexp (Exchange.guard_stats sim.exchange : Exchange_core_engine.Guard_event.Stats.t)];
  [%expect
    {|
    ((collar_rejected 0) (collar_repriced 1) (collar_unreferenced 2)
     (halt_rejected 0) (halts 0) (reopens 0))
    |}]
;;

let halt_rule : Guard.Config.t =
  { collar = None
  ; halt_rule =
      Some
        { levels =
            [ { move_bps = 700
              ; duration_ns = Some (Time_ns.Span.to_int_ns (Time_ns.Span.of_min 15.))
              }
            ; { move_bps = 1300; duration_ns = None }
            ]
        ; scope = Market_wide
        ; watch = []
        ; observe = Mark
        ; reopen = Automatic
        }
  }
;;

let run_halts sim =
  set_mark sim "60000";
  seed_book sim;
  set_mark sim "64500";
  order sim ~side:"Buy" ~px:"60200" ~qty:"0.01";
  (* Passive orders rest during a halt. *)
  order sim ~side:"Buy" ~px:"59000" ~qty:"0.01";
  guard_status sim;
  sim.clock := !(sim.clock) + Time_ns.Span.to_int_ns (Time_ns.Span.of_min 16.);
  (* The 15 minute halt has lifted at the clock step. *)
  order sim ~side:"Buy" ~px:"60200" ~qty:"0.01";
  set_mark sim "68000";
  order sim ~side:"Sell" ~px:"59800" ~qty:"0.01";
  guard_summary sim;
  request sim `POST "/sim/reopen?symbol=XYZUSDT" "";
  request ~print:false sim `POST "/sim/reopen" "";
  guard_summary sim;
  order sim ~side:"Sell" ~px:"59800" ~qty:"0.01"
;;

let%expect_test "halts reject with 10001 until they lift or reopen" =
  let sim = create halt_rule in
  run_halts sim;
  [%expect
    {|
    Buy 60200: 10001 "params error: symbol is halted"
    Buy 59000: 0 "OK"
    200 {
      "collar": null,
      "halt_rule": {
        "levels": [
          { "move_bps": 700, "duration_s": 900 },
          { "move_bps": 1300, "duration_s": null }
        ],
        "scope": "market"
      },
      "symbols": [
        {
          "symbol": "BTCUSDT",
          "collar_reference": null,
          "session_reference": "60000",
          "halt": { "until_ms": 1700000900000 }
        },
        {
          "symbol": "ETHUSDT",
          "collar_reference": null,
          "session_reference": null,
          "halt": { "until_ms": 1700000900000 }
        },
        {
          "symbol": "SOLUSDT",
          "collar_reference": null,
          "session_reference": null,
          "halt": { "until_ms": 1700000900000 }
        }
      ],
      "stats": {
        "collar_rejected": 0,
        "collar_repriced": 0,
        "collar_unreferenced": 0,
        "halt_rejected": 1,
        "halts": 3,
        "reopens": 0
      },
      "recent": [
        {
          "time_ms": 1700000000000,
          "symbol": "BTCUSDT",
          "kind": "halted",
          "trigger_symbol": "BTCUSDT",
          "level": 0,
          "reference": "60000",
          "px": "64500",
          "move_bps": 750,
          "until_ms": 1700000900000
        },
        {
          "time_ms": 1700000000000,
          "symbol": "ETHUSDT",
          "kind": "halted",
          "trigger_symbol": "BTCUSDT",
          "level": 0,
          "reference": "60000",
          "px": "64500",
          "move_bps": 750,
          "until_ms": 1700000900000
        },
        {
          "time_ms": 1700000000000,
          "symbol": "SOLUSDT",
          "kind": "halted",
          "trigger_symbol": "BTCUSDT",
          "level": 0,
          "reference": "60000",
          "px": "64500",
          "move_bps": 750,
          "until_ms": 1700000900000
        },
        {
          "time_ms": 1700000000000,
          "symbol": "BTCUSDT",
          "kind": "halt_rejected",
          "side": "Buy",
          "account": "k",
          "order_id": "7"
        }
      ]
    }
    Buy 60200: 0 "OK"
    Sell 59800: 10001 "params error: symbol is halted"
    halt "until_reopen", stats {"collar_rejected":0,"collar_repriced":0,"collar_unreferenced":0,"halt_rejected":2,"halts":6,"reopens":3}
    400 { "error": "unknown symbol XYZUSDT" }
    halt null, stats {"collar_rejected":0,"collar_repriced":0,"collar_unreferenced":0,"halt_rejected":2,"halts":6,"reopens":6}
    Sell 59800: 0 "OK"
    |}]
;;

let%expect_test "journal replay reproduces the guard events" =
  let sim = create { collar = (collar Reject).collar; halt_rule = halt_rule.halt_rule } in
  set_mark sim "60000";
  seed_book sim;
  order ~print:false sim ~side:"Buy" ~px:"60400" ~qty:"0.01";
  set_mark sim "64500";
  order ~print:false sim ~side:"Buy" ~px:"60200" ~qty:"0.01";
  sim.clock := !(sim.clock) + Time_ns.Span.to_int_ns (Time_ns.Span.of_min 16.);
  set_mark sim "68000";
  request ~print:false sim `POST "/sim/reopen" "";
  let live = Server.venue sim.server |> Venue.guard_events in
  let journal = Exchange_core_engine.Journal.to_string (Queue.to_list sim.inputs) in
  let replayed =
    Exchange_core_engine.Journal.replay
      ~config:(Adapt.config ())
      (ok_exn (Exchange_core_engine.Journal.of_string journal))
  in
  let replayed_events = Exchange.drain_guard_events replayed in
  print_s
    [%message
      ""
        ~events:(List.length live : int)
        ~kinds:
          (List.map live ~f:(fun e -> e.kind)
           : Exchange_core_engine.Guard_event.Kind.t list)
        ~same_events:
          ([%equal: Exchange_core_engine.Guard_event.t list] live replayed_events : bool)
        ~same_stats:
          ([%equal: Exchange_core_engine.Guard_event.Stats.t]
             (Exchange.guard_stats sim.exchange)
             (Exchange.guard_stats replayed)
           : bool)];
  [%expect
    {|
    ((events 14)
     (kinds
      ((Collar_rejected (side Buy) (limit_px 60400) (reference 60000)
        (bound 60300))
       (Halted (trigger_symbol BTCUSDT) (level 0) (reference 60000) (px 64500)
        (move_bps 750) (until (1700000900000000000)))
       (Halted (trigger_symbol BTCUSDT) (level 0) (reference 60000) (px 64500)
        (move_bps 750) (until (1700000900000000000)))
       (Halted (trigger_symbol BTCUSDT) (level 0) (reference 60000) (px 64500)
        (move_bps 750) (until (1700000900000000000)))
       (Halt_rejected (side Buy)) Reopened Reopened Reopened
       (Halted (trigger_symbol BTCUSDT) (level 1) (reference 60000) (px 68000)
        (move_bps 1333) (until ()))
       (Halted (trigger_symbol BTCUSDT) (level 1) (reference 60000) (px 68000)
        (move_bps 1333) (until ()))
       (Halted (trigger_symbol BTCUSDT) (level 1) (reference 60000) (px 68000)
        (move_bps 1333) (until ()))
       Reopened Reopened Reopened))
     (same_events true) (same_stats true))
    |}]
;;
