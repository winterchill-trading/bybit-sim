open! Core
open! Bybit_protocol
module Exchange = Exchange_core_engine.Exchange
module Neutral = Exchange_core
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

let ms ns = Timestamp_ms.of_int_ms (ns / 1_000_000)

(* Universe *)

let fees : Neutral.Fee_schedule.t = { taker_bps = 5.5; maker_bps = 2. }
let min_notional = Usd.of_int 5

let base_coin symbol =
  let s = Symbol.to_string symbol in
  Option.value (String.chop_suffix s ~suffix:"USDT") ~default:s
;;

(* Bybit's instrument record for an engine instrument: the filters follow from the tick,
   the lot size and the leverage cap. *)
let info_of_instrument (i : Neutral.Instrument.t) : Instruments_info.Instrument.t =
  let qty_step = Neutral.Instrument.lot_size i in
  { symbol = i.symbol
  ; contract_type = "LinearPerpetual"
  ; status = "Trading"
  ; base_coin = base_coin i.symbol
  ; quote_coin = "USDT"
  ; leverage_filter =
      { min_leverage = Decimal.one
      ; max_leverage = Decimal.of_int i.max_leverage
      ; leverage_step = Decimal.of_string "0.01"
      }
  ; price_filter =
      { min_price = i.price_tick
      ; max_price = Price.(of_int 2_000_000 - i.price_tick)
      ; tick_size = i.price_tick
      }
  ; lot_size_filter =
      { max_order_qty = Size.scale qty_step ~by:1_000_000
      ; min_order_qty = qty_step
      ; qty_step
      ; max_mkt_order_qty = Some (Size.scale qty_step ~by:500_000)
      ; min_notional_value = Some min_notional
      }
  }
;;

let instrument (info : Instruments_info.Instrument.t) =
  { (Instruments_info.Instrument.to_exchange_core info) with fees }
;;

let default_instruments =
  let make symbol ~tick ~size_decimals =
    info_of_instrument
      (Neutral.Instrument.create
         (Symbol.of_string symbol)
         ~size_decimals
         ~price_tick:(Price.of_string tick)
         ~max_leverage:100
         ~fees)
  in
  [ make "BTCUSDT" ~tick:"0.1" ~size_decimals:3
  ; make "ETHUSDT" ~tick:"0.01" ~size_decimals:2
  ; make "SOLUSDT" ~tick:"0.01" ~size_decimals:1
  ]
;;

let config ?(instruments = default_instruments) () =
  { Exchange.Config.default with
    instruments = List.map instruments ~f:instrument
  ; funding_interval_ns = Time_ns.Span.to_int_ns (Time_ns.Span.of_hr 8.)
  ; default_funding_rate = 0.0001
  ; default_leverage = 10
  ; min_order_value = min_notional
  ; l2_levels = 25
  }
;;

let create_exchange ?instruments () = Exchange.create ~config:(config ?instruments ()) ()

let market_sim_config =
  { Exchange_core_engine.Market_sim.Config.default with max_notional = 20_000. }
;;

let instruments_info ?symbol ex : Instruments_info.t =
  { category = Linear
  ; list =
      Exchange.instruments ex
      |> List.filter ~f:(fun (i : Neutral.Instrument.t) ->
        Option.for_all symbol ~f:(Symbol.equal i.symbol))
      |> List.map ~f:info_of_instrument
  ; next_page_cursor = Some ""
  }
;;

(* Errors *)

module Api_error = struct
  type t =
    { code : Envelope.Error.t
    ; msg : string
    }
  [@@deriving sexp_of, compare, equal]

  let params msg = { code = Request_parameter_error; msg }
  let order_not_exists = { code = Order_not_exists; msg = "Order does not exist" }
end

module Rejection = struct
  type t =
    | Api_error of Api_error.t
    | Cancelled of Reject_reason.t
  [@@deriving sexp_of, compare, equal]
end

let rejection (reason : Neutral.Reject_reason.t) : Rejection.t =
  let error code msg = Rejection.Api_error { code; msg } in
  match reason with
  | Unknown_symbol -> Api_error (Api_error.params "params error: symbol invalid")
  | Unsupported msg -> Api_error (Api_error.params msg)
  | Invalid_size ->
    Api_error
      (Api_error.params "params error: qty must be a positive multiple of qtyStep")
  | Invalid_price ->
    Api_error
      (Api_error.params "params error: price must be a positive multiple of tickSize")
  | Duplicate_client_order_id ->
    error Duplicate_order_link_id "OrderLinkedID is duplicate"
  | Reduce_only_would_increase ->
    error
      Qty_truncated_to_zero
      "current position is zero, cannot fix reduce-only order qty"
  | Below_min_value { min } ->
    error
      (Other 110094)
      (sprintf "Order does not meet minimum order value %sUSDT" (Usd.to_string min))
  | Insufficient_margin ->
    error Available_balance_insufficient "Available balance is insufficient"
  | Order_not_found -> Api_error Api_error.order_not_exists
  | Post_only_would_cross _ -> Cancelled Post_only_will_take_liquidity
  | No_liquidity -> Cancelled No_immediate_qty_to_fill
  | Self_trade -> Cancelled By_self_match
;;

(* Requests *)

let time_in_force (p : Create_order.Params.t) : Time_in_force.t =
  match p.order_type with
  | Market -> Ioc
  | Limit | Unknown -> Option.value p.time_in_force ~default:Gtc
;;

let order_request ex (p : Create_order.Params.t)
  : (Neutral.Order_request.t, Api_error.t) Result.t
  =
  let open Result.Let_syntax in
  let%bind () =
    match Exchange.instrument ex p.symbol with
    | Some _ -> Ok ()
    | None -> Error (Api_error.params "params error: symbol invalid")
  in
  let%bind () =
    match p.position_idx with
    | None | Some One_way -> Ok ()
    | Some (Hedge_buy | Hedge_sell) ->
      Error (Api_error.params "position idx not match position mode")
  in
  let request order_type px : Neutral.Order_request.t =
    { symbol = p.symbol
    ; side = p.side
    ; size = p.qty
    ; px
    ; order_type
    ; reduce_only = Option.value p.reduce_only ~default:false
    ; client_order_id = p.order_link_id
    }
  in
  match p.order_type with
  | Unknown -> Error (Api_error.params "params error: orderType invalid")
  | Market -> Ok (request Neutral.Order_type.market None)
  | Limit ->
    (match p.price with
     | None -> Error (Api_error.params "params error: price is required for Limit orders")
     | Some px ->
       (match time_in_force p with
        | Gtc -> Ok (request (Limit Gtc) (Some px))
        | Ioc | Fok -> Ok (request (Limit Ioc) (Some px))
        | Post_only -> Ok (request (Limit Alo) (Some px))
        | Rpi -> Error (Api_error.params "params error: RPI orders are not supported")))
;;

let fok_fillable ex ~symbol ~side ~px ~size =
  match Exchange.l2 ~n_levels:Int.max_value ex symbol with
  | None -> false
  | Some book ->
    let levels, acceptable =
      match (side : Side.t) with
      | Buy -> book.asks, fun level_px -> Price.( <= ) level_px px
      | Sell -> book.bids, fun level_px -> Price.( >= ) level_px px
    in
    let available =
      List.take_while levels ~f:(fun (l : Neutral.L2.Level.t) -> acceptable l.px)
      |> List.map ~f:(fun (l : Neutral.L2.Level.t) -> l.sz)
      |> Size.sum
    in
    Size.( >= ) available size
;;

(* Conversions *)

let book_levels levels =
  List.map levels ~f:(fun (l : Neutral.L2.Level.t) : Book_level.t ->
    { price = l.px; size = l.sz })
;;

let orderbook ~now ~u ~seq (book : Neutral.L2.t) : Orderbook.t =
  { s = book.symbol
  ; b = book_levels book.bids
  ; a = book_levels book.asks
  ; ts = ms now
  ; u
  ; seq
  ; cts = Some (ms book.time)
  }
;;

(* Levels of [next] that are new or changed, then levels of [prev] that are gone (size 0),
   merged in book order by [better]. *)
let side_delta ~better prev next =
  let size_at levels px =
    List.find levels ~f:(fun (l : Neutral.L2.Level.t) -> Price.equal l.px px)
    |> Option.map ~f:(fun (l : Neutral.L2.Level.t) -> l.sz)
  in
  let changed =
    List.filter_map next ~f:(fun (l : Neutral.L2.Level.t) ->
      match size_at prev l.px with
      | Some sz when Size.equal sz l.sz -> None
      | _ -> Some { Book_level.price = l.px; size = l.sz })
  in
  let removed =
    List.filter_map prev ~f:(fun (l : Neutral.L2.Level.t) ->
      match size_at next l.px with
      | Some _ -> None
      | None -> Some { Book_level.price = l.px; size = Size.zero })
  in
  List.sort (changed @ removed) ~compare:(fun (a : Book_level.t) b ->
    if Price.equal a.price b.price then 0 else if better a.price b.price then -1 else 1)
;;

let orderbook_delta ~(prev : Neutral.L2.t) (next : Neutral.L2.t) =
  ( side_delta ~better:Price.( > ) prev.bids next.bids
  , side_delta ~better:Price.( < ) prev.asks next.asks )
;;

let tick_direction ~prev px =
  match prev with
  | None -> "ZeroPlusTick"
  | Some (prev_px, prev_dir) ->
    if Price.( > ) px prev_px
    then "PlusTick"
    else if Price.( < ) px prev_px
    then "MinusTick"
    else (
      match prev_dir with
      | "PlusTick" | "ZeroPlusTick" -> "ZeroPlusTick"
      | _ -> "ZeroMinusTick")
;;

let public_trade ~tick_direction (fill : Order_book.Fill.t) : Public_trade.Trade.t =
  { time = ms fill.time
  ; symbol = fill.symbol
  ; side = fill.taker_side
  ; size = fill.sz
  ; price = fill.px
  ; tick_direction = Some tick_direction
  ; trade_id = Exec_id.of_string (Neutral.Trade_id.to_string fill.tid)
  ; block_trade = false
  ; rpi = None
  ; seq = Some (Neutral.Trade_id.to_int fill.tid)
  }
;;

let ticker ex ~last_price symbol : Tickers.Ticker.t option =
  let open Option.Let_syntax in
  let%bind _ = Exchange.instrument ex symbol in
  let book = Exchange.l2 ~n_levels:1 ex symbol in
  let best f = Option.bind book ~f in
  let bid = best Neutral.L2.best_bid in
  let ask = best Neutral.L2.best_ask in
  let%bind mark = Exchange.mark ex symbol in
  let config = Exchange.config ex in
  let interval = config.funding_interval_ns in
  let next_funding = ((Exchange.now ex / interval) + 1) * interval in
  let px = Option.map ~f:(fun (l : Neutral.L2.Level.t) -> l.px) in
  let sz = Option.map ~f:(fun (l : Neutral.L2.Level.t) -> l.sz) in
  Some
    { Tickers.Ticker.symbol
    ; last_price = Option.value last_price ~default:mark
    ; mark_price = mark
    ; index_price = mark
    ; bid1_price = px bid
    ; bid1_size = sz bid
    ; ask1_price = px ask
    ; ask1_size = sz ask
    ; funding_rate = Some (Decimal.of_float config.default_funding_rate)
    ; next_funding_time = ms next_funding
    ; open_interest = None
    ; volume24h = None
    ; turnover24h = None
    ; price24h_pcnt = None
    }
;;

let ws_ticker_data (t : Tickers.Ticker.t) : Ws_ticker.Data.t =
  { symbol = t.symbol
  ; last_price = Some t.last_price
  ; mark_price = Some t.mark_price
  ; index_price = Some t.index_price
  ; bid1_price = t.bid1_price
  ; bid1_size = t.bid1_size
  ; ask1_price = t.ask1_price
  ; ask1_size = t.ask1_size
  ; funding_rate = t.funding_rate
  ; next_funding_time = Some t.next_funding_time
  ; open_interest = t.open_interest
  ; volume24h = t.volume24h
  ; turnover24h = t.turnover24h
  ; price24h_pcnt = t.price24h_pcnt
  }
;;

let ticker_delta ~(prev : Ws_ticker.Data.t) (next : Ws_ticker.Data.t) =
  let d equal a b = if Option.equal equal a b then None else b in
  let delta : Ws_ticker.Data.t =
    { symbol = next.symbol
    ; last_price = d Price.equal prev.last_price next.last_price
    ; mark_price = d Price.equal prev.mark_price next.mark_price
    ; index_price = d Price.equal prev.index_price next.index_price
    ; bid1_price = d Price.equal prev.bid1_price next.bid1_price
    ; bid1_size = d Size.equal prev.bid1_size next.bid1_size
    ; ask1_price = d Price.equal prev.ask1_price next.ask1_price
    ; ask1_size = d Size.equal prev.ask1_size next.ask1_size
    ; funding_rate = d Decimal.equal prev.funding_rate next.funding_rate
    ; next_funding_time =
        d Timestamp_ms.equal prev.next_funding_time next.next_funding_time
    ; open_interest = d Size.equal prev.open_interest next.open_interest
    ; volume24h = d Size.equal prev.volume24h next.volume24h
    ; turnover24h = d Usd.equal prev.turnover24h next.turnover24h
    ; price24h_pcnt = d Decimal.equal prev.price24h_pcnt next.price24h_pcnt
    }
  in
  let unchanged : Ws_ticker.Data.t =
    { symbol = next.symbol
    ; last_price = None
    ; mark_price = None
    ; index_price = None
    ; bid1_price = None
    ; bid1_size = None
    ; ask1_price = None
    ; ask1_size = None
    ; funding_rate = None
    ; next_funding_time = None
    ; open_interest = None
    ; volume24h = None
    ; turnover24h = None
    ; price24h_pcnt = None
    }
  in
  if Ws_ticker.Data.equal delta unchanged then None else Some delta
;;

let closed_size (change : Exchange_core_engine.Position.Change.t) sz =
  match change.direction with
  | Open_long | Open_short -> None
  | Close_long | Close_short -> Some sz
  | Long_to_short | Short_to_long -> Some (Size.abs change.start_position)
;;

let execution ?category ~order_id ~fee_rate (e : Exchange_core_engine.Execution.t)
  : Execution.t
  =
  let s = e.settlement in
  { exec_id = Exec_id.of_string (Neutral.Trade_id.to_string e.fill.tid)
  ; order_id
  ; order_link_id = Exchange_core_engine.Execution.client_order_id e
  ; symbol = e.fill.symbol
  ; side = s.side
  ; exec_price = e.fill.px
  ; exec_qty = e.fill.sz
  ; exec_value = Notional.mul e.fill.px e.fill.sz
  ; exec_fee = s.fee
  ; fee_rate = Some fee_rate
  ; exec_type = Trade
  ; is_maker = not s.crossed
  ; exec_time = ms e.fill.time
  ; closed_size = closed_size s.change e.fill.sz
  ; seq = Some (Neutral.Trade_id.to_int e.fill.tid)
  ; category
  }
;;

let position ?category ~cum_fees ~mark ~time (p : Neutral.Position_view.t) : Position.t =
  { position_idx = One_way
  ; symbol = p.symbol
  ; side =
      (if Size.is_positive p.size
       then Some Buy
       else if Size.is_negative p.size
       then Some Sell
       else None)
  ; size = Size.abs p.size
  ; avg_price = p.entry_px
  ; position_value = Some p.notional
  ; unrealised_pnl = p.unrealized_pnl
  ; cum_realised_pnl = Usd.(p.realized_pnl - p.cum_funding - cum_fees)
  ; cur_realised_pnl = None
  ; leverage = Some (Decimal.of_int p.leverage)
  ; liq_price = p.liquidation_px
  ; mark_price = mark
  ; position_status = Some "Normal"
  ; created_time = ms time
  ; updated_time = ms time
  ; category
  ; seq = None
  }
;;

let flat_position ?category ~mark ~time symbol : Position.t =
  { position_idx = One_way
  ; symbol
  ; side = None
  ; size = Size.zero
  ; avg_price = Price.zero
  ; position_value = Some Usd.zero
  ; unrealised_pnl = Usd.zero
  ; cum_realised_pnl = Usd.zero
  ; cur_realised_pnl = None
  ; leverage = None
  ; liq_price = None
  ; mark_price = mark
  ; position_status = Some "Normal"
  ; created_time = ms time
  ; updated_time = ms time
  ; category
  ; seq = None
  }
;;

let wallet (v : Neutral.Account_view.t) : Wallet_balance.Account.t =
  let upl = Usd.(v.equity - v.balance) in
  { account_type = "UNIFIED"
  ; total_equity = v.equity
  ; total_wallet_balance = v.balance
  ; total_margin_balance = v.equity
  ; total_available_balance = v.available
  ; total_perp_upl = Some upl
  ; total_initial_margin = Some v.margin_used
  ; total_maintenance_margin = Some v.maintenance_margin
  ; coin =
      [ { coin = "USDT"
        ; wallet_balance = v.balance
        ; equity = v.equity
        ; unrealised_pnl = Some upl
        ; cum_realised_pnl = None
        ; usd_value = Some v.equity
        ; locked = Some Usd.zero
        }
      ]
  }
;;
