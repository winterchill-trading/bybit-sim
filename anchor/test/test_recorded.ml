open! Core
open! Async
open! Exchange_core
open! Exchange_core_engine
open Bybit_sim
open Bybit_sim_anchor

(* One recorded minute of Bybit BTCUSDT (trades, orderbook.50, tickers), converted from
   bybit-client's test fixtures to the recorder's raw minute layout. *)
let dir = "fixtures"
let minute = Time_ns.of_string_with_utc_offset "2026-10-12T15:05:00Z"
let t0 = Time_ns.of_string_with_utc_offset "2026-10-12T15:05:18Z"
let spec = ok_exn (Spec.of_string "bybit:BTCUSDT=BTCUSDT")
let alice = Account.of_string "alice"

let place server ~side ~px ~qty =
  let status, json =
    Server.handle_http
      server
      ~meth:`POST
      ~uri:(Uri.of_string "/v5/order/create")
      ~headers:
        (Cohttp.Header.of_list
           [ "X-BAPI-API-KEY", Account.to_string alice
           ; ( "X-BAPI-TIMESTAMP"
             , Int.to_string (Time_ns.to_int_ns_since_epoch t0 / 1_000_000) )
           ])
      ~body:
        (sprintf
           {|{"category":"linear","symbol":"BTCUSDT","side":"%s","orderType":"Limit","qty":"%s","price":"%s"}|}
           side
           qty
           px)
  in
  printf "%d %s\n" (Cohttp.Code.code_of_status status) (Yojson.Safe.to_string json)
;;

let state exchange =
  let btc = spec.sim_symbol in
  [%sexp
    { now : int = Exchange.now exchange
    ; mark : Price.t option = Exchange.mark exchange btc
    ; book : L2.t option = Exchange.l2 ~n_levels:5 exchange btc
    ; alice : Account_view.t = Exchange.account_view exchange alice
    }]
;;

let%expect_test "a recorded minute, and its journal replays the run" =
  Log.Global.set_output [];
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let server = Server.create ~now:(fun () -> Time_ns.to_int_ns_since_epoch t0) exchange in
  let anchors =
    ok_exn
      (Anchors.create ~config:{ Anchors.Config.default with speed = 0. } server [ spec ])
  in
  (* Resting above the market: the reference buys through it during the minute. *)
  place server ~side:"Sell" ~px:"82610.0" ~qty:"0.01";
  [%expect
    {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":""},"retExtInfo":{},"time":1791817518000} |}];
  let%map () =
    Anchors.run
      anchors
      (Raw { dir; from = minute; to_ = Time_ns.add minute Time_ns.Span.minute })
  in
  print_s (Anchors.summary anchors);
  [%expect
    {|
    (((anchor bybit:BTCUSDT=BTCUSDT) (source done) (stale ())
      (stale_seconds 0.245) (events 1379) (price (82647.9)) (shadow_levels 10)
      (replay_fills 1)))
    |}];
  print_s
    [%sexp (Venue.positions (Server.venue server) alice : Bybit_protocol.Position.t list)];
  [%expect
    {|
    (((position_idx One_way) (symbol BTCUSDT) (side (Sell)) (size 0.01)
      (avg_price 82610) (position_value (826.479)) (unrealised_pnl -0.379)
      (cum_realised_pnl -0.16522) (cur_realised_pnl ()) (leverage (10))
      (liq_price (99584670.1273632)) (mark_price 82647.9)
      (position_status (Normal)) (created_time 1791817538928)
      (updated_time 1791817538928) (category ()) (seq ())))
    |}];
  let journal = Journal.to_string (Queue.to_list inputs) in
  let replayed =
    Journal.replay ~config:(Adapt.config ()) (ok_exn (Journal.of_string journal))
  in
  print_s
    [%message
      ""
        ~inputs:(Queue.length inputs : int)
        ~same_state:(Sexp.equal (state exchange) (state replayed) : bool)];
  [%expect {| ((inputs 3409) (same_state true)) |}]
;;

let%expect_test "a mark collar on a recorded minute; the journal replays its guard events"
  =
  Log.Global.set_output [];
  let exchange = Adapt.create_exchange () in
  let inputs = Queue.create () in
  Exchange.record_inputs exchange ~f:(Queue.enqueue inputs);
  let guard =
    ok_exn (Guard.Config.of_flags ~collar_bps:5 ~halt_levels:"7:15m" ~anchored:true ())
  in
  Guard.apply guard exchange |> ok_exn;
  let server = Server.create ~now:(fun () -> Time_ns.to_int_ns_since_epoch t0) exchange in
  let anchors =
    ok_exn
      (Anchors.create ~config:{ Anchors.Config.default with speed = 0. } server [ spec ])
  in
  let%map () =
    Anchors.run
      anchors
      (Raw { dir; from = minute; to_ = Time_ns.add minute Time_ns.Span.minute })
  in
  (* Marketable against the shadow levels, but more than 5 bps from the mark. *)
  place server ~side:"Buy" ~px:"83500.0" ~qty:"0.01";
  place server ~side:"Sell" ~px:"81500.0" ~qty:"0.01";
  [%expect
    {|
    200 {"retCode":110003,"retMsg":"Order price exceeds the allowable range: max buy price 82689.2.","result":{},"retExtInfo":{},"time":1791817518000}
    200 {"retCode":110003,"retMsg":"Order price exceeds the allowable range: min sell price 82606.6.","result":{},"retExtInfo":{},"time":1791817518000}
    |}];
  Venue.sync (Server.venue server);
  let live = Venue.guard_events (Server.venue server) in
  let replayed =
    Journal.replay
      ~config:(Adapt.config ())
      (ok_exn (Journal.of_string (Journal.to_string (Queue.to_list inputs))))
  in
  print_s
    [%message
      ""
        ~live:(List.length live : int)
        ~stats:(Exchange.guard_stats exchange : Guard_event.Stats.t)
        ~same_events:
          ([%equal: Guard_event.t list] live (Exchange.drain_guard_events replayed)
           : bool)];
  [%expect
    {|
    ((live 2)
     (stats
      ((collar_rejected 2) (collar_repriced 0) (collar_unreferenced 0)
       (halt_rejected 0) (halts 0) (reopens 0)))
     (same_events true))
    |}]
;;

let%expect_test "normalized event logs" =
  Log.Global.set_output [];
  let dir = "norm-source-test" in
  let%bind () = Unix.system_exn (sprintf "rm -rf %s && mkdir -p %s" dir dir) in
  let at s = Time_ns.add t0 (Time_ns.Span.of_sec s) in
  let level (px, sz) =
    { Market_data.L2_update.Level.price = Price.of_string px; size = Size.of_string sz }
  in
  let writer = Market_data.Event_log.Writer.create ~dir () in
  List.iter
    ~f:(Market_data.Event_log.Writer.append writer)
    [ Market_data.Event.L2
        { instrument = spec.reference
        ; exch_ts = at 0.
        ; recv_ts = at 0.
        ; kind = Snapshot
        ; bids = List.map ~f:level [ "82600.0", "1"; "82599.9", "2" ]
        ; asks = List.map ~f:level [ "82600.1", "1"; "82600.2", "2" ]
        }
    ; Trade
        { instrument = spec.reference
        ; exch_ts = at 0.5
        ; recv_ts = at 0.5
        ; price = Price.of_string "82600.1"
        ; size = Size.of_string "0.2"
        ; side = Buy
        ; trade_id = "1"
        }
    ];
  let%bind () = Market_data.Event_log.Writer.close writer in
  let server =
    Server.create
      ~now:(fun () -> Time_ns.to_int_ns_since_epoch t0)
      (Adapt.create_exchange ())
  in
  let anchors =
    ok_exn
      (Anchors.create ~config:{ Anchors.Config.default with speed = 0. } server [ spec ])
  in
  let date = Time_ns.to_date t0 ~zone:Time_float.Zone.utc in
  let%bind () = Anchors.run anchors (Norm { dir; from = date; to_ = date }) in
  print_s (Anchors.summary anchors);
  [%expect
    {|
    (((anchor bybit:BTCUSDT=BTCUSDT) (source done) (stale ()) (stale_seconds 0)
      (events 2) (price (82600.1)) (shadow_levels 4) (replay_fills 0)))
    |}];
  Unix.system_exn (sprintf "rm -rf %s" dir)
;;
