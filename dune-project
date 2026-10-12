(lang dune 3.17)

(name bybit-sim)

(generate_opam_files true)

(license MIT)

(maintainers "winterchill-trading")

(authors "winterchill-trading")

(source
 (github winterchill-trading/bybit-sim))

(package
 (name bybit-sim)
 (synopsis "Bybit v5 linear perpetual exchange simulator")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp-async
  http
  async_websocket
  uri
  yojson
  fixed-decimal
  exchange-core
  exchange-core-engine
  bybit-protocol
  order-book
  ppx_jane))

(package
 (name bybit-sim-anchor)
 (synopsis
  "The bybit-sim binary, with markets anchored to a live or recorded reference venue")
 (description
  "A separate package so that the bybit-sim library stays free of the venue clients, whose tests depend on it.")
 (depends
  (ocaml
   (>= 5.2))
  dune
  core
  core_unix
  async
  cohttp
  yojson
  uri
  fixed-decimal
  exchange-core
  exchange-core-engine
  bybit-protocol
  (bybit-sim
   (= :version))
  market-data
  price-anchor
  bybit-client
  binance-client
  ppx_jane))
