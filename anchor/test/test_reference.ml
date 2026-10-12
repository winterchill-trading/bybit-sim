open! Core
open Bybit_sim_anchor

let%expect_test "normalizers by venue" =
  List.iter
    Market_data.Venue.[ Bybit; Binance; Okx ]
    ~f:(fun venue ->
      match Reference.normalizer venue with
      | Ok n ->
        print_s
          [%message "ok" ~venue:(Market_data.Normalizer.venue n : Market_data.Venue.t)]
      | Error e -> print_s [%sexp (e : Error.t)]);
  [%expect
    {|
    (ok (venue Bybit))
    (ok (venue Binance))
    ("no client for this reference venue" (venue Okx)
     (supported (Bybit Binance)))
    |}]
;;
