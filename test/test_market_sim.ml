open! Core
open! Bybit_protocol
open! Bybit_sim
module Exchange = Exchange_core_engine.Exchange
module Market_sim = Exchange_core_engine.Market_sim

let run ~seed ~ticks =
  let exchange = Adapt.create_exchange () in
  let venue = Venue.create exchange in
  let sim =
    Market_sim.create { Adapt.market_sim_config with seed; noise_traders = 4 } exchange
  in
  let trades = ref 0 in
  for i = 1 to ticks do
    Market_sim.tick sim;
    Exchange.step exchange ~now:(i * 100_000_000);
    trades := !trades + List.length (Venue.drain venue).trades
  done;
  venue, !trades
;;

let%expect_test "noise traders keep two-sided books around the reference prices" =
  let venue, trades = run ~seed:7 ~ticks:200 in
  List.iter (Venue.tickers venue).list ~f:(fun t ->
    print_s
      [%message
        ""
          ~symbol:(t.symbol : Symbol.t)
          ~mark:(t.mark_price : Price.t)
          ~bid:(t.bid1_price : Price.t option)
          ~ask:(t.ask1_price : Price.t option)]);
  print_s [%message (trades : int)];
  [%expect
    {|
    ((symbol BTCUSDT) (mark 99798.5) (bid (99764.9)) (ask (99853.3)))
    ((symbol ETHUSDT) (mark 3510.73) (bid (3507.9)) (ask (3509.21)))
    ((symbol SOLUSDT) (mark 150.15) (bid (150.17)) (ask (150.25)))
    (trades 66)
    |}]
;;

let%expect_test "same seed, same run" =
  let digest seed =
    let venue, _ = run ~seed ~ticks:50 in
    Venue.tickers venue
  in
  print_s [%sexp ([%equal: Tickers.t] (digest 3) (digest 3) : bool)];
  [%expect {| true |}];
  print_s [%sexp ([%equal: Tickers.t] (digest 3) (digest 4) : bool)];
  [%expect {| false |}]
;;
