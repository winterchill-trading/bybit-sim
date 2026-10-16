open! Core
open! Async
open! Bybit_protocol
module Exchange = Exchange_core_engine.Exchange
module Event = Exchange_core_engine.Event
module Market_sim = Exchange_core_engine.Market_sim
module Account = Exchange_core.Account
module Api_error = Adapt.Api_error

module Config = struct
  type t =
    { initial_balance : Usd.t
    ; book_interval : Time_ns.Span.t
    ; ticker_interval : Time_ns.Span.t
    ; step_interval : Time_ns.Span.t
    }
  [@@deriving sexp_of]

  let default =
    { initial_balance = Usd.of_int 1_000_000
    ; book_interval = Time_ns.Span.of_int_ms 20
    ; ticker_interval = Time_ns.Span.of_int_ms 100
    ; step_interval = Time_ns.Span.second
    }
  ;;
end

module Conn = struct
  type kind =
    | Public
    | Private

  type t =
    { id : int
    ; conn_id : string
    ; kind : kind
    ; send : string Pipe.Writer.t
    ; mutable topics : Topic.t list
    ; mutable account : Account.t option
    }

  let subscribed t topic = List.mem t.topics topic ~equal:Topic.equal
end

(* Shared state of one orderbook topic: what its subscribers have been sent. *)
module Book_topic = struct
  type t =
    { depth : int
    ; symbol : Symbol.t
    ; mutable last : Exchange_core.L2.t
    ; mutable u : int
    }
end

type t =
  { venue : Venue.t
  ; config : Config.t
  ; now : unit -> int
  ; seen : Account.Hash_set.t
  ; conns : Conn.t Int.Table.t
  ; mutable next_conn_id : int
  ; mutable next_push_id : int
  ; book_topics : Book_topic.t String.Table.t
  ; dirty_books : Symbol.Hash_set.t
  ; mutable book_flush_scheduled : bool
  ; tickers : Ws_ticker.Data.t Symbol.Table.t (* last pushed per symbol *)
  ; mutable step_hooks : (now:int -> unit) list (* in registration order *)
  ; extra_routes : (unit -> Yojson.Safe.t) String.Table.t
  }

let wall_clock () = Time_ns.now () |> Time_ns.to_int_ns_since_epoch
let config t = t.config
let venue t = t.venue
let exchange t = Venue.exchange t.venue
let num_ws_connections t = Hashtbl.length t.conns
let now_ms t = t.now () / 1_000_000

let step_clock t =
  let now = t.now () in
  if now > Exchange.now (exchange t) then Exchange.step (exchange t) ~now
;;

let create ?(config = Config.default) ?(now = wall_clock) exchange =
  let t =
    { venue = Venue.create exchange
    ; config
    ; now
    ; seen = Account.Hash_set.create ()
    ; conns = Int.Table.create ()
    ; next_conn_id = 0
    ; next_push_id = 0
    ; book_topics = String.Table.create ()
    ; dirty_books = Symbol.Hash_set.create ()
    ; book_flush_scheduled = false
    ; tickers = Symbol.Table.create ()
    ; step_hooks = []
    ; extra_routes = String.Table.create ()
    }
  in
  step_clock t;
  ignore (Venue.drain t.venue : Venue.Output.t);
  t
;;

let ensure_account t account =
  if not (Hash_set.mem t.seen account)
  then (
    Hash_set.add t.seen account;
    Exchange.deposit (exchange t) account t.config.initial_balance;
    Log.Global.debug_s
      [%message
        "credited initial balance"
          (account : Account.t)
          ~usdt:(t.config.initial_balance : Usd.t)])
;;

(* Websocket fan-out *)

let encode msg = Yojson.Safe.to_string (Ws_message.yojson_of_t msg)
let send (conn : Conn.t) msg = Pipe.write_without_pushback_if_open conn.send (encode msg)

let broadcast t topic msg =
  let subscribers =
    Hashtbl.data t.conns |> List.filter ~f:(fun c -> Conn.subscribed c topic)
  in
  if not (List.is_empty subscribers)
  then (
    let text = encode msg in
    List.iter subscribers ~f:(fun (c : Conn.t) ->
      Pipe.write_without_pushback_if_open c.send text))
;;

let book_snapshot t (bt : Book_topic.t) : Ws_message.t =
  Orderbook
    { topic = Orderbook { depth = bt.depth; symbol = bt.symbol }
    ; type_ = Snapshot
    ; ts = Adapt.ms (t.now ())
    ; data =
        { s = bt.symbol
        ; b = Adapt.book_levels bt.last.bids
        ; a = Adapt.book_levels bt.last.asks
        ; u = bt.u
        ; seq = Venue.book_seq t.venue bt.symbol
        }
    ; cts = Some (Adapt.ms bt.last.time)
    }
;;

let current_book t (bt : Book_topic.t) =
  Exchange.l2 ~n_levels:bt.depth (exchange t) bt.symbol |> Option.value ~default:bt.last
;;

let flush_book_topic t (bt : Book_topic.t) =
  let next = current_book t bt in
  let topic : Topic.t = Orderbook { depth = bt.depth; symbol = bt.symbol } in
  if bt.depth = 1
  then (
    if not
         ([%equal: Exchange_core.L2.Level.t list * Exchange_core.L2.Level.t list]
            (bt.last.bids, bt.last.asks)
            (next.bids, next.asks))
    then (
      bt.last <- next;
      bt.u <- bt.u + 1;
      broadcast t topic (book_snapshot t bt)))
  else (
    let bids, asks = Adapt.orderbook_delta ~prev:bt.last next in
    if not (List.is_empty bids && List.is_empty asks)
    then (
      bt.last <- next;
      bt.u <- bt.u + 1;
      broadcast
        t
        topic
        (Orderbook
           { topic
           ; type_ = Delta
           ; ts = Adapt.ms (t.now ())
           ; data =
               { s = bt.symbol
               ; b = bids
               ; a = asks
               ; u = bt.u
               ; seq = Venue.book_seq t.venue bt.symbol
               }
           ; cts = Some (Adapt.ms next.time)
           })))
;;

let flush_symbol_books t symbol =
  Hash_set.remove t.dirty_books symbol;
  Hashtbl.data t.book_topics
  |> List.filter ~f:(fun (bt : Book_topic.t) -> Symbol.equal bt.symbol symbol)
  |> List.sort ~compare:(fun (a : Book_topic.t) b -> Int.compare a.depth b.depth)
  |> List.iter ~f:(flush_book_topic t)
;;

let flush_books t =
  t.book_flush_scheduled <- false;
  Hash_set.to_list t.dirty_books
  |> List.sort ~compare:Symbol.compare
  |> List.iter ~f:(flush_symbol_books t)
;;

let schedule_book_flush t =
  if (not t.book_flush_scheduled) && not (Hash_set.is_empty t.dirty_books)
  then (
    t.book_flush_scheduled <- true;
    Clock_ns.run_after t.config.book_interval (fun () -> flush_books t) ())
;;

let fresh_ticker t symbol =
  (Venue.tickers ~symbol t.venue).list |> List.hd |> Option.map ~f:Adapt.ws_ticker_data
;;

let ticker_message t (data : Ws_ticker.Data.t) type_ : Ws_message.t =
  Ticker
    { topic = Tickers data.symbol
    ; type_
    ; data
    ; cs = Some (Venue.book_seq t.venue data.symbol)
    ; ts = Adapt.ms (t.now ())
    }
;;

let flush_ticker t symbol =
  match Hashtbl.find t.tickers symbol, fresh_ticker t symbol with
  | Some prev, Some next ->
    Option.iter (Adapt.ticker_delta ~prev next) ~f:(fun delta ->
      Hashtbl.set t.tickers ~key:symbol ~data:next;
      broadcast t (Tickers symbol) (ticker_message t delta Delta))
  | None, Some next -> Hashtbl.set t.tickers ~key:symbol ~data:next
  | _, None -> ()
;;

(* Private pushes *)

let private_subscribers t account ~matches =
  Hashtbl.data t.conns
  |> List.concat_map ~f:(fun (c : Conn.t) ->
    match c.account with
    | Some a when Account.equal a account ->
      List.filter_map c.topics ~f:(fun topic -> Option.some_if (matches topic) (c, topic))
    | _ -> [])
;;

let push_private t account ~matches ~make =
  List.iter (private_subscribers t account ~matches) ~f:(fun (conn, topic) ->
    t.next_push_id <- t.next_push_id + 1;
    let id = sprintf "sim-%d" t.next_push_id in
    let creation_time = Timestamp_ms.of_int_ms (now_ms t) in
    send conn (make ~id ~topic ~creation_time))
;;

let has_private_subscriber t account =
  Hashtbl.exists t.conns ~f:(fun (c : Conn.t) ->
    Option.equal Account.equal c.account (Some account) && not (List.is_empty c.topics))
;;

(* Groups [(key, value)] pairs by key, keys in order of first appearance. *)
let group_by_account pairs =
  let order = ref [] in
  let tbl = Account.Table.create () in
  List.iter pairs ~f:(fun (key, data) ->
    if not (Hashtbl.mem tbl key) then order := key :: !order;
    Hashtbl.add_multi tbl ~key ~data);
  List.rev_map !order ~f:(fun key -> key, List.rev (Hashtbl.find_multi tbl key))
;;

let is_order : Topic.t -> bool = function
  | Order (None | Some Linear) -> true
  | _ -> false
;;

let is_execution : Topic.t -> bool = function
  | Execution (None | Some Linear) -> true
  | _ -> false
;;

let is_position : Topic.t -> bool = function
  | Position (None | Some Linear) -> true
  | _ -> false
;;

let is_wallet : Topic.t -> bool = function
  | Wallet -> true
  | _ -> false
;;

let publish_private t (out : Venue.Output.t) =
  List.map out.orders ~f:(fun o -> Orders.Order.account o, o)
  |> group_by_account
  |> List.iter ~f:(fun (account, orders) ->
    push_private t account ~matches:is_order ~make:(fun ~id ~topic ~creation_time ->
      Ws_message.Order
        { id
        ; topic
        ; creation_time
        ; data = List.map orders ~f:(Orders.Order.to_realtime ~ws:true)
        }));
  let executions =
    List.concat_map out.events ~f:(fun event ->
      match Event.executions event with
      | Some (taker, maker) ->
        [ taker.settlement.account, taker; maker.settlement.account, maker ]
      | None -> [])
    |> List.filter ~f:(fun (account, _) -> has_private_subscriber t account)
  in
  group_by_account executions
  |> List.iter ~f:(fun (account, execs) ->
    push_private t account ~matches:is_execution ~make:(fun ~id ~topic ~creation_time ->
      Ws_message.Execution
        { id
        ; topic
        ; creation_time
        ; data = List.map execs ~f:(Venue.execution ~category:Linear t.venue)
        }));
  let touched =
    List.concat_map out.events ~f:(fun (event : Event.t) ->
      match event with
      | Fill { fill; _ } -> [ fill.taker, fill.symbol; fill.maker, fill.symbol ]
      | Liquidation { liquidation = l; _ } -> [ l.account, l.symbol ]
      | Funding { payments; symbol; _ } ->
        List.map
          payments
          ~f:(fun (p : Exchange_core_engine.Clearinghouse.Funding_payment.t) ->
            p.account, symbol)
      | Order_accepted _ | Order_rejected _ | Order_filled _ | Order_cancelled _ -> [])
    |> List.filter ~f:(fun (account, _) -> has_private_subscriber t account)
    |> List.dedup_and_sort ~compare:[%compare: Account.t * Symbol.t]
  in
  group_by_account touched
  |> List.iter ~f:(fun (account, symbols) ->
    push_private t account ~matches:is_position ~make:(fun ~id ~topic ~creation_time ->
      Ws_message.Position
        { id
        ; topic
        ; creation_time
        ; data = List.map symbols ~f:(Venue.position ~category:Linear t.venue account)
        });
    push_private t account ~matches:is_wallet ~make:(fun ~id ~topic ~creation_time ->
      Ws_message.Wallet
        { id; topic; creation_time; data = [ Venue.wallet t.venue account ] }))
;;

let log_event (event : Event.t) =
  match event with
  | Fill { fill; _ } ->
    Log.Global.info
      "fill %s %s %s@%s taker=%s maker=%s tid=%s"
      (Symbol.to_string fill.symbol)
      (Side.to_wire fill.taker_side)
      (Size.to_string fill.sz)
      (Price.to_string fill.px)
      (Account.to_string fill.taker)
      (Account.to_string fill.maker)
      (Exchange_core.Trade_id.to_string fill.tid)
  | Liquidation { liquidation = l; _ } ->
    Log.Global.info
      "liquidation %s %s %s@%s pnl=%s"
      (Account.to_string l.account)
      (Symbol.to_string l.symbol)
      (Size.to_string l.size)
      (Price.to_string l.px)
      (Usd.to_string l.pnl)
  | Order_accepted _ | Order_rejected _ | Order_filled _ | Order_cancelled _ | Funding _
    -> Log.Global.debug_s [%sexp (event : Event.t)]
;;

let publish t =
  let out = Venue.drain t.venue in
  List.iter out.events ~f:(fun event ->
    log_event event;
    Option.iter (Event.book_symbol event) ~f:(Hash_set.add t.dirty_books));
  List.map out.trades ~f:(fun (trade : Public_trade.Trade.t) -> trade.symbol, trade)
  |> List.fold ~init:Symbol.Map.empty ~f:(fun acc (key, data) ->
    Map.add_multi acc ~key ~data)
  |> Map.iteri ~f:(fun ~key:symbol ~data ->
    broadcast
      t
      (Public_trade symbol)
      (Public_trade
         { topic = Public_trade symbol
         ; type_ = Snapshot
         ; ts = Adapt.ms (t.now ())
         ; data = List.rev data
         }));
  publish_private t out;
  schedule_book_flush t
;;

let on_step t f = t.step_hooks <- t.step_hooks @ [ f ]
let add_route t ~path f = Hashtbl.set t.extra_routes ~key:path ~data:f

let mutate t ~f =
  step_clock t;
  if not (List.is_empty t.step_hooks)
  then (
    let now = Exchange.now (exchange t) in
    List.iter t.step_hooks ~f:(fun hook -> hook ~now));
  let result = f t.venue in
  Venue.sync t.venue;
  publish t;
  result
;;

(* Websocket requests *)

let op_response ?success ?ret_msg ?req_id ?args (conn : Conn.t) op : Op_response.t =
  { success; ret_msg; conn_id = Some conn.conn_id; req_id; op; args }
;;

let known_symbol t symbol = Option.is_some (Exchange.instrument (exchange t) symbol)

let valid_topic t (conn : Conn.t) (topic : Topic.t) =
  match conn.kind, topic with
  | Public, Orderbook { depth; symbol } ->
    List.mem [ 1; 50; 200; 1000 ] depth ~equal:Int.equal && known_symbol t symbol
  | Public, (Public_trade symbol | Tickers symbol) -> known_symbol t symbol
  | Private, (Order c | Execution c | Position c) ->
    (match c with
     | None | Some Linear -> true
     | Some (Inverse | Spot | Option) -> false)
  | Private, Wallet -> true
  | Public, (Order _ | Execution _ | Position _ | Wallet | Other _)
  | Private, (Orderbook _ | Public_trade _ | Tickers _ | Other _) -> false
;;

let subscribe_snapshot t conn (topic : Topic.t) =
  match topic with
  | Orderbook { depth; symbol } ->
    let key = Topic.to_string topic in
    let bt =
      Hashtbl.find_or_add t.book_topics key ~default:(fun () ->
        let empty : Exchange_core.L2.t =
          { symbol; time = Exchange.now (exchange t); bids = []; asks = [] }
        in
        let bt = { Book_topic.depth; symbol; last = empty; u = 1 } in
        bt.last <- current_book t bt;
        bt)
    in
    send conn (book_snapshot t bt)
  | Tickers symbol ->
    if not (Hashtbl.mem t.tickers symbol) then flush_ticker t symbol;
    Option.iter (Hashtbl.find t.tickers symbol) ~f:(fun data ->
      send conn (ticker_message t data Snapshot))
  | Public_trade _ | Order _ | Execution _ | Position _ | Wallet | Other _ -> ()
;;

let handle_subscribe t (conn : Conn.t) ~req_id ~op ~args ~subscribe =
  let ok_msg =
    match conn.kind with
    | Public -> op
    | Private -> ""
  in
  match conn.kind, conn.account with
  | Private, None ->
    send
      conn
      (Subscribe_ack
         (op_response conn op ?req_id ~success:false ~ret_msg:"Request not authorized"))
  | _ ->
    (match List.find args ~f:(fun topic -> not (valid_topic t conn topic)) with
     | Some bad ->
       send
         conn
         (Subscribe_ack
            (op_response
               conn
               op
               ?req_id
               ~success:false
               ~ret_msg:(sprintf "error:handler not found,topic:%s" (Topic.to_string bad))))
     | None ->
       (* Bring existing subscribers up to date first, so that a new subscriber's first
          book or ticker message is its snapshot. *)
       if subscribe
       then
         List.iter args ~f:(fun (topic : Topic.t) ->
           match topic with
           | Orderbook { symbol; _ } -> flush_symbol_books t symbol
           | Tickers symbol -> flush_ticker t symbol
           | _ -> ());
       if subscribe
       then
         conn.topics
         <- conn.topics
            @ List.filter args ~f:(fun topic -> not (Conn.subscribed conn topic))
       else
         conn.topics
         <- List.filter conn.topics ~f:(fun topic ->
              not (List.mem args topic ~equal:Topic.equal));
       Log.Global.debug_s
         [%message "ws subscription" ~conn:(conn.id : int) op (args : Topic.t list)];
       send
         conn
         (Subscribe_ack (op_response conn op ?req_id ~success:true ~ret_msg:ok_msg));
       if subscribe then List.iter args ~f:(subscribe_snapshot t conn))
;;

let handle_ws_message t (conn : Conn.t) text =
  match Ws_request.t_of_yojson (Yojson.Safe.from_string text) with
  | exception _ ->
    Log.Global.debug "ws %d: invalid message %s" conn.id text;
    send
      conn
      (Op_response
         (op_response conn "" ~success:false ~ret_msg:("error:invalid request: " ^ text)))
  | Ping { req_id } ->
    (match conn.kind with
     | Public ->
       send
         conn
         (Pong
            (op_response
               conn
               "ping"
               ~success:true
               ~ret_msg:"pong"
               ~req_id:(Option.value req_id ~default:"")))
     | Private ->
       send
         conn
         (Pong (op_response conn "pong" ?req_id ~args:[ Int.to_string (now_ms t) ])))
  | Subscribe { req_id; args } ->
    handle_subscribe t conn ~req_id ~op:"subscribe" ~args ~subscribe:true
  | Unsubscribe { req_id; args } ->
    handle_subscribe t conn ~req_id ~op:"unsubscribe" ~args ~subscribe:false
  | Auth { req_id; api_key; expires; signature = _ } ->
    let fail msg =
      send conn (Auth_ack (op_response conn "auth" ?req_id ~success:false ~ret_msg:msg))
    in
    (match conn.kind with
     | Public -> fail "error:auth is only available on the private stream"
     | Private ->
       if String.is_empty api_key
       then fail "error:apiKey is empty"
       else if expires <= now_ms t
       then fail "error:expires is in the past"
       else (
         let account = Account.of_string api_key in
         ensure_account t account;
         conn.account <- Some account;
         send conn (Auth_ack (op_response conn "auth" ?req_id ~success:true ~ret_msg:""))))
;;

let handle_ws t kind reader writer =
  let ws = Websocket.create ~opcode:`Text ~role:Server reader writer in
  let incoming, outgoing = Websocket.pipes ws in
  let id = t.next_conn_id in
  t.next_conn_id <- id + 1;
  let conn =
    { Conn.id
    ; conn_id = sprintf "sim-conn-%d" id
    ; kind
    ; send = outgoing
    ; topics = []
    ; account = None
    }
  in
  Hashtbl.set t.conns ~key:id ~data:conn;
  Log.Global.debug "ws %d: connected" id;
  let%map () = Pipe.iter_without_pushback incoming ~f:(handle_ws_message t conn) in
  Hashtbl.remove t.conns id;
  Pipe.close outgoing;
  Log.Global.debug "ws %d: disconnected" id
;;

(* REST *)

let error_message = function
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure msg, _) | Failure msg -> msg
  | Yojson.Json_error msg -> msg
  | exn -> Exn.to_string exn
;;

let params_error fmt = ksprintf (fun msg -> Error (Api_error.params msg)) fmt

let decode body ~f =
  match f (Yojson.Safe.from_string body) with
  | exception exn -> params_error "params error: %s" (error_message exn)
  | x -> Ok x
;;

let query uri name =
  Uri.get_query_param uri name |> Option.filter ~f:(fun s -> not (String.is_empty s))
;;

let int_query uri name ~default ~min ~max =
  match query uri name with
  | None -> Ok default
  | Some s ->
    (match Int.of_string_opt s with
     | Some n when n >= min && n <= max -> Ok n
     | _ -> params_error "params error: %s must be an integer in [%d, %d]" name min max)
;;

let require_linear uri =
  match query uri "category" with
  | Some "linear" -> Ok ()
  | Some _ -> params_error "params error: only category=linear is simulated"
  | None -> params_error "params error: category is required"
;;

let header headers name =
  Cohttp.Header.get headers name |> Option.filter ~f:(fun s -> not (String.is_empty s))
;;

let authenticate t headers =
  let now = now_ms t in
  match header headers "x-bapi-api-key" with
  | None ->
    Error
      { Api_error.code = Invalid_api_key
      ; msg = "API key is invalid. (X-BAPI-API-KEY header is missing)"
      }
  | Some key ->
    let recv_window =
      Option.bind (header headers "x-bapi-recv-window") ~f:Int.of_string_opt
      |> Option.value ~default:5000
    in
    (match Option.bind (header headers "x-bapi-timestamp") ~f:Int.of_string_opt with
     | Some ts when ts >= now - recv_window && ts < now + 1000 ->
       let account = Account.of_string key in
       ensure_account t account;
       Ok account
     | ts ->
       Error
         { code = Request_time_out_of_window
         ; msg =
             sprintf
               "invalid request, please check your server timestamp or recv_window \
                param. req_timestamp[%s],server_timestamp[%d],recv_window[%d]"
               (Option.value_map ts ~default:"" ~f:Int.to_string)
               now
               recv_window
         })
;;

let symbol_query uri = query uri "symbol" |> Option.map ~f:Symbol.of_string

let page list ~f =
  `Assoc
    [ "category", `String "linear"
    ; "list", `List (List.map list ~f)
    ; "nextPageCursor", `String ""
    ]
;;

let require_one_of uri names =
  if List.exists names ~f:(fun n -> Option.is_some (query uri n))
  then Ok ()
  else params_error "params error: one of %s is required" (String.concat ~sep:", " names)
;;

let market_time t =
  let ns = t.now () in
  `Assoc
    [ "timeSecond", `String (Int.to_string (ns / 1_000_000_000))
    ; "timeNano", `String (Int.to_string ns)
    ]
;;

let get_public t path uri =
  let open Result.Let_syntax in
  match path with
  | "/v5/market/time" -> Some (Ok (market_time t))
  | "/v5/market/instruments-info" ->
    Some
      (let%map () = require_linear uri in
       Instruments_info.yojson_of_t
         (Adapt.instruments_info ?symbol:(symbol_query uri) (exchange t)))
  | "/v5/market/orderbook" ->
    Some
      (let%bind () = require_linear uri in
       let%bind limit = int_query uri "limit" ~default:25 ~min:1 ~max:1000 in
       let%bind symbol =
         match symbol_query uri with
         | Some s -> Ok s
         | None -> params_error "params error: symbol is required"
       in
       match Venue.orderbook ~limit t.venue symbol with
       | Some book -> Ok (Orderbook.yojson_of_t book)
       | None -> params_error "params error: symbol invalid")
  | "/v5/market/tickers" ->
    Some
      (let%bind () = require_linear uri in
       let symbol = symbol_query uri in
       let%bind () =
         match symbol with
         | Some s when not (known_symbol t s) ->
           params_error "params error: symbol invalid"
         | _ -> Ok ()
       in
       Ok (Tickers.yojson_of_t (Venue.tickers ?symbol t.venue)))
  | _ -> None
;;

let get_private t account path uri =
  let open Result.Let_syntax in
  let order_id = query uri "orderId" |> Option.map ~f:Order_id.of_string in
  let order_link_id = query uri "orderLinkId" |> Option.map ~f:Order_link_id.of_string in
  let symbol = symbol_query uri in
  match path with
  | "/v5/order/realtime" ->
    Some
      (let%bind () = require_linear uri in
       let%bind () = require_one_of uri [ "symbol"; "baseCoin"; "settleCoin" ] in
       let%bind open_only = int_query uri "openOnly" ~default:0 ~min:0 ~max:2 in
       let%map limit = int_query uri "limit" ~default:20 ~min:1 ~max:50 in
       Venue.realtime
         ?symbol
         ?order_id
         ?order_link_id
         t.venue
         account
         ~open_only:(open_only = 0)
         ~limit
       |> List.filter ~f:(fun (o : Realtime_order.t) ->
         Option.for_all
           (query uri "baseCoin")
           ~f:(String.equal (Adapt.base_coin o.symbol)))
       |> page ~f:Realtime_order.yojson_of_t)
  | "/v5/execution/list" ->
    Some
      (let%bind () = require_linear uri in
       let%map limit = int_query uri "limit" ~default:50 ~min:1 ~max:100 in
       Venue.executions ?symbol ?order_id ?order_link_id t.venue account ~limit
       |> page ~f:Execution.yojson_of_t)
  | "/v5/position/list" ->
    Some
      (let%bind () = require_linear uri in
       let%bind () = require_one_of uri [ "symbol"; "settleCoin" ] in
       let%map () =
         match symbol with
         | Some s when not (known_symbol t s) ->
           params_error "params error: symbol invalid"
         | _ -> Ok ()
       in
       Venue.positions ?symbol t.venue account |> page ~f:Position.yojson_of_t)
  | "/v5/account/wallet-balance" ->
    Some
      (match query uri "accountType" with
       | Some "UNIFIED" ->
         let account = Venue.wallet t.venue account in
         let coins =
           match query uri "coin" with
           | None -> account.coin
           | Some coins ->
             let wanted = String.split coins ~on:',' in
             List.filter account.coin ~f:(fun c ->
               List.mem wanted c.coin ~equal:String.equal)
         in
         Ok (Wallet_balance.yojson_of_t { list = [ { account with coin = coins } ] })
       | _ -> params_error "params error: accountType only supports UNIFIED")
  | _ -> None
;;

let ack_json = Result.map ~f:Order_ack.yojson_of_t

let post_private t account path body =
  let open Result.Let_syntax in
  let run f = Some (mutate t ~f) in
  match path with
  | "/v5/order/create" ->
    run (fun venue ->
      let%bind req = decode body ~f:Create_order.Request.t_of_yojson in
      let%bind () =
        match req.category with
        | Linear -> Ok ()
        | _ -> params_error "params error: only category=linear is simulated"
      in
      Venue.create_order venue account req.params
      |> ack_json
      |> Result.map ~f:(fun r -> r, None))
  | "/v5/order/create-batch" ->
    run (fun venue ->
      let%bind req = decode body ~f:Create_batch.Request.t_of_yojson in
      let%bind () =
        match req.category with
        | Linear -> Ok ()
        | _ -> params_error "params error: only category=linear is simulated"
      in
      let%map result, ext = Venue.create_batch venue account req.request in
      ( Create_batch.Response.yojson_of_t result
      , Some (Create_batch.Ext_info.yojson_of_t ext) ))
  | "/v5/order/cancel" ->
    run (fun venue ->
      let%bind req = decode body ~f:Cancel_order.Request.t_of_yojson in
      Venue.cancel_order venue account req |> ack_json |> Result.map ~f:(fun r -> r, None))
  | "/v5/order/cancel-all" ->
    run (fun venue ->
      let%bind req = decode body ~f:Cancel_all.Request.t_of_yojson in
      let%map r = Venue.cancel_all venue account req in
      Cancel_all.Response.yojson_of_t r, None)
  | "/v5/order/amend" ->
    run (fun venue ->
      let%bind req = decode body ~f:Amend_order.Request.t_of_yojson in
      Venue.amend_order venue account req |> ack_json |> Result.map ~f:(fun r -> r, None))
  | _ -> None
;;

let envelope t result : Yojson.Safe.t =
  let env : Yojson.Safe.t Envelope.t =
    match result with
    | Ok (json, ext) ->
      { ret_code = 0
      ; ret_msg = "OK"
      ; result = json
      ; ret_ext_info = Option.value ext ~default:(`Assoc [])
      ; time = Timestamp_ms.of_int_ms (now_ms t)
      }
    | Error (e : Api_error.t) ->
      { ret_code = Envelope.Error.to_code e.code
      ; ret_msg = e.msg
      ; result = `Assoc []
      ; ret_ext_info = `Assoc []
      ; time = Timestamp_ms.of_int_ms (now_ms t)
      }
  in
  Envelope.yojson_of_t Fn.id env
;;

let not_found t path =
  `Not_found, envelope t (Error (Api_error.params (sprintf "route not found: %s" path)))
;;

let private_routes =
  [ `GET, "/v5/order/realtime"
  ; `GET, "/v5/execution/list"
  ; `GET, "/v5/position/list"
  ; `GET, "/v5/account/wallet-balance"
  ; `POST, "/v5/order/create"
  ; `POST, "/v5/order/create-batch"
  ; `POST, "/v5/order/cancel"
  ; `POST, "/v5/order/cancel-all"
  ; `POST, "/v5/order/amend"
  ]
;;

let guard_status t =
  mutate t ~f:(fun venue -> Guard.status ~recent:(Venue.guard_events venue) (exchange t))
;;

(* [POST /sim/reopen?symbol=S]: lifts the halt of [S], or of every halted symbol. *)
let reopen t uri =
  match Option.map (query uri "symbol") ~f:Symbol.of_string with
  | Some symbol when not (known_symbol t symbol) ->
    ( `Bad_request
    , `Assoc [ "error", `String ("unknown symbol " ^ Symbol.to_string symbol) ] )
  | symbol ->
    mutate t ~f:(fun venue -> Exchange.reopen ?symbol (Venue.exchange venue));
    `OK, guard_status t
;;

let handle_http t ~meth ~uri ~headers ~body =
  let path = Uri.path uri in
  let no_ext = Result.map ~f:(fun json -> json, None) in
  let is_private =
    List.exists private_routes ~f:(fun (m, p) -> Poly.equal m meth && String.equal p path)
  in
  match meth with
  | `GET when String.equal path "/sim/guard" -> `OK, guard_status t
  | `POST when String.equal path "/sim/reopen" -> reopen t uri
  | `GET when Hashtbl.mem t.extra_routes path ->
    `OK, (Hashtbl.find_exn t.extra_routes path) ()
  | `GET when not is_private ->
    (match get_public t path uri with
     | Some result -> `OK, envelope t (no_ext result)
     | None -> not_found t path)
  | _ when not is_private -> not_found t path
  | _ ->
    (match authenticate t headers with
     | Error e -> `OK, envelope t (Error e)
     | Ok account ->
       let result =
         match meth with
         | `POST -> post_private t account path body
         | _ ->
           mutate t ~f:(fun _ -> get_private t account path uri) |> Option.map ~f:no_ext
       in
       (match result with
        | Some result -> `OK, envelope t result
        | None -> not_found t path))
;;

let header_is req name value =
  match Cohttp.Header.get (Cohttp.Request.headers req) name with
  | Some v ->
    String.split v ~on:','
    |> List.exists ~f:(fun v -> String.Caseless.equal (String.strip v) value)
  | None -> false
;;

let json_headers = Cohttp.Header.of_list [ "content-type", "application/json" ]

let respond status json =
  let%map response =
    Cohttp_async.Server.respond_string
      ~headers:json_headers
      ~status
      (Yojson.Safe.to_string json)
  in
  `Response response
;;

let ws_upgrade t kind req =
  match
    Cohttp.Request.headers req |> fun h -> Cohttp.Header.get h "sec-websocket-key"
  with
  | None -> respond `Bad_request (`Assoc [ "error", `String "missing Sec-WebSocket-Key" ])
  | Some key ->
    let headers =
      Cohttp.Header.of_list
        [ "upgrade", "websocket"
        ; "connection", "Upgrade"
        ; ( "sec-websocket-accept"
          , Websocket.sec_websocket_accept_header_value ~sec_websocket_key:key )
        ]
    in
    (* [Http.Response.make], unlike [Cohttp.Response.make], does not add
       [transfer-encoding: chunked], which is invalid on a 101. *)
    let response = Http.Response.make ~status:`Switching_protocols ~headers () in
    return (`Expert (response, fun reader writer -> handle_ws t kind reader writer))
;;

let handler t ~body _addr req =
  let uri = Cohttp.Request.uri req in
  match Cohttp.Request.meth req, Uri.path uri with
  | `GET, "/v5/public/linear" when header_is req "upgrade" "websocket" ->
    ws_upgrade t Public req
  | `GET, "/v5/private" when header_is req "upgrade" "websocket" ->
    ws_upgrade t Private req
  | meth, _ ->
    let%bind body = Cohttp_async.Body.to_string body in
    let status, json =
      handle_http t ~meth ~uri ~headers:(Cohttp.Request.headers req) ~body
    in
    respond status json
;;

let listen t ~port =
  Cohttp_async.Server.create_expert
    ~on_handler_error:
      (`Call (fun _ exn -> Log.Global.error_s [%message "handler error" (exn : exn)]))
    (Tcp.Where_to_listen.of_port port)
    (handler t)
;;

let port server = Cohttp_async.Server.listening_on server

let start_periodic t =
  Clock_ns.every t.config.ticker_interval (fun () ->
    Hashtbl.keys t.tickers |> List.iter ~f:(flush_ticker t));
  Clock_ns.every t.config.step_interval (fun () -> mutate t ~f:ignore)
;;

let run_market_sim t sim =
  Clock_ns.every (Market_sim.config sim).tick_interval (fun () ->
    mutate t ~f:(fun _ -> Market_sim.tick sim))
;;
