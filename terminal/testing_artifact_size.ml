open! Core

let format = function
  | None -> "unknown"
  | Some bytes when bytes < 0 -> "unknown"
  | Some bytes when bytes < 1_000 -> sprintf "%d B" bytes
  | Some bytes ->
    let open Int64 in
    let bytes = of_int bytes in
    let rec scaled hundredth unit rest =
      (* Round in integer arithmetic without multiplying the byte count. *)
      let value =
        (bytes / hundredth) + if bytes % hundredth >= hundredth / 2L then 1L else 0L
      in
      match rest with
      | next :: rest when value >= 100_000L -> scaled (hundredth * 1_000L) next rest
      | _ -> sprintf "%Ld.%02Ld %s" (value / 100L) (value % 100L) unit
    in
    scaled 10L "kB" [ "MB"; "GB"; "TB"; "PB"; "EB" ]
;;

let%test_unit "unknown, zero and exact bytes" =
  List.iter
    [ None, "unknown"
    ; Some (-1), "unknown"
    ; Some 0, "0 B"
    ; Some 513, "513 B"
    ; Some 999, "999 B"
    ]
    ~f:(fun (bytes, expect) -> [%test_result: string] (format bytes) ~expect)
;;

let%test_unit "decimal units and two-place rounding" =
  List.iter
    [ 1_000, "1.00 kB"
    ; 1_244, "1.24 kB"
    ; 1_245, "1.25 kB"
    ; 1_250, "1.25 kB"
    ; 9_995, "10.00 kB"
    ; 999_994, "999.99 kB"
    ; 999_995, "1.00 MB"
    ; 1_000_000, "1.00 MB"
    ; 1_244_999, "1.24 MB"
    ; 1_245_000, "1.25 MB"
    ; 1_250_000, "1.25 MB"
    ; 2_500_000, "2.50 MB"
    ; 999_994_999, "999.99 MB"
    ; 999_995_000, "1.00 GB"
    ; 1_000_000_000, "1.00 GB"
    ]
    ~f:(fun (bytes, expect) -> [%test_result: string] (format (Some bytes)) ~expect)
;;

let%test_unit "large native sizes round without overflow" =
  if Stdlib.Sys.word_size = 64
  then (
    [%test_result: string] (format (Int64.to_int 3_000_000_000L)) ~expect:"3.00 GB";
    [%test_result: string] (format (Some Int.max_value)) ~expect:"4.61 EB")
;;
