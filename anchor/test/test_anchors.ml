open! Core
open! Async
open! Exchange_core
open Bybit_sim
open Bybit_sim_anchor

let t0 = 1_700_000_000_000_000_000
let reference = Market_data.Instrument.of_string "binance:BTCUSDT"
let spec = ok_exn (Spec.of_string "binance:BTCUSDT=BTCUSDT")
let at ms = Time_ns.of_int_ns_since_epoch (t0 + (ms * 1_000_000))

let level (px, sz) =
  { Market_data.L2_update.Level.price = Price.of_string px; size = Size.of_string sz }
;;

let snapshot ~ms ~bids ~asks : Market_data.L2_update.t =
  { instrument = reference
  ; exch_ts = at ms
  ; recv_ts = at ms
  ; kind = Snapshot
  ; bids = List.map bids ~f:level
  ; asks = List.map asks ~f:level
  }
;;

let trade ~ms ~px ~sz side : Market_data.Trade.t =
  { instrument = reference
  ; exch_ts = at ms
  ; recv_ts = at ms
  ; price = Price.of_string px
  ; size = Size.of_string sz
  ; side
  ; trade_id = Int.to_string ms
  }
;;

(* A feed whose pipes the test writes to. *)
let test_feed () =
  let trades_r, trades_w = Pipe.create () in
  let bbo_r, bbo_w = Pipe.create () in
  let l2_r, l2_w = Pipe.create () in
  let funding_r, funding_w = Pipe.create () in
  let feed : Market_data.Feed.t =
    (module struct
      let trades = trades_r
      let bbo = bbo_r
      let l2 = l2_r
      let funding = funding_r

      let close () =
        Pipe.close trades_w;
        Pipe.close bbo_w;
        Pipe.close l2_w;
        Pipe.close funding_w;
        return ()
      ;;
    end)
  in
  feed, trades_w, l2_w
;;

let print_book server =
  let book =
    Option.value_exn (Venue.orderbook ~limit:3 (Server.venue server) spec.sim_symbol)
  in
  print_s [%sexp (book : Bybit_protocol.Orderbook.t)]
;;

(* Through the server's route, as a client would see it. *)
let print_status server =
  let _status, json =
    Server.handle_http
      server
      ~meth:`GET
      ~uri:(Uri.of_string Anchors.path)
      ~headers:(Cohttp.Header.init ())
      ~body:""
  in
  print_endline (Yojson.Safe.pretty_to_string json)
;;

let%expect_test "a live feed drives the mark, shadow levels and replay fills" =
  Log.Global.set_output [];
  let now = ref t0 in
  let server = Server.create ~now:(fun () -> !now) (Adapt.create_exchange ()) in
  let anchors = ok_exn (Anchors.create server [ spec ]) in
  let feed, trades, l2 = test_feed () in
  let finished =
    Anchors.run anchors (Custom (fun _ -> return (Ok (Price_anchor.Source.of_feed feed))))
  in
  Pipe.write_without_pushback
    l2
    (snapshot
       ~ms:0
       ~bids:[ "50000.0", "1"; "49999.9", "2" ]
       ~asks:[ "50000.1", "1"; "50000.2", "2" ]);
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  print_book server;
  [%expect
    {|
    ((s BTCUSDT) (b (((price 50000) (size 1)) ((price 49999.9) (size 2))))
     (a (((price 50000.1) (size 1)) ((price 50000.2) (size 2))))
     (ts 1700000000000) (u 4) (seq 4) (cts (1700000000000)))
    |}];
  (* A client bid behind the reference's 2 BTC at 49999.9. *)
  let status, json =
    Server.handle_http
      server
      ~meth:`POST
      ~uri:(Uri.of_string "/v5/order/create")
      ~headers:
        (Cohttp.Header.of_list
           [ "X-BAPI-API-KEY", "alice"
           ; "X-BAPI-TIMESTAMP", Int.to_string (t0 / 1_000_000)
           ])
      ~body:
        {|{"category":"linear","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","qty":"0.01","price":"49999.9"}|}
  in
  printf "%d %s\n" (Cohttp.Code.code_of_status status) (Yojson.Safe.to_string json);
  [%expect
    {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"5","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
  (* The reference trades through it. *)
  now := t0 + 10_000_000;
  Pipe.write_without_pushback trades (trade ~ms:10 ~px:"49999.8" ~sz:"0.5" Sell);
  let%bind () = Scheduler.yield_until_no_jobs_remain () in
  let alice = Account.of_string "alice" in
  print_s
    [%sexp (Venue.positions (Server.venue server) alice : Bybit_protocol.Position.t list)];
  [%expect
    {|
    (((position_idx One_way) (symbol BTCUSDT) (side (Buy)) (size 0.01)
      (avg_price 49999.9) (position_value (500.001)) (unrealised_pnl 0.002)
      (cum_realised_pnl -0.0999998) (cur_realised_pnl ()) (leverage (10))
      (liq_price ()) (mark_price 50000.1) (position_status (Normal))
      (created_time 1700000000010) (updated_time 1700000000010) (category ())
      (seq ())))
    |}];
  print_status server;
  [%expect
    {|
    {
      "anchors": [
        {
          "reference": "binance:BTCUSDT",
          "symbol": "BTCUSDT",
          "source": "running",
          "source_error": null,
          "fresh": true,
          "stale_reason": null,
          "stale_seconds": 0.0,
          "went_stale": 1,
          "gaps": 0,
          "events": 2,
          "reference_price": "50000.1",
          "shadow_levels": 4,
          "replay_fills": 1,
          "replays_rejected": 0,
          "marks_set": 1
        }
      ]
    }
    |}];
  (* Silent for longer than max_staleness. *)
  now := t0 + 6_000_000_000;
  Server.mutate server ~f:ignore;
  print_status server;
  [%expect
    {|
    {
      "anchors": [
        {
          "reference": "binance:BTCUSDT",
          "symbol": "BTCUSDT",
          "source": "running",
          "source_error": null,
          "fresh": false,
          "stale_reason": "silent",
          "stale_seconds": 0.0,
          "went_stale": 2,
          "gaps": 0,
          "events": 2,
          "reference_price": "50000.1",
          "shadow_levels": 0,
          "replay_fills": 1,
          "replays_rejected": 0,
          "marks_set": 1
        }
      ]
    }
    |}];
  let module F = (val feed) in
  let%bind () = F.close () in
  let%map () = finished in
  print_s (Anchors.summary anchors);
  [%expect
    {|
    (((anchor binance:BTCUSDT=BTCUSDT) (source done) (stale (silent))
      (stale_seconds 0) (events 2) (price (50000.1)) (shadow_levels 0)
      (replay_fills 1)))
    |}]
;;
