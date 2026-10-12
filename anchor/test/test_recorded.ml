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
