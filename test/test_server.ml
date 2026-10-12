open! Core
open! Async
open! Bybit_sim

(* A fixed clock keeps every timestamp in the output deterministic. *)
let now () = 1_700_000_000_000_000_000
let now_ms = "1700000000000"

let with_server f =
  Log.Global.set_output [];
  let server = Server.create ~now (Adapt.create_exchange ()) in
  let%bind http = Server.listen server ~port:0 in
  let%bind () = f (Server.port http) in
  Cohttp_async.Server.close http
;;

let auth_headers ?(timestamp = now_ms) key =
  [ "X-BAPI-API-KEY", key; "X-BAPI-TIMESTAMP", timestamp; "X-BAPI-SIGN", "unchecked" ]
;;

let uri port path_and_query =
  Uri.of_string (sprintf "http://127.0.0.1:%d%s" port path_and_query)
;;

let print_response ?(pretty = false) (response, body) =
  let%map body = Cohttp_async.Body.to_string body in
  let body =
    if pretty then Yojson.Safe.pretty_to_string (Yojson.Safe.from_string body) else body
  in
  printf "%d %s\n" (Cohttp.Code.code_of_status (Cohttp.Response.status response)) body
;;

let get ?pretty ?(headers = []) port path =
  Cohttp_async.Client.get ~headers:(Cohttp.Header.of_list headers) (uri port path)
  >>= print_response ?pretty
;;

let post ?(headers = []) port path body =
  Cohttp_async.Client.post
    ~headers:(Cohttp.Header.of_list headers)
    ~body:(Cohttp_async.Body.of_string body)
    (uri port path)
  >>= print_response
;;

let get_as key ?pretty port path = get ?pretty ~headers:(auth_headers key) port path
let post_as key port path body = post ~headers:(auth_headers key) port path body

let limit ?(tif = "GTC") ?link ~side ~px ~qty () =
  sprintf
    {|{"category":"linear","symbol":"BTCUSDT","side":"%s","orderType":"Limit","qty":"%s","price":"%s","timeInForce":"%s"%s}|}
    side
    qty
    px
    tif
    (Option.value_map link ~default:"" ~f:(sprintf {|,"orderLinkId":"%s"|}))
;;

let%expect_test "market endpoints" =
  with_server (fun port ->
    let%bind () = get port "/v5/market/time" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"timeSecond":"1700000000","timeNano":"1700000000000000000"},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get ~pretty:true port "/v5/market/instruments-info?category=linear&symbol=BTCUSDT"
    in
    [%expect
      {|
      200 {
        "retCode": 0,
        "retMsg": "OK",
        "result": {
          "category": "linear",
          "list": [
            {
              "symbol": "BTCUSDT",
              "contractType": "LinearPerpetual",
              "status": "Trading",
              "baseCoin": "BTC",
              "quoteCoin": "USDT",
              "leverageFilter": {
                "minLeverage": "1",
                "maxLeverage": "100",
                "leverageStep": "0.01"
              },
              "priceFilter": {
                "minPrice": "0.1",
                "maxPrice": "1999999.9",
                "tickSize": "0.1"
              },
              "lotSizeFilter": {
                "maxOrderQty": "1000",
                "minOrderQty": "0.001",
                "qtyStep": "0.001",
                "maxMktOrderQty": "500",
                "minNotionalValue": "5"
              }
            }
          ],
          "nextPageCursor": ""
        },
        "retExtInfo": {},
        "time": 1700000000000
      }
      |}];
    let%bind () = get port "/v5/market/instruments-info?category=linear" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"symbol":"BTCUSDT","contractType":"LinearPerpetual","status":"Trading","baseCoin":"BTC","quoteCoin":"USDT","leverageFilter":{"minLeverage":"1","maxLeverage":"100","leverageStep":"0.01"},"priceFilter":{"minPrice":"0.1","maxPrice":"1999999.9","tickSize":"0.1"},"lotSizeFilter":{"maxOrderQty":"1000","minOrderQty":"0.001","qtyStep":"0.001","maxMktOrderQty":"500","minNotionalValue":"5"}},{"symbol":"ETHUSDT","contractType":"LinearPerpetual","status":"Trading","baseCoin":"ETH","quoteCoin":"USDT","leverageFilter":{"minLeverage":"1","maxLeverage":"100","leverageStep":"0.01"},"priceFilter":{"minPrice":"0.01","maxPrice":"1999999.99","tickSize":"0.01"},"lotSizeFilter":{"maxOrderQty":"10000","minOrderQty":"0.01","qtyStep":"0.01","maxMktOrderQty":"5000","minNotionalValue":"5"}},{"symbol":"SOLUSDT","contractType":"LinearPerpetual","status":"Trading","baseCoin":"SOL","quoteCoin":"USDT","leverageFilter":{"minLeverage":"1","maxLeverage":"100","leverageStep":"0.01"},"priceFilter":{"minPrice":"0.01","maxPrice":"1999999.99","tickSize":"0.01"},"lotSizeFilter":{"maxOrderQty":"100000","minOrderQty":"0.1","qtyStep":"0.1","maxMktOrderQty":"50000","minNotionalValue":"5"}}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/orderbook?category=linear&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"s":"BTCUSDT","b":[],"a":[],"ts":1700000000000,"u":0,"seq":0,"cts":1700000000000},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/orderbook?category=linear&symbol=XYZUSDT" in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: symbol invalid","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/orderbook?category=spot&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: only category=linear is simulated","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/tickers?category=linear" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[]},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/nope" in
    [%expect
      {| 404 {"retCode":10001,"retMsg":"route not found: /v5/nope","result":{},"retExtInfo":{},"time":1700000000000} |}];
    return ())
;;

let%expect_test "orders, fills and account endpoints" =
  with_server (fun port ->
    (* The market maker rests a post-only ask. *)
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~tif:"PostOnly" ~link:"mm-1" ~side:"Sell" ~px:"100000" ~qty:"0.01" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":"mm-1"},"retExtInfo":{},"time":1700000000000} |}];
    (* A limit buy crosses it and fills completely. *)
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~side:"Buy" ~px:"100000" ~qty:"0.004" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"2","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/orderbook?category=linear&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"s":"BTCUSDT","b":[],"a":[["100000","0.006"]],"ts":1700000000000,"u":2,"seq":2,"cts":1700000000000},"retExtInfo":{},"time":1700000000000} |}];
    (* A post-only bid that would cross is accepted, then cancelled. *)
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~tif:"PostOnly" ~side:"Buy" ~px:"100000" ~qty:"0.01" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"00000000-0000-4000-8000-000000000001","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    (* Synchronous rejections. *)
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~side:"Buy" ~px:"90000" ~qty:"1000" ())
    in
    [%expect
      {| 200 {"retCode":110007,"retMsg":"Available balance is insufficient","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        {|{"category":"linear","symbol":"XYZUSDT","side":"Buy","orderType":"Market","qty":"1"}|}
    in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: symbol invalid","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~side:"Buy" ~px:"90000.05" ~qty:"0.001" ())
    in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: price must be a positive multiple of tickSize","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~link:"mm-1" ~side:"Sell" ~px:"101000" ~qty:"0.01" ())
    in
    [%expect
      {| 200 {"retCode":110072,"retMsg":"OrderLinkedID is duplicate","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "mm" port "/v5/order/realtime?category=linear&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","orderType":"Limit","price":"100000","qty":"0.01","timeInForce":"PostOnly","orderStatus":"PartiallyFilled","cumExecQty":"0.004","cumExecValue":"400","avgPrice":"100000","leavesQty":"0.006","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get_as "mm" port "/v5/order/realtime?category=linear&symbol=BTCUSDT&openOnly=1"
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","orderType":"Limit","price":"100000","qty":"0.01","timeInForce":"PostOnly","orderStatus":"PartiallyFilled","cumExecQty":"0.004","cumExecValue":"400","avgPrice":"100000","leavesQty":"0.006","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"},{"orderId":"00000000-0000-4000-8000-000000000001","orderLinkId":"","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","price":"100000","qty":"0.01","timeInForce":"PostOnly","orderStatus":"Cancelled","cumExecQty":"0","cumExecValue":"0","avgPrice":"","leavesQty":"0","reduceOnly":false,"rejectReason":"EC_PostOnlyWillTakeLiquidity","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    (* Amending keeps the order id; qty is the new total. *)
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/amend"
        {|{"category":"linear","symbol":"BTCUSDT","orderLinkId":"mm-1","qty":"0.02","price":"100100"}|}
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":"mm-1"},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "mm" port "/v5/order/realtime?category=linear&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","orderType":"Limit","price":"100100","qty":"0.02","timeInForce":"PostOnly","orderStatus":"PartiallyFilled","cumExecQty":"0.004","cumExecValue":"400","avgPrice":"100000","leavesQty":"0.016","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "mm" port "/v5/execution/list?category=linear" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"execId":"1","orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","execPrice":"100000","execQty":"0.004","execValue":"400","execFee":"0.08","feeRate":"0.0002","execType":"Trade","isMaker":true,"execTime":"1700000000000","closedSize":"","seq":1}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "taker" port "/v5/execution/list?category=linear" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"execId":"1","orderId":"2","orderLinkId":"","symbol":"BTCUSDT","side":"Buy","execPrice":"100000","execQty":"0.004","execValue":"400","execFee":"0.22","feeRate":"0.00055","execType":"Trade","isMaker":false,"execTime":"1700000000000","closedSize":"","seq":1}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get_as "taker" port "/v5/position/list?category=linear&symbol=BTCUSDT"
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"positionIdx":0,"symbol":"BTCUSDT","side":"Buy","size":"0.004","avgPrice":"100000","positionValue":"400","unrealisedPnl":"0","cumRealisedPnl":"-0.22","leverage":"10","liqPrice":"","markPrice":"100000","positionStatus":"Normal","createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get_as "taker" port "/v5/position/list?category=linear&symbol=ETHUSDT"
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"positionIdx":0,"symbol":"ETHUSDT","side":"","size":"0","avgPrice":"0","positionValue":"0","unrealisedPnl":"0","cumRealisedPnl":"0","leverage":"","liqPrice":"","markPrice":"0","positionStatus":"Normal","createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "taker" port "/v5/position/list?category=linear" in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: one of symbol, settleCoin is required","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "taker" port "/v5/account/wallet-balance?accountType=UNIFIED" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"list":[{"accountType":"UNIFIED","totalEquity":"999999.78","totalWalletBalance":"999999.78","totalMarginBalance":"999999.78","totalAvailableBalance":"999959.78","totalPerpUPL":"0","totalInitialMargin":"40","totalMaintenanceMargin":"2","coin":[{"coin":"USDT","walletBalance":"999999.78","equity":"999999.78","unrealisedPnl":"0","usdValue":"999999.78","locked":"0"}]}]},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/cancel"
        {|{"category":"linear","symbol":"BTCUSDT","orderLinkId":"mm-1"}|}
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":"mm-1"},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/cancel"
        {|{"category":"linear","symbol":"BTCUSDT","orderId":"1"}|}
    in
    [%expect
      {| 200 {"retCode":110001,"retMsg":"Order does not exist","result":{},"retExtInfo":{},"time":1700000000000} |}];
    return ())
;;

let%expect_test "time in force and market orders" =
  with_server (fun port ->
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~side:"Sell" ~px:"100000" ~qty:"0.01" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    (* FOK for more than the book holds: accepted, then cancelled. *)
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~tif:"FOK" ~side:"Buy" ~px:"100000" ~qty:"0.02" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"00000000-0000-4000-8000-000000000001","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    (* IOC fills what it can; the rest is cancelled. *)
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~tif:"IOC" ~side:"Buy" ~px:"100000" ~qty:"0.02" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"2","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    (* A market sell with no bids. *)
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        {|{"category":"linear","symbol":"BTCUSDT","side":"Sell","orderType":"Market","qty":"0.001"}|}
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"00000000-0000-4000-8000-000000000002","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get_as "taker" port "/v5/order/realtime?category=linear&symbol=BTCUSDT&openOnly=1"
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"orderId":"00000000-0000-4000-8000-000000000002","orderLinkId":"","symbol":"BTCUSDT","side":"Sell","orderType":"Market","price":"0","qty":"0.001","timeInForce":"IOC","orderStatus":"Cancelled","cumExecQty":"0","cumExecValue":"0","avgPrice":"","leavesQty":"0","reduceOnly":false,"rejectReason":"EC_NoImmediateQtyToFill","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"},{"orderId":"2","orderLinkId":"","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","price":"100000","qty":"0.02","timeInForce":"IOC","orderStatus":"Cancelled","cumExecQty":"0.01","cumExecValue":"1000","avgPrice":"100000","leavesQty":"0","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"},{"orderId":"00000000-0000-4000-8000-000000000001","orderLinkId":"","symbol":"BTCUSDT","side":"Buy","orderType":"Limit","price":"100000","qty":"0.02","timeInForce":"FOK","orderStatus":"Cancelled","cumExecQty":"0","cumExecValue":"0","avgPrice":"","leavesQty":"0","reduceOnly":false,"rejectReason":"EC_NoEnoughQtyToFill","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000"}],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get port "/v5/market/tickers?category=linear&symbol=BTCUSDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[{"symbol":"BTCUSDT","lastPrice":"100000","markPrice":"100000","indexPrice":"100000","bid1Price":"","bid1Size":"","ask1Price":"","ask1Size":"","fundingRate":"0.0001","nextFundingTime":"1700006400000"}]},"retExtInfo":{},"time":1700000000000} |}];
    return ())
;;

let%expect_test "batch and cancel-all" =
  with_server (fun port ->
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create-batch"
        (sprintf
           {|{"category":"linear","request":[%s,%s,%s]}|}
           (limit ~side:"Buy" ~px:"99000" ~qty:"0.01" ())
           (limit ~side:"Buy" ~px:"99000" ~qty:"0.0001" ())
           (limit ~link:"b-3" ~side:"Sell" ~px:"101000" ~qty:"0.01" ()))
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"list":[{"category":"linear","symbol":"BTCUSDT","orderId":"1","orderLinkId":"","createAt":"1700000000000"},{"category":"linear","symbol":"BTCUSDT","orderId":"","orderLinkId":"","createAt":"1700000000000"},{"category":"linear","symbol":"BTCUSDT","orderId":"3","orderLinkId":"b-3","createAt":"1700000000000"}]},"retExtInfo":{"list":[{"code":0,"msg":"OK"},{"code":10001,"msg":"params error: qty must be a positive multiple of qtyStep"},{"code":0,"msg":"OK"}]},"time":1700000000000} |}];
    let%bind () = post_as "mm" port "/v5/order/cancel-all" {|{"category":"linear"}|} in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: symbol, baseCoin or settleCoin is required","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/cancel-all"
        {|{"category":"linear","symbol":"BTCUSDT"}|}
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"list":[{"orderId":"3","orderLinkId":"b-3"},{"orderId":"1","orderLinkId":""}],"success":"1"},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = get_as "mm" port "/v5/order/realtime?category=linear&settleCoin=USDT" in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"category":"linear","list":[],"nextPageCursor":""},"retExtInfo":{},"time":1700000000000} |}];
    return ())
;;

let%expect_test "authentication" =
  with_server (fun port ->
    let%bind () = get port "/v5/account/wallet-balance?accountType=UNIFIED" in
    [%expect
      {| 200 {"retCode":10003,"retMsg":"API key is invalid. (X-BAPI-API-KEY header is missing)","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get
        ~headers:[ "X-BAPI-API-KEY", "k" ]
        port
        "/v5/account/wallet-balance?accountType=UNIFIED"
    in
    [%expect
      {| 200 {"retCode":10002,"retMsg":"invalid request, please check your server timestamp or recv_window param. req_timestamp[],server_timestamp[1700000000000],recv_window[5000]","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () =
      get
        ~headers:(auth_headers ~timestamp:"1699999990000" "k")
        port
        "/v5/account/wallet-balance?accountType=UNIFIED"
    in
    [%expect
      {| 200 {"retCode":10002,"retMsg":"invalid request, please check your server timestamp or recv_window param. req_timestamp[1699999990000],server_timestamp[1700000000000],recv_window[5000]","result":{},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = post ~headers:(auth_headers "k") port "/v5/order/create" "not json" in
    [%expect
      {| 200 {"retCode":10001,"retMsg":"params error: Line 1, bytes 0-8:\nInvalid token 'not json'","result":{},"retExtInfo":{},"time":1700000000000} |}];
    return ())
;;

(* Websocket client handshake (async_websocket only implements framing). *)
let ws_connect port path =
  let%bind _socket, reader, writer =
    Tcp.connect (Tcp.Where_to_connect.of_host_and_port { host = "127.0.0.1"; port })
  in
  Writer.write
    writer
    (sprintf
       "GET %s HTTP/1.1\r\n\
        Host: localhost\r\n\
        Upgrade: websocket\r\n\
        Connection: Upgrade\r\n\
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
        Sec-WebSocket-Version: 13\r\n\
        \r\n"
       path);
  let rec read_headers () =
    match%bind Reader.read_line reader with
    | `Eof -> failwith "eof during handshake"
    | `Ok "" -> return ()
    | `Ok line ->
      print_endline line;
      read_headers ()
  in
  let%map () = read_headers () in
  Websocket.pipes (Websocket.create ~opcode:`Text ~role:Client reader writer)
;;

let receive incoming =
  match%map Pipe.read incoming with
  | `Ok msg -> print_endline msg
  | `Eof -> print_endline "<eof>"
;;

let%expect_test "public websocket" =
  with_server (fun port ->
    let%bind incoming, outgoing = ws_connect port "/v5/public/linear" in
    [%expect
      {|
      HTTP/1.1 101 Switching Protocols
      upgrade: websocket
      connection: Upgrade
      sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
      |}];
    Pipe.write_without_pushback
      outgoing
      {|{"req_id":"1","op":"subscribe","args":["orderbook.50.BTCUSDT","publicTrade.BTCUSDT"]}|};
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    [%expect
      {|
      {"success":true,"ret_msg":"subscribe","conn_id":"sim-conn-0","req_id":"1","op":"subscribe"}
      {"topic":"orderbook.50.BTCUSDT","type":"snapshot","ts":1700000000000,"data":{"s":"BTCUSDT","b":[],"a":[],"u":1,"seq":0},"cts":1700000000000}
      |}];
    Pipe.write_without_pushback
      outgoing
      {|{"op":"subscribe","args":["orderbook.7.BTCUSDT"]}|};
    let%bind () = receive incoming in
    [%expect
      {| {"success":false,"ret_msg":"error:handler not found,topic:orderbook.7.BTCUSDT","conn_id":"sim-conn-0","op":"subscribe"} |}];
    Pipe.write_without_pushback outgoing {|{"op":"ping"}|};
    let%bind () = receive incoming in
    [%expect
      {| {"success":true,"ret_msg":"pong","conn_id":"sim-conn-0","req_id":"","op":"ping"} |}];
    (* Book changes are pushed as deltas after the coalescing delay. *)
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~side:"Sell" ~px:"100000" ~qty:"0.01" ())
    in
    [%expect
      {| 200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":""},"retExtInfo":{},"time":1700000000000} |}];
    let%bind () = receive incoming in
    [%expect
      {| {"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1700000000000,"data":{"s":"BTCUSDT","b":[],"a":[["100000","0.01"]],"u":2,"seq":1},"cts":1700000000000} |}];
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~side:"Buy" ~px:"100000" ~qty:"0.004" ())
    in
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    [%expect
      {|
      200 {"retCode":0,"retMsg":"OK","result":{"orderId":"2","orderLinkId":""},"retExtInfo":{},"time":1700000000000}
      {"topic":"publicTrade.BTCUSDT","type":"snapshot","ts":1700000000000,"data":[{"T":1700000000000,"s":"BTCUSDT","S":"Buy","v":"0.004","p":"100000","L":"ZeroPlusTick","i":"1","BT":false,"seq":1}]}
      {"topic":"orderbook.50.BTCUSDT","type":"delta","ts":1700000000000,"data":{"s":"BTCUSDT","b":[],"a":[["100000","0.006"]],"u":3,"seq":2},"cts":1700000000000}
      |}];
    Pipe.write_without_pushback
      outgoing
      {|{"op":"subscribe","args":["tickers.BTCUSDT","orderbook.1.BTCUSDT"]}|};
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    [%expect
      {|
      {"success":true,"ret_msg":"subscribe","conn_id":"sim-conn-0","op":"subscribe"}
      {"topic":"tickers.BTCUSDT","type":"snapshot","data":{"symbol":"BTCUSDT","lastPrice":"100000","markPrice":"100000","indexPrice":"100000","ask1Price":"100000","ask1Size":"0.006","fundingRate":"0.0001","nextFundingTime":"1700006400000"},"cs":2,"ts":1700000000000}
      {"topic":"orderbook.1.BTCUSDT","type":"snapshot","ts":1700000000000,"data":{"s":"BTCUSDT","b":[],"a":[["100000","0.006"]],"u":1,"seq":2},"cts":1700000000000}
      |}];
    Pipe.close outgoing;
    return ())
;;

let%expect_test "private websocket" =
  with_server (fun port ->
    let%bind incoming, outgoing = ws_connect port "/v5/private" in
    [%expect
      {|
      HTTP/1.1 101 Switching Protocols
      upgrade: websocket
      connection: Upgrade
      sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
      |}];
    Pipe.write_without_pushback outgoing {|{"op":"subscribe","args":["order"]}|};
    let%bind () = receive incoming in
    [%expect
      {| {"success":false,"ret_msg":"Request not authorized","conn_id":"sim-conn-0","op":"subscribe"} |}];
    Pipe.write_without_pushback
      outgoing
      {|{"req_id":"a","op":"auth","args":["mm",1700000001000,"unchecked"]}|};
    let%bind () = receive incoming in
    [%expect
      {| {"success":true,"ret_msg":"","conn_id":"sim-conn-0","req_id":"a","op":"auth"} |}];
    Pipe.write_without_pushback
      outgoing
      {|{"op":"subscribe","args":["order","execution","position","wallet"]}|};
    let%bind () = receive incoming in
    [%expect {| {"success":true,"ret_msg":"","conn_id":"sim-conn-0","op":"subscribe"} |}];
    Pipe.write_without_pushback outgoing {|{"req_id":"p","op":"ping"}|};
    let%bind () = receive incoming in
    [%expect
      {| {"conn_id":"sim-conn-0","req_id":"p","op":"pong","args":["1700000000000"]} |}];
    let%bind () =
      post_as
        "mm"
        port
        "/v5/order/create"
        (limit ~link:"mm-1" ~side:"Sell" ~px:"100000" ~qty:"0.01" ())
    in
    let%bind () = receive incoming in
    [%expect
      {|
      200 {"retCode":0,"retMsg":"OK","result":{"orderId":"1","orderLinkId":"mm-1"},"retExtInfo":{},"time":1700000000000}
      {"id":"sim-1","topic":"order","creationTime":1700000000000,"data":[{"orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","orderType":"Limit","price":"100000","qty":"0.01","timeInForce":"GTC","orderStatus":"New","cumExecQty":"0","cumExecValue":"0","avgPrice":"","leavesQty":"0.01","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000","category":"linear","closedPnl":"0"}]}
      |}];
    let%bind () =
      post_as
        "taker"
        port
        "/v5/order/create"
        (limit ~side:"Buy" ~px:"100000" ~qty:"0.004" ())
    in
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    let%bind () = receive incoming in
    [%expect
      {|
      200 {"retCode":0,"retMsg":"OK","result":{"orderId":"2","orderLinkId":""},"retExtInfo":{},"time":1700000000000}
      {"id":"sim-2","topic":"order","creationTime":1700000000000,"data":[{"orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","orderType":"Limit","price":"100000","qty":"0.01","timeInForce":"GTC","orderStatus":"PartiallyFilled","cumExecQty":"0.004","cumExecValue":"400","avgPrice":"100000","leavesQty":"0.006","reduceOnly":false,"rejectReason":"EC_NoError","positionIdx":0,"createdTime":"1700000000000","updatedTime":"1700000000000","category":"linear","closedPnl":"0"}]}
      {"id":"sim-3","topic":"execution","creationTime":1700000000000,"data":[{"execId":"1","orderId":"1","orderLinkId":"mm-1","symbol":"BTCUSDT","side":"Sell","execPrice":"100000","execQty":"0.004","execValue":"400","execFee":"0.08","feeRate":"0.0002","execType":"Trade","isMaker":true,"execTime":"1700000000000","closedSize":"","seq":1,"category":"linear"}]}
      {"id":"sim-4","topic":"position","creationTime":1700000000000,"data":[{"positionIdx":0,"symbol":"BTCUSDT","side":"Sell","size":"0.004","entryPrice":"100000","positionValue":"400","unrealisedPnl":"0","cumRealisedPnl":"-0.08","leverage":"10","liqPrice":"248855701.49253736","markPrice":"100000","positionStatus":"Normal","createdTime":"1700000000000","updatedTime":"1700000000000","category":"linear"}]}
      {"id":"sim-5","topic":"wallet","creationTime":1700000000000,"data":[{"accountType":"UNIFIED","totalEquity":"999999.92","totalWalletBalance":"999999.92","totalMarginBalance":"999999.92","totalAvailableBalance":"999959.92","totalPerpUPL":"0","totalInitialMargin":"40","totalMaintenanceMargin":"2","coin":[{"coin":"USDT","walletBalance":"999999.92","equity":"999999.92","unrealisedPnl":"0","usdValue":"999999.92","locked":"0"}]}]}
      |}];
    Pipe.close outgoing;
    return ())
;;
