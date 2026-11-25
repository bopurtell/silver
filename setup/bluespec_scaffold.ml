open! Core
module Config = Silver_project_integration.Simulation_config
module Location = Silver_project_integration.Config_location
module Manifest = Silver_project_integration.Silver_manifest

let python3 () =
  let path = Option.value (Sys.getenv "PATH") ~default:"/usr/bin:/bin" in
  List.find_map (String.split path ~on:':') ~f:(fun dir ->
    try
      let dir = Filename_unix.realpath (if String.is_empty dir then "." else dir) in
      let executable = Filename.concat dir "python3" in
      if Poly.equal (Core_unix.stat executable).st_kind S_REG
         && Result.is_ok (Core_unix.access executable [ `Exec ])
      then Some executable
      else None
    with
    | Core_unix.Unix_error _ -> None)
  |> Result.of_option
       ~error:
         "Python 3 is required for the simulation provider; install python3 and put it \
          on PATH"
;;

let require_directory path =
  if not (Poly.equal (Core_unix.lstat path).st_kind S_DIR)
  then failwith (path ^ ": expected a directory, not a symlink or other file")
;;

let require_absent path =
  if No_clobber.exists path then Error (No_clobber.existing_error path) else Ok ()
;;

let create ~destination =
  Or_error.try_with (fun () ->
    let open Result.Let_syntax in
    if String.is_empty destination then failwith "expected a destination directory";
    let%bind python = python3 () in
    Core_unix.mkdir_p destination ~perm:0o755;
    let root = Filename_unix.realpath destination in
    let name = Filename.basename root in
    let manifest =
      Yojson.Safe.pretty_to_string
        (`Assoc
          [ "schema_version", `Int Manifest.version
          ; "name", `String name
          ; "build_label", `String "//:rtl"
          ; "test_label", `String "//:simulation"
          ])
      ^ "\n"
    in
    let%bind (_ : Manifest.t) = Manifest.parse_string manifest in
    let manifest_path = root ^/ Manifest.relative_path in
    let simulation_path = Location.preferred_path ~root ~filename:Config.filename in
    let config : Config.t =
      Config.validate
        { schema_version = 1
        ; provider_executable = python
        ; provider_args = [ "simulation_provider.py" ] (* Runs from the project root. *)
        ; discovery_timeout_seconds = 10
        ; run_timeout_seconds = 300
        ; max_parallel_runs = 1
        }
    in
    let simulation = Sexp.to_string_hum (Config.sexp_of_t config) ^ "\n" in
    let files =
      List.map Bluespec_template.files ~f:(fun (name, text) -> root ^/ name, text)
      @ [ simulation_path, simulation; manifest_path, manifest ]
    in
    let directories =
      [ Filename.dirname manifest_path; Filename.dirname simulation_path ]
    in
    (* Check all collisions before publishing any file. Recheck directories in
       No_clobber.publish and publish the discovery marker last. *)
    List.iter directories ~f:(fun path ->
      if No_clobber.exists path then require_directory path);
    let%bind () =
      Result.all_unit
        (List.map
           ((root ^/ Project_discovery.marker)
            :: (Location.candidate_paths ~root ~filename:Config.filename
                @ List.map files ~f:fst))
           ~f:require_absent)
    in
    List.iter directories ~f:(fun path ->
      Core_unix.mkdir_p path ~perm:0o755;
      require_directory path);
    let rec publish = function
      | [] -> Ok root
      | (path, contents) :: rest ->
        let%bind () =
          No_clobber.publish
            ~directory:(Filename.dirname path)
            ~path
            ~temporary_prefix:".silver-init-"
            ~contents
        in
        publish rest
    in
    publish files)
  |> function
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;
