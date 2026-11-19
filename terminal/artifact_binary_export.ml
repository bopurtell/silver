open! Core
open! Async
open Hardcaml_workbench_protocol

let max_bytes = 16 * 1024 * 1024
let page_limit = 64 * 1024
let max_hex_length = 2 * page_limit

let executable path =
  if String.is_empty path
     || Filename.is_relative path
     || String.exists path ~f:(Char.equal '\000')
  then Or_error.error_string "Viewer requires an absolute executable filename"
  else Ok path
;;

let extension (reference : Asic_artifact.Reference.t) =
  List.find [ ".gds"; ".png"; ".def"; ".odb" ] ~f:(fun suffix ->
    String.is_suffix (String.lowercase reference.path) ~suffix)
  |> Or_error.of_option ~error:(Error.of_string "Unsupported physical binary extension")
;;

let eligible reference =
  let open Or_error.Let_syntax in
  let%bind _ = extension reference in
  if reference.size < 0
     || reference.size > max_bytes
     || String.length reference.sha256 <> 64
     || not
          (String.for_all reference.sha256 ~f:(function
            | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
            | _ -> false))
  then Or_error.error_string "Binary export requires bounded size (16 MiB) and SHA256"
  else Ok ()
;;

let decode hex =
  if String.length hex > max_hex_length || String.length hex % 2 <> 0
  then Or_error.error_string "Invalid binary hex page length"
  else
    Or_error.try_with (fun () ->
      let digit = function
        | '0' .. '9' as c -> Char.to_int c - Char.to_int '0'
        | 'a' .. 'f' as c -> Char.to_int c - Char.to_int 'a' + 10
        | 'A' .. 'F' as c -> Char.to_int c - Char.to_int 'A' + 10
        | _ -> failwith "Invalid binary hex digit"
      in
      String.init
        (String.length hex / 2)
        ~f:(fun i ->
          Char.of_int_exn ((digit hex.[2 * i] lsl 4) lor digit hex.[(2 * i) + 1])))
;;

let validate_page
  (reference : Asic_artifact.Reference.t)
  ~offset
  (page : Asic_artifact.Byte_page.t)
  =
  let open Or_error.Let_syntax in
  let%bind () =
    if Run_ref.equal reference.run page.run
       && String.equal reference.id page.artifact_id
       && String.equal reference.terminal_attempt page.terminal_attempt
       && String.equal reference.sha256 page.sha256
       && page.offset = offset
       && page.limit = page_limit
    then Ok ()
    else Or_error.error_string "Binary page identity/offset/limit changed"
  in
  let%bind () =
    match page.error with
    | None -> Ok ()
    | Some e -> Or_error.error_string e
  in
  let%bind bytes = decode page.bytes_hex in
  if page.next_offset < offset
     || page.next_offset > reference.size
     || page.next_offset - offset <> String.length bytes
     || (not (Bool.equal page.eof (page.next_offset = reference.size)))
     || ((not page.eof) && String.is_empty bytes)
  then Or_error.error_string "Invalid binary page progress/size/EOF"
  else Ok bytes
;;

let run ~viewer ~reference ~fetch ~current ~launch =
  let parameters =
    let open Or_error.Let_syntax in
    let%bind viewer = executable viewer in
    let%bind () = eligible reference in
    let%map suffix = extension reference in
    viewer, suffix
  in
  match parameters with
  | Error e -> return (Error e)
  | Ok (viewer, suffix) ->
    let sha256 = String.lowercase reference.sha256 in
    let metadata =
      Sexp.to_string_hum
        (Sexp.List
           [ Atom "terminal-host-exact-binary-export"
           ; List
               [ Atom "original_reference"; Asic_artifact.Reference.sexp_of_t reference ]
           ; List [ Atom "verified_sha256"; Atom sha256 ]
           ])
    in
    Streaming_export.run
      ~size:reference.size
      ~sha256
      ~metadata
      ~suffix
      ~current
      ~viewer:(Some viewer)
      ~launch
      ~fetch:(fun ~offset ~limit ~check ->
        let%map page = fetch ~reference ~offset ~limit ~check in
        check ();
        let open Or_error.Let_syntax in
        let%bind page in
        let%map bytes = validate_page reference ~offset page in
        bytes, page.eof)
      ()
;;

let%test_unit "hex transport bounds" =
  assert (String.length (Or_error.ok_exn (decode (String.make 131072 'f'))) = 65536);
  assert (Or_error.is_error (decode (String.make 131074 '0')));
  assert (Or_error.is_error (decode "0z"));
  assert (Or_error.is_error (decode "0"))
;;
