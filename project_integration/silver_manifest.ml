open! Core

type t =
  { name : string
  ; build_label : string
  ; test_label : string
  }

let version = 1
let relative_path = ".silver/project.json"

let valid_label label =
  let valid_component component =
    (not (List.mem [ ""; "."; ".."; "..." ] component ~equal:String.equal))
    && String.for_all component ~f:(fun c ->
      Char.is_alphanum c || String.contains "_.-+~=@," c)
  in
  let valid_path path = List.for_all (String.split path ~on:'/') ~f:valid_component in
  let valid_repo repo =
    match String.chop_prefix repo ~prefix:"@" with
    | None -> String.is_empty repo
    | Some name ->
      let name = String.chop_prefix name ~prefix:"@" |> Option.value ~default:name in
      String.for_all name ~f:(fun c -> Char.is_alphanum c || String.contains "_.-+~" c)
  in
  (* Require an absolute label, not an option, relative path or recursive pattern. *)
  match String.substr_index label ~pattern:"//" with
  | Some index when valid_repo (String.prefix label index) ->
    (match String.split (String.drop_prefix label (index + 2)) ~on:':' with
     | [ package; target ] ->
       (String.is_empty package || valid_path package) && valid_path target
     | [ package ] -> valid_path package
     | _ -> false)
  | _ -> false
;;

let parse_string contents =
  let open Result.Let_syntax in
  let fail field expectation = Error (field ^ " must be " ^ expectation) in
  match Yojson.Safe.from_string contents with
  | `Assoc fields ->
    let%bind () =
      match
        List.find fields ~f:(fun (key, _) ->
          not
            (List.mem
               [ "schema_version"; "name"; "build_label"; "test_label" ]
               key
               ~equal:String.equal))
      with
      | None -> Ok ()
      | Some (key, _) -> Error (sprintf "Unknown field %S" (String.prefix key 128))
    in
    let member field =
      match
        List.filter_map fields ~f:(fun (key, value) ->
          Option.some_if (String.equal key field) value)
      with
      | [ value ] -> Ok value
      | [] -> Error ("Missing field " ^ field)
      | _ -> Error ("Duplicate field " ^ field)
    in
    let string field ~valid ~expectation =
      match%bind member field with
      | `String text when valid text -> Ok text
      | _ -> fail field expectation
    in
    let label field =
      string field ~valid:valid_label ~expectation:"an absolute Bazel label"
    in
    let%bind () =
      match%bind member "schema_version" with
      | `Int n when n = version -> Ok ()
      | _ -> fail "schema_version" (Int.to_string version)
    in
    let%bind name =
      string
        "name"
        ~valid:(fun s ->
          (not (String.is_empty (String.strip s)))
          && not (String.exists s ~f:(fun c -> Char.(c < ' ' || c = '\x7f'))))
        ~expectation:"a nonempty project name without control characters"
    in
    let%bind build_label = label "build_label" in
    let%map test_label = label "test_label" in
    { name; build_label; test_label }
  | _ -> Error "Expected a JSON object"
  | exception Yojson.Json_error message -> Error (String.prefix message 512)
;;

let load ~root =
  let path = Filename.concat root relative_path in
  Config_location.read_optional ~path ~max_bytes:Config_location.max_config_bytes
  |> Or_error.bind ~f:(function
    | None -> Ok None
    | Some contents ->
      (match parse_string contents with
       | Ok manifest -> Ok (Some manifest)
       | Error reason -> Or_error.error_string (path ^ ": " ^ reason)))
;;
