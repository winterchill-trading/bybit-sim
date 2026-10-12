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
