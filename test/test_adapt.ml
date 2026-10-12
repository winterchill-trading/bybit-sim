open! Core
open! Bybit_protocol
open! Bybit_sim
module L2 = Exchange_core.L2

let%expect_test "rejections" =
  List.iter
    Exchange_core.Reject_reason.
      [ Unknown_symbol
      ; Invalid_size
      ; Invalid_price
      ; Duplicate_client_order_id
      ; Reduce_only_would_increase
      ; Below_min_value { min = Usd.of_int 5 }
      ; Insufficient_margin
      ; Order_not_found
      ; Post_only_would_cross { best_bid = None; best_ask = None }
      ; No_liquidity
      ; Self_trade
      ]
    ~f:(fun reason ->
      match Adapt.rejection reason with
      | Api_error { code; msg } -> printf "%d %s\n" (Envelope.Error.to_code code) msg
      | Cancelled reason -> printf "cancelled %s\n" (Reject_reason.to_wire reason));
  [%expect
    {|
    10001 params error: symbol invalid
    10001 params error: qty must be a positive multiple of qtyStep
    10001 params error: price must be a positive multiple of tickSize
    110072 OrderLinkedID is duplicate
    110017 current position is zero, cannot fix reduce-only order qty
    110094 Order does not meet minimum order value 5USDT
    110007 Available balance is insufficient
    110001 Order does not exist
    cancelled EC_PostOnlyWillTakeLiquidity
    cancelled EC_NoImmediateQtyToFill
    cancelled EC_BySelfMatch
    |}]
;;

let book bids asks : L2.t =
  let level (px, sz) : L2.Level.t =
    { px = Price.of_string px; sz = Size.of_string sz; n = 1 }
  in
  { symbol = Symbol.of_string "BTCUSDT"
  ; time = 0
  ; bids = List.map bids ~f:level
  ; asks = List.map asks ~f:level
  }
;;

let%expect_test "orderbook delta" =
  let prev = book [ "100", "1"; "99", "2" ] [ "101", "1"; "102", "3" ] in
  let next = book [ "100.5", "1"; "100", "1"; "99", "5" ] [ "102", "3"; "103", "1" ] in
  let bids, asks = Adapt.orderbook_delta ~prev next in
  let show levels =
    List.map levels ~f:(fun (l : Book_level.t) ->
      sprintf "%s@%s" (Size.to_string l.size) (Price.to_string l.price))
    |> String.concat ~sep:" "
  in
  printf "bids: %s\nasks: %s\n" (show bids) (show asks);
  [%expect {|
    bids: 1@100.5 5@99
    asks: 0@101 1@103
    |}];
  let bids, asks = Adapt.orderbook_delta ~prev prev in
  printf "unchanged: %b\n" (List.is_empty bids && List.is_empty asks);
  [%expect {| unchanged: true |}]
;;

let%expect_test "tick direction" =
  let px = Price.of_string in
  let prev = ref None in
  List.iter [ "100"; "101"; "101"; "100"; "100"; "102" ] ~f:(fun p ->
    let dir = Adapt.tick_direction ~prev:!prev (px p) in
    prev := Some (px p, dir);
    printf "%s %s\n" p dir);
  [%expect
    {|
    100 ZeroPlusTick
    101 PlusTick
    101 ZeroPlusTick
    100 MinusTick
    100 ZeroMinusTick
    102 PlusTick
    |}]
;;

let%expect_test "order requests" =
  let ex = Adapt.create_exchange () in
  let btc = Symbol.of_string "BTCUSDT" in
  let show p =
    match Adapt.order_request ex p with
    | Ok req -> print_s [%sexp (req : Exchange_core.Order_request.t)]
    | Error e -> print_s [%sexp (e : Adapt.Api_error.t)]
  in
  let qty = Size.of_string "0.001" in
  let price = Price.of_string "100000" in
  show (Create_order.Params.limit btc ~side:Buy ~qty ~price ~time_in_force:Post_only);
  show (Create_order.Params.limit btc ~side:Sell ~qty ~price ~time_in_force:Fok);
  show (Create_order.Params.market btc ~side:Buy ~qty ~reduce_only:true);
  show (Create_order.Params.limit btc ~side:Buy ~qty ~price ~time_in_force:Rpi);
  show (Create_order.Params.limit btc ~side:Buy ~qty ~price ~position_idx:Hedge_buy);
  show (Create_order.Params.limit (Symbol.of_string "BTCUSD") ~side:Buy ~qty ~price);
  [%expect
    {|
    ((symbol BTCUSDT) (side Buy) (size 0.001) (px (100000))
     (order_type (Limit Alo)) (reduce_only false) (client_order_id ()))
    ((symbol BTCUSDT) (side Sell) (size 0.001) (px (100000))
     (order_type (Limit Ioc)) (reduce_only false) (client_order_id ()))
    ((symbol BTCUSDT) (side Buy) (size 0.001) (px ())
     (order_type (Market (slippage_bps ()))) (reduce_only true)
     (client_order_id ()))
    ((code Request_parameter_error)
     (msg "params error: RPI orders are not supported"))
    ((code Request_parameter_error) (msg "position idx not match position mode"))
    ((code Request_parameter_error) (msg "params error: symbol invalid"))
    |}]
;;
