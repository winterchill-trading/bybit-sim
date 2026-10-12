open! Core
open Bybit_sim_anchor

let%expect_test "source flags" =
  List.iter
    [ None, None, None, None
    ; Some "data", None, Some "2026-10-12T15:05:00Z", Some "2026-10-12T15:06:00Z"
    ; Some "data", None, Some "2026-10-12", Some "2026-10-12"
    ; None, Some "norm", Some "2026-10-11T23:00:00Z", Some "2026-10-12"
    ; Some "data", None, Some "2026-10-12", None
    ; None, None, Some "2026-10-12", Some "2026-10-12"
    ; Some "data", Some "norm", Some "2026-10-12", Some "2026-10-12"
    ; Some "data", None, Some "yesterday", Some "2026-10-12"
    ]
    ~f:(fun (raw, norm, from, to_) ->
      let utc = Time_ns.to_string_iso8601_basic ~zone:Time_float.Zone.utc in
      match Anchors.Source.of_flags ~raw ~norm ~from ~to_ with
      | Ok (Raw { dir; from; to_ }) ->
        print_s [%message "Raw" dir ~from:(utc from) ~to_:(utc to_)]
      | source -> print_s [%sexp (source : Anchors.Source.t Or_error.t)]);
  [%expect
    {|
    (Ok Live)
    (Raw data (from 2026-10-12T15:05:00.000000000Z)
     (to_ 2026-10-12T15:06:00.000000000Z))
    (Raw data (from 2026-10-12T00:00:00.000000000Z)
     (to_ 2026-10-13T00:00:00.000000000Z))
    (Ok (Norm (dir norm) (from 2026-10-11) (to_ 2026-10-12)))
    (Error "-anchor-raw and -anchor-norm need -anchor-from and -anchor-to")
    (Error "-anchor-from and -anchor-to need -anchor-raw or -anchor-norm")
    (Error "-anchor-raw and -anchor-norm are exclusive")
    (Error ("expected a time or a UTC date" yesterday))
    |}]
;;
