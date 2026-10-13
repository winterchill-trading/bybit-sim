open! Core
open! Bybit_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Account = Exchange_core.Account
module Api_error = Adapt.Api_error
module Order = Orders.Order

module Output = struct
  type t =
    { events : Event.t list
    ; orders : Order.t list
    ; trades : Public_trade.Trade.t list
    }
end

type t =
  { exchange : Exchange.t
  ; orders : Orders.t
  ; last_trade : (Price.t * string) Symbol.Table.t
  ; book_seq : int Symbol.Table.t
  ; mutable events : Event.t list (* newest first *)
  ; mutable changed : Order.t list (* newest first *)
  ; mutable trades : Public_trade.Trade.t list (* newest first *)
  }

let create exchange =
  { exchange
  ; orders = Orders.create ()
  ; last_trade = Symbol.Table.create ()
  ; book_seq = Symbol.Table.create ()
  ; events = []
  ; changed = []
  ; trades = []
  }
;;

let exchange t = t.exchange
let orders t = t.orders
let now t = Exchange.now t.exchange
let book_seq t symbol = Hashtbl.find t.book_seq symbol |> Option.value ~default:0
let changed t o = t.changed <- o :: t.changed

let sync t =
  List.iter (Exchange.drain_events t.exchange) ~f:(fun event ->
    t.events <- event :: t.events;
    Option.iter (Event.book_symbol event) ~f:(fun symbol ->
      Hashtbl.update t.book_seq symbol ~f:(fun n -> Option.value n ~default:0 + 1));
    (match event with
     | Fill { fill; _ } ->
       let prev = Hashtbl.find t.last_trade fill.symbol in
       let tick_direction = Adapt.tick_direction ~prev fill.px in
       Hashtbl.set t.last_trade ~key:fill.symbol ~data:(fill.px, tick_direction);
       t.trades <- Adapt.public_trade ~tick_direction fill :: t.trades
     | _ -> ());
    List.iter (Orders.apply t.orders event) ~f:(changed t))
;;

let drain t : Output.t =
  sync t;
  let seen = Order_id.Hash_set.create () in
  let orders =
    List.rev t.changed
    |> List.filter ~f:(fun o ->
      if Hash_set.mem seen (Order.id o)
      then false
      else (
        Hash_set.add seen (Order.id o);
        true))
  in
  let output =
    { Output.events = List.rev t.events; orders; trades = List.rev t.trades }
  in
  t.events <- [];
  t.changed <- [];
  t.trades <- [];
  output
;;

(* Market data *)

let orderbook ?(limit = 25) t symbol =
  Exchange.l2 ~n_levels:limit t.exchange symbol
  |> Option.map ~f:(fun book ->
    let seq = book_seq t symbol in
    Adapt.orderbook ~now:(now t) ~u:seq ~seq book)
;;

let tickers ?symbol t : Tickers.t =
  let symbols =
    List.map (Exchange.instruments t.exchange) ~f:(fun i -> i.symbol)
    |> List.filter ~f:(fun s -> Option.for_all symbol ~f:(Symbol.equal s))
  in
  { category = Linear
  ; list =
      List.filter_map symbols ~f:(fun symbol ->
        let last_price = Hashtbl.find t.last_trade symbol |> Option.map ~f:fst in
        Adapt.ticker t.exchange ~last_price symbol)
  ; next_page_cursor = None
  }
;;

(* Trading *)

let ack o : Order_ack.t = { order_id = Order.id o; order_link_id = Order.order_link_id o }

let check_category (category : Category.t) =
  match category with
  | Linear -> Ok ()
  | Inverse | Spot | Option ->
    Error (Api_error.params "params error: only category=linear is simulated")
;;

let cancelled_at_once t account p reason =
  let o = Orders.rejected t.orders account p reason ~time:(now t) in
  changed t o;
  Ok (ack o)
;;

(* The engine's id for the order when it was placed or rejected by the engine; [None] when
   validation refused it before the engine saw it. *)
let place_order t account (p : Create_order.Params.t) =
  match Adapt.order_request t.exchange p with
  | Error e -> None, Error e
  | Ok req ->
    let fok_unfillable =
      match Adapt.time_in_force p, req.px with
      | Fok, Some px ->
        not (Adapt.fok_fillable t.exchange ~symbol:p.symbol ~side:p.side ~px ~size:p.qty)
      | _ -> false
    in
    if fok_unfillable
    then None, cancelled_at_once t account p No_enough_qty_to_fill
    else (
      let engine_id, status = Exchange.place_with_order_id t.exchange account req in
      match status with
      | Resting { order_id; _ } | Filled { order_id; _ } ->
        let o = Orders.placed t.orders account p order_id ~time:(now t) in
        sync t;
        Some engine_id, Ok (ack o)
      | Rejected reason ->
        sync t;
        (match Adapt.rejection reason with
         | Api_error e -> Some engine_id, Error e
         | Cancelled reason -> Some engine_id, cancelled_at_once t account p reason))
;;

let create_order t account p = snd (place_order t account p)
let max_batch = 20

let create_batch t account params =
  if List.length params > max_batch
  then
    Error
      (Api_error.params (sprintf "params error: at most %d orders per batch" max_batch))
  else (
    let results =
      List.map params ~f:(fun (p : Create_order.Params.t) ->
        let engine_id, result = place_order t account p in
        let item : Create_batch.Item.t =
          match result with
          | Ok ack ->
            { category = Linear
            ; symbol = p.symbol
            ; order_id = ack.order_id
            ; order_link_id = ack.order_link_id
            ; create_at = Some (Adapt.ms (now t))
            }
          | Error _ ->
            { category = Linear
            ; symbol = p.symbol
            ; order_id =
                (match engine_id with
                 | Some id -> Order_id.of_exchange_core id
                 | None -> Order_id.of_string "")
            ; order_link_id = p.order_link_id
            ; create_at = Some (Adapt.ms (now t))
            }
        in
        let status : Create_batch.Ext_info.Status.t =
          match result with
          | Ok _ -> { code = 0; msg = "OK" }
          | Error e -> { code = Envelope.Error.to_code e.code; msg = e.msg }
        in
        item, status)
    in
    Ok
      ( { Create_batch.Response.list = List.map results ~f:fst }
      , { Create_batch.Ext_info.list = List.map results ~f:snd } ))
;;

let find_target t account ~order_id ~order_link_id =
  match order_id, order_link_id with
  | Some id, _ -> Ok (Orders.find_open t.orders account (`Id id))
  | None, Some link -> Ok (Orders.find_open t.orders account (`Link link))
  | None, None ->
    Error (Api_error.params "params error: orderId or orderLinkId is required")
;;

let open_target t account ~symbol ~order_id ~order_link_id =
  match find_target t account ~order_id ~order_link_id with
  | Error e -> Error e
  | Ok (Some o) when Symbol.equal (Order.symbol o) symbol ->
    (match Order.engine_oid o with
     | Some oid -> Ok (o, oid)
     | None -> Error Api_error.order_not_exists)
  | Ok _ -> Error Api_error.order_not_exists
;;

let cancel_one t account o oid =
  let status = Exchange.cancel t.exchange account ~symbol:(Order.symbol o) oid in
  sync t;
  match status with
  | Cancelled -> Ok (ack o)
  | Not_found -> Error Api_error.order_not_exists
;;

let cancel_order t account (req : Cancel_order.Request.t) =
  let open Result.Let_syntax in
  let%bind () = check_category req.category in
  let%bind o, oid =
    open_target
      t
      account
      ~symbol:req.symbol
      ~order_id:req.order_id
      ~order_link_id:req.order_link_id
  in
  cancel_one t account o oid
;;

let cancel_all t account (req : Cancel_all.Request.t) =
  let open Result.Let_syntax in
  let%bind () = check_category req.category in
  let%bind matches =
    match req.symbol, req.base_coin, req.settle_coin with
    | Some symbol, _, _ -> Ok (fun o -> Symbol.equal (Order.symbol o) symbol)
    | None, Some coin, _ ->
      Ok (fun o -> String.equal (Adapt.base_coin (Order.symbol o)) coin)
    | None, None, Some "USDT" -> Ok (fun _ -> true)
    | None, None, Some _ -> Ok (fun _ -> false)
    | None, None, None ->
      Error (Api_error.params "params error: symbol, baseCoin or settleCoin is required")
  in
  let acks =
    Orders.open_orders t.orders account
    |> List.filter ~f:matches
    |> List.filter_map ~f:(fun o ->
      Option.bind (Order.engine_oid o) ~f:(fun oid ->
        Result.ok (cancel_one t account o oid)))
  in
  Ok { Cancel_all.Response.list = acks; success = true }
;;

let resting_request o ~size ~px : Exchange_core.Order_request.t =
  { symbol = Order.symbol o
  ; side = Order.side o
  ; size
  ; px = Some px
  ; order_type =
      (match Order.time_in_force o with
       | Post_only -> Limit Alo
       | Gtc | Ioc | Fok | Rpi -> Limit Gtc)
  ; reduce_only = Order.reduce_only o
  ; client_order_id = Order.order_link_id o
  }
;;

let amend_order t account (req : Amend_order.Request.t) =
  let open Result.Let_syntax in
  let%bind () = check_category req.category in
  let%bind o, oid =
    open_target
      t
      account
      ~symbol:req.symbol
      ~order_id:req.order_id
      ~order_link_id:req.order_link_id
  in
  let%bind () =
    if Option.is_none req.qty && Option.is_none req.price
    then Error (Api_error.params "params error: qty or price is required")
    else Ok ()
  in
  let qty = Option.value req.qty ~default:(Order.qty o) in
  let px = Option.value req.price ~default:(Order.price o) in
  let leaves = Size.(qty - Order.cum_exec_qty o) in
  let%bind () =
    if Size.is_positive leaves
    then Ok ()
    else Error (Api_error.params "params error: qty must exceed the filled qty")
  in
  let old_qty = Order.qty o in
  let old_px = Order.price o in
  let old_leaves = Order.leaves_qty o in
  let time = now t in
  match
    Exchange.modify t.exchange account (Order_id oid) (resting_request o ~size:leaves ~px)
  with
  | Resting { order_id; _ } | Filled { order_id; _ } ->
    Orders.amended t.orders o ~engine_oid:order_id ~qty ~price:px ~time;
    sync t;
    Ok (ack o)
  | Rejected reason ->
    (* The engine has cancelled the original; put its remainder back. *)
    (match
       Exchange.place t.exchange account (resting_request o ~size:old_leaves ~px:old_px)
     with
     | Resting { order_id; _ } | Filled { order_id; _ } ->
       Orders.amended t.orders o ~engine_oid:order_id ~qty:old_qty ~price:old_px ~time
     | Rejected _ -> Orders.cancelled t.orders o ~time);
    sync t;
    changed t o;
    (match Adapt.rejection reason with
     | Api_error e -> Error e
     | Cancelled reason ->
       Error
         (Api_error.params
            (sprintf "params error: amend rejected (%s)" (Reject_reason.to_wire reason))))
;;

(* Account queries *)

let realtime ?symbol ?order_id ?order_link_id t account ~open_only ~limit =
  let by_key = Option.is_some order_id || Option.is_some order_link_id in
  let orders =
    Orders.open_orders t.orders account
    @ if open_only && not by_key then [] else Orders.closed_orders t.orders account
  in
  List.filter orders ~f:(fun o ->
    Option.for_all symbol ~f:(Symbol.equal (Order.symbol o))
    && Option.for_all order_id ~f:(Order_id.equal (Order.id o))
    && Option.for_all order_link_id ~f:(fun link ->
      Option.equal Order_link_id.equal (Order.order_link_id o) (Some link)))
  |> Fn.flip List.take limit
  |> List.map ~f:(fun o -> Order.to_realtime o)
;;

let fee_rate t (e : Exchange_core_engine.Execution.t) =
  match Exchange.instrument t.exchange e.fill.symbol with
  | None -> Decimal.zero
  | Some i ->
    let bps = if e.settlement.crossed then i.fees.taker_bps else i.fees.maker_bps in
    (* Instrument fees are configured as float basis points in the engine. *)
    (Decimal.of_float [@alert "-lossy"]) (bps /. 10_000.)
;;

let execution ?category t (e : Exchange_core_engine.Execution.t) =
  let order_id = Orders.order_id t.orders (Exchange_core_engine.Execution.order_id e) in
  Adapt.execution ?category ~order_id ~fee_rate:(fee_rate t e) e
;;

let executions ?symbol ?order_id ?order_link_id t account ~limit =
  Exchange.fills t.exchange account
  |> List.map ~f:(execution t)
  |> List.filter ~f:(fun (e : Execution.t) ->
    Option.for_all symbol ~f:(Symbol.equal e.symbol)
    && Option.for_all order_id ~f:(Order_id.equal e.order_id)
    && Option.for_all order_link_id ~f:(fun link ->
      Option.equal Order_link_id.equal e.order_link_id (Some link)))
  |> Fn.flip List.take limit
;;

let cum_fees t account symbol =
  Exchange.fills t.exchange account
  |> List.filter_map ~f:(fun (e : Exchange_core_engine.Execution.t) ->
    Option.some_if (Symbol.equal e.fill.symbol symbol) e.settlement.fee)
  |> Usd.sum
;;

let mark t symbol = Exchange.mark t.exchange symbol |> Option.value ~default:Price.zero

let position ?category t account symbol =
  let view = Exchange.account_view t.exchange account in
  let time = now t in
  match Exchange_core.Account_view.find_position view symbol with
  | Some p ->
    Adapt.position
      ?category
      ~cum_fees:(cum_fees t account symbol)
      ~mark:(mark t symbol)
      ~time
      p
  | None -> Adapt.flat_position ?category ~mark:(mark t symbol) ~time symbol
;;

let positions ?symbol t account =
  match symbol with
  | Some symbol -> [ position t account symbol ]
  | None ->
    (Exchange.account_view t.exchange account).positions
    |> List.map ~f:(fun (p : Exchange_core.Position_view.t) ->
      position t account p.symbol)
;;

let wallet t account = Adapt.wallet (Exchange.account_view t.exchange account)
