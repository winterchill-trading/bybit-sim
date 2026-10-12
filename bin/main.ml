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
     and anchor_status_interval_s =
       flag
         "-anchor-status-interval-s"
         (optional_with_default 10 int)
         ~doc:"S log every anchor's status every S seconds (default 10, 0 disables)"
     and anchor_raw =
       flag
         "-anchor-raw"
         (optional string)
         ~doc:
           "DIR replay the recorder's raw minute files under DIR (containing raw/) \
            instead of the live stream"
     and anchor_norm =
       flag
         "-anchor-norm"
         (optional string)
         ~doc:"DIR replay normalized event logs under DIR instead of the live stream"
     and anchor_from =
       flag
         "-anchor-from"
         (optional string)
         ~doc:"T start of the recorded range (2026-10-12T15:05:00Z or a UTC date)"
     and anchor_to =
       flag
         "-anchor-to"
         (optional string)
         ~doc:"T end of the recorded range, exclusive (a date means its end)"
     and anchor_speed =
       flag
         "-anchor-speed"
         (optional_with_default 1. float)
         ~doc:
           "X pacing of recorded sources: 1 real time, 0 as fast as possible (default 1)"
     and input_journal =
       flag
         "-input-journal"
         (optional string)
         ~doc:
           "FILE write every engine input (client requests, noise traders, anchors) to \
            FILE, a binary journal that replays the whole run"
     and log_level =
       flag
         "-log-level"
         (optional_with_default `Info Log.Level.arg)
         ~doc:"LEVEL debug, info, warn or error (default info)"
     in
     fun () ->
       Log.Global.set_output [ Log.Output.stderr () ];
       Log.Global.set_level log_level;
       let anchor_source =
         Bybit_sim_anchor.Anchors.Source.of_flags
           ~raw:anchor_raw
           ~norm:anchor_norm
           ~from:anchor_from
           ~to_:anchor_to
         |> ok_exn
       in
       let exchange = Adapt.create_exchange () in
       Option.iter input_journal ~f:(fun path ->
         let journal = Exchange_core_engine.Journal.create path in
         Exchange_core_engine.Journal.attach journal exchange;
         Clock_ns.every Time_ns.Span.second (fun () ->
           Exchange_core_engine.Journal.flush journal);
         Shutdown.at_shutdown (fun () ->
           Exchange_core_engine.Journal.close journal;
           return ());
         (* So that ^C and SIGTERM still run the at_shutdown handlers. *)
         Signal.handle Signal.terminating ~f:(fun _ -> shutdown 0));
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
           { Bybit_sim_anchor.Anchors.Config.levels = anchor_levels
           ; mark_interval = Time_ns.Span.of_int_ms anchor_mark_interval_ms
           ; max_staleness = Time_ns.Span.of_int_ms anchor_max_staleness_ms
           ; noise_traders = anchor_noise
           ; price_factor = anchor_price_factor
           ; size_factor = anchor_size_factor
           ; speed = anchor_speed
           }
         in
         let anchors =
           Bybit_sim_anchor.Anchors.create ~config ?market_sim server anchor_specs
           |> ok_exn
         in
         if anchor_status_interval_s > 0
         then
           Bybit_sim_anchor.Anchors.log_summary_every
             anchors
             (Time_ns.Span.of_int_sec anchor_status_interval_s);
         don't_wait_for (Bybit_sim_anchor.Anchors.run anchors anchor_source));
       Option.iter market_sim ~f:(Server.run_market_sim server);
       Cohttp_async.Server.close_finished http)
;;

let () = Command_unix.run command
