open! Core
open! Bybit_protocol
module Account = Exchange_core.Account
module Engine_oid = Exchange_core.Order_id
module Event = Exchange_core_engine.Event
module Notional = Fixed_decimal.Product (Price) (Size) (Usd)

let ms ns = Timestamp_ms.of_int_ms (ns / 1_000_000)

module Order = struct
  type t =
    { id : Order_id.t
    ; account : Account.t
    ; symbol : Symbol.t
    ; side : Side.t
    ; order_link_id : Order_link_id.t option
    ; order_type : Order_type.t
    ; time_in_force : Time_in_force.t
    ; reduce_only : bool
    ; created : int
    ; mutable engine_oid : Engine_oid.t option
    ; mutable amended : bool
    ; mutable price : Price.t
    ; mutable qty : Size.t
    ; mutable cum_exec_qty : Size.t
    ; mutable cum_exec_value : Usd.t
    ; mutable closed_pnl : Usd.t
    ; mutable status : Order_status.t
    ; mutable reject_reason : Reject_reason.t
    ; mutable updated : int
    }

  let id t = t.id
  let account t = t.account
  let symbol t = t.symbol
  let side t = t.side
  let order_link_id t = t.order_link_id
  let order_type t = t.order_type
  let time_in_force t = t.time_in_force
  let price t = t.price
  let qty t = t.qty
  let cum_exec_qty t = t.cum_exec_qty
  let status t = t.status
  let engine_oid t = t.engine_oid
  let is_open t = Order_status.is_open t.status
  let leaves_qty t = if is_open t then Size.(t.qty - t.cum_exec_qty) else Size.zero

  let avg_price t =
    if Size.is_zero t.cum_exec_qty
    then None
    else Some (Notional.div t.cum_exec_value t.cum_exec_qty)
  ;;

  let to_realtime ?(ws = false) t : Realtime_order.t =
    { order_id = t.id
    ; order_link_id = t.order_link_id
    ; symbol = t.symbol
    ; side = t.side
    ; order_type = t.order_type
    ; price = t.price
    ; qty = t.qty
    ; time_in_force = t.time_in_force
    ; order_status = t.status
    ; cum_exec_qty = t.cum_exec_qty
    ; cum_exec_value = t.cum_exec_value
    ; avg_price = avg_price t
    ; leaves_qty = Some (leaves_qty t)
    ; reduce_only = t.reduce_only
    ; reject_reason = t.reject_reason
    ; position_idx = One_way
    ; created_time = ms t.created
    ; updated_time = ms t.updated
    ; category = Option.some_if ws Category.Linear
    ; closed_pnl = Option.some_if ws t.closed_pnl
    }
  ;;
end

type t =
  { closed_history : int
  ; open_by_id : Order.t Order_id.Table.t
  ; open_by_engine : Order.t Engine_oid.Table.t
  ; aliases : Order_id.t Engine_oid.Table.t
  ; closed : Order.t Queue.t Account.Table.t
  ; mutable next_rejected : int
  }

let create ?(closed_history = 500) () =
  { closed_history
  ; open_by_id = Order_id.Table.create ()
  ; open_by_engine = Engine_oid.Table.create ()
  ; aliases = Engine_oid.Table.create ()
  ; closed = Account.Table.create ()
  ; next_rejected = 1
  }
;;

let order_id t engine_oid =
  match Hashtbl.find t.aliases engine_oid with
  | Some id -> id
  | None -> Order_id.of_exchange_core engine_oid
;;

let new_order ~id ~account ~engine_oid (p : Create_order.Params.t) ~time ~status : Order.t
  =
  { id
  ; account
  ; symbol = p.symbol
  ; side = p.side
  ; order_link_id = p.order_link_id
  ; order_type = p.order_type
  ; time_in_force = Adapt.time_in_force p
  ; reduce_only = Option.value p.reduce_only ~default:false
  ; created = time
  ; engine_oid
  ; amended = false
  ; price = Option.value p.price ~default:Price.zero
  ; qty = p.qty
  ; cum_exec_qty = Size.zero
  ; cum_exec_value = Usd.zero
  ; closed_pnl = Usd.zero
  ; status
  ; reject_reason = No_error
  ; updated = time
  }
;;

let close t (o : Order.t) =
  Hashtbl.remove t.open_by_id o.id;
  Option.iter o.engine_oid ~f:(Hashtbl.remove t.open_by_engine);
  let q = Hashtbl.find_or_add t.closed o.account ~default:Queue.create in
  Queue.enqueue q o;
  while Queue.length q > t.closed_history do
    ignore (Queue.dequeue_exn q : Order.t)
  done
;;

let placed t account p engine_oid ~time =
  let o =
    new_order
      ~id:(Order_id.of_exchange_core engine_oid)
      ~account
      ~engine_oid:(Some engine_oid)
      p
      ~time
      ~status:New
  in
  Hashtbl.set t.open_by_id ~key:o.id ~data:o;
  Hashtbl.set t.open_by_engine ~key:engine_oid ~data:o;
  o
;;

let rejected t account p reason ~time =
  let n = t.next_rejected in
  t.next_rejected <- n + 1;
  let id = Order_id.of_string (sprintf "00000000-0000-4000-8000-%012x" n) in
  let o = new_order ~id ~account ~engine_oid:None p ~time ~status:Cancelled in
  o.reject_reason <- reason;
  close t o;
  o
;;

let amended t (o : Order.t) ~engine_oid ~qty ~price ~time =
  Option.iter o.engine_oid ~f:(Hashtbl.remove t.open_by_engine);
  o.engine_oid <- Some engine_oid;
  o.amended <- true;
  o.qty <- qty;
  o.price <- price;
  o.updated <- time;
  Hashtbl.set t.aliases ~key:engine_oid ~data:o.id;
  Hashtbl.set t.open_by_engine ~key:engine_oid ~data:o
;;

let cancelled t (o : Order.t) ~time =
  if Order.is_open o
  then (
    o.status <- Cancelled;
    o.updated <- time;
    close t o)
;;

let apply_fill
  t
  oid
  (fill : Order_book.Fill.t)
  (s : Exchange_core_engine.Clearinghouse.Settlement.t)
  =
  match Hashtbl.find t.open_by_engine oid with
  | None -> None
  | Some (o : Order.t) ->
    o.cum_exec_qty <- Size.(o.cum_exec_qty + fill.sz);
    o.cum_exec_value <- Usd.(o.cum_exec_value + Notional.mul fill.px fill.sz);
    o.closed_pnl <- Usd.(o.closed_pnl + s.change.closed_pnl);
    o.status <- Partially_filled;
    o.updated <- fill.time;
    Some o
;;

let apply t (event : Event.t) =
  let find (order : Exchange_core.Open_order.t) =
    Hashtbl.find t.open_by_engine order.order_id
  in
  (* The engine's original size of a first incarnation corrects the requested qty, e.g.
     after reduce-only clipping. *)
  let sync_qty (o : Order.t) (order : Exchange_core.Open_order.t) =
    o.price <- order.px;
    if not o.amended then Option.iter order.orig_size ~f:(fun s -> o.qty <- s)
  in
  match event with
  | Fill { fill; taker; maker } ->
    List.filter_opt
      [ apply_fill t fill.taker_oid fill taker; apply_fill t fill.maker_oid fill maker ]
  | Order_accepted { order; time; _ } ->
    (match find order with
     | None -> []
     | Some o ->
       sync_qty o order;
       o.status <- (if Size.is_zero o.cum_exec_qty then New else Partially_filled);
       o.updated <- time;
       [ o ])
  | Order_filled { order; time; _ } ->
    (match find order with
     | None -> []
     | Some o ->
       if Option.is_some order.orig_size then sync_qty o order;
       o.status <- Filled;
       o.updated <- time;
       close t o;
       [ o ])
  | Order_cancelled { reason = Modified; _ } -> []
  | Order_cancelled { order; reason; time; _ } ->
    (match find order with
     | None -> []
     | Some o ->
       o.status <- Cancelled;
       (match reason with
        | Self_trade -> o.reject_reason <- By_self_match
        | User | Modified | Ioc_unfilled | Liquidated -> ());
       o.updated <- time;
       close t o;
       [ o ])
  | Order_rejected _ | Liquidation _ | Funding _ -> []
;;

let newest_first orders =
  List.sort orders ~compare:(fun (a : Order.t) (b : Order.t) ->
    Comparable.lift
      [%compare: int * Order_id.t]
      ~f:(fun (o : Order.t) -> o.created, o.id)
      b
      a)
;;

let open_orders t account =
  Hashtbl.data t.open_by_id
  |> List.filter ~f:(fun (o : Order.t) -> Account.equal o.account account)
  |> newest_first
;;

let closed_orders t account =
  match Hashtbl.find t.closed account with
  | None -> []
  | Some q -> List.rev (Queue.to_list q)
;;

let find_open t account key =
  match key with
  | `Id id ->
    Hashtbl.find t.open_by_id id
    |> Option.filter ~f:(fun (o : Order.t) -> Account.equal o.account account)
  | `Link link ->
    open_orders t account
    |> List.find ~f:(fun (o : Order.t) ->
      Option.equal Order_link_id.equal o.order_link_id (Some link))
;;
