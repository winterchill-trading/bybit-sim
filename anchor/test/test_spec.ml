open! Core
open Bybit_sim_anchor

let%expect_test "parse" =
  List.iter
    [ "binance:BTCUSDT=BTCUSDT"
    ; "bybit:ETHUSDT=ETHUSDT"
    ; "BTCUSDT"
    ; "binance:BTCUSDT="
    ; "nowhere:BTCUSDT=BTCUSDT"
    ]
    ~f:(fun s ->
      match Spec.of_string s with
      | Ok t -> print_endline (Spec.to_string t)
      | Error e -> print_s [%sexp (e : Error.t)]);
  [%expect
    {|
    binance:BTCUSDT=BTCUSDT
    bybit:ETHUSDT=ETHUSDT
    ("expected <venue>:<symbol>=<sim-symbol>" (anchor BTCUSDT))
    ("expected <venue>:<symbol>=<sim-symbol>" (anchor binance:BTCUSDT=))
    (("bad reference" (anchor nowhere:BTCUSDT=BTCUSDT))
     ("Venue.of_string: unknown venue" (s nowhere)))
    |}]
;;
