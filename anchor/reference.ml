open! Core
open! Async

let supported = Market_data.Venue.[ Bybit; Binance ]
let streams = Market_data.Stream.[ Trades; L2; Funding ]

let unsupported venue =
  Or_error.error_s
    [%message
      "no client for this reference venue"
        (venue : Market_data.Venue.t)
        (supported : Market_data.Venue.t list)]
;;

let live_feed (instrument : Market_data.Instrument.t) =
  let symbols = [ Market_data.Symbol.to_string instrument.symbol ] in
  match instrument.venue with
  | Bybit ->
    Deferred.Or_error.try_with ~extract_exn:true (fun () ->
      Bybit_client.Live_feed.connect
        (Bybit_client.Config.Read_only.mainnet ())
        ~symbols
        ~streams
      >>| Bybit_client.Live_feed.feed)
  | Binance ->
    Deferred.Or_error.try_with ~extract_exn:true (fun () ->
      Binance_client.Live_feed.create
        (Binance_client.Config.Read_only.mainnet ())
        ~symbols
        ~streams)
  | venue -> return (unsupported venue)
;;

let normalizer : Market_data.Venue.t -> Market_data.Normalizer.t Or_error.t = function
  | Bybit -> Ok (module Bybit_client.Raw_normalizer)
  | Binance -> Ok (module Binance_client.Raw_normalizer)
  | venue -> unsupported venue
;;
