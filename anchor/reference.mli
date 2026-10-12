(** The venues an anchor can follow, through their client libraries: a live, read-only
    {!Market_data.Feed.t} (no credentials) and the normalizer that turns recorded raw
    frames back into events. Bybit and Binance for now; other venues fail with an error
    naming the supported ones. *)

open! Core
open! Async

val supported : Market_data.Venue.t list

(** The streams a live anchor subscribes: trades, L2 and funding. *)
val streams : Market_data.Stream.t list

(** Connects to the venue's public mainnet stream for the instrument's symbol. Fails if
    the venue is not supported or the first connection fails. *)
val live_feed : Market_data.Instrument.t -> Market_data.Feed.t Deferred.Or_error.t

(** The venue's {!Market_data.Normalizer.S}, for {!Price_anchor.Source.of_raw}. *)
val normalizer : Market_data.Venue.t -> Market_data.Normalizer.t Or_error.t
