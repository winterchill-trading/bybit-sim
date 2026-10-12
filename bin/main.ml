open! Core
open! Async
open! Bybit_protocol
open! Bybit_sim
module Market_sim = Exchange_core_engine.Market_sim

let command =
  Command.async
    ~summary:"Bybit v5 linear perpetual exchange simulator"
    ~readme:(fun () ->
      "Serves Bybit's v5 REST API (/v5/market/*, /v5/order/*, /v5/execution/list, \
       /v5/position/list, /v5/account/wallet-balance) and the websocket streams \
       /v5/public/linear and /v5/private on one port. Signatures are not checked: the \
       X-BAPI-API-KEY header (or the websocket auth apiKey) is the account, and every \
       key is credited -initial-balance USDT on first use. X-BAPI-TIMESTAMP must still \
       be within the recv window.")
    (let%map_open.Command port =
       flag "-port" (optional_with_default 3400 int) ~doc:"PORT HTTP and websocket port"
     and seed =
       flag "-seed" (optional_with_default 0 int) ~doc:"N market simulation random seed"
     and vol_bps =
       flag
         "-vol-bps"
         (optional_with_default Market_sim.Config.default.vol_bps float)
         ~doc:"BPS reference price volatility per second, in basis points"
     and symbols =
       flag
         "-symbols"
         (optional (Arg_type.comma_separated string))
         ~doc:"SYMBOL,... symbols the noise traders trade (default: all)"
     and noise_traders =
       flag
         "-noise-traders"
         (optional_with_default Market_sim.Config.default.noise_traders int)
         ~doc:"N number of noise trader accounts (0 disables the market simulation)"
     and initial_balance =
       flag
         "-initial-balance"
         (optional_with_default
            (Usd.to_string Server.Config.default.initial_balance)
            string)
         ~doc:"USDT balance credited to any API key on first use"
     and anchor_specs =
       flag
         "-anchor"
         (listed Bybit_sim_anchor.Spec.arg_type)
         ~doc:
           "VENUE:SYMBOL=SIMSYM follow a reference market (repeatable), e.g. \
            binance:BTCUSDT=BTCUSDT; live through the venue's public stream unless a \
            recorded source is given"
     and anchor_levels =
       flag
         "-anchor-levels"
         (optional_with_default Bybit_sim_anchor.Anchors.Config.default.levels int)
         ~doc:"N reference levels per side resting in the simulated book (default 5)"
     and anchor_mark_interval_ms =
       flag
         "-anchor-mark-interval-ms"
         (optional_with_default 100 int)
         ~doc:"MS minimum time between two mark updates (default 100)"
     and anchor_max_staleness_ms =
       flag
         "-anchor-max-staleness-ms"
         (optional_with_default 5000 int)
         ~doc:"MS a reference silent for longer is stale (default 5000)"
     and anchor_noise =
       flag
         "-anchor-noise"
         (optional_with_default 0 int)
         ~doc:"N noise traders kept on anchored symbols (default 0)"
     and anchor_price_factor =
       flag
         "-anchor-price-factor"
         (optional_with_default 1. float)
         ~doc:"F reference prices are multiplied by F (default 1)"
     and anchor_size_factor =
       flag
         "-anchor-size-factor"
         (optional_with_default 1. float)
         ~doc:"F reference sizes are multiplied by F (default 1)"
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let exchange = Adapt.create_exchange () in
       let server =
         Server.create
           ~config:
             { Server.Config.default with
               initial_balance = Usd.of_string initial_balance
             }
           exchange
       in
       let%bind http = Server.listen server ~port in
       Log.Global.info
         "bybit-sim listening on port %d (REST /v5/..., websocket /v5/public/linear and \
          /v5/private)"
         (Server.port http);
       Server.start_periodic server;
       let market_sim =
         Option.some_if (noise_traders > 0) ()
         |> Option.map ~f:(fun () ->
           Market_sim.create
             { Adapt.market_sim_config with
               seed
             ; vol_bps
             ; noise_traders
             ; symbols = List.map (Option.value symbols ~default:[]) ~f:Symbol.of_string
             }
             exchange)
       in
       if not (List.is_empty anchor_specs)
       then (
         let config =
           { Bybit_sim_anchor.Anchors.Config.default with
             levels = anchor_levels
           ; mark_interval = Time_ns.Span.of_int_ms anchor_mark_interval_ms
           ; max_staleness = Time_ns.Span.of_int_ms anchor_max_staleness_ms
           ; noise_traders = anchor_noise
           ; price_factor = anchor_price_factor
           ; size_factor = anchor_size_factor
           }
         in
         let anchors =
           Bybit_sim_anchor.Anchors.create ~config ?market_sim server anchor_specs
           |> ok_exn
         in
         don't_wait_for (Bybit_sim_anchor.Anchors.run anchors Live));
       Option.iter market_sim ~f:(Server.run_market_sim server);
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
