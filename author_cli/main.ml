open! Core
open! Async
open Hardcaml_workbench_protocol
module A = Authoring
module Client = Hardcaml_workbench_native_http.Client
module Service = Hardcaml_workbench_backend.Authoring_service
module Discovery = Hardcaml_workbench_setup.Project_discovery

let flags =
  let open Command.Let_syntax in
  let%map_open root =
    flag
      "--root"
      (optional string)
      ~doc:"DIR Project root (default: nearest Dune project)"
  and endpoint =
    flag
      "--endpoint"
      (optional string)
      ~doc:"URL Use a daemon; requires an absolute --root on its host"
  and apply =
    flag "--apply" no_arg ~doc:" Publish the previewed files (default: preview only)"
  in
  root, endpoint, apply
;;

let connect ~bound root = function
  | None ->
    let root =
      match root with
      | Some root -> Discovery.explicit_root root
      | None ->
        Result.map (Discovery.discover ~explicit_flag:"--root" ()) ~f:(fun d -> d.root)
    in
    let root = Result.ok_or_failwith root in
    let service = Service.create ~permitted_roots:[ root ] in
    let project, identity =
      if bound
      then (
        let stat = Core_unix.stat root in
        Some (Project_id.of_string "silver-author-local"), Some (stat.st_dev, stat.st_ino))
      else None, None
    in
    return
      ( root
      , project
      , fun req ->
          In_thread.run (fun () -> Service.handle ?project_identity:identity service req)
      )
  | Some endpoint ->
    let root =
      match root with
      | Some root when not (Filename.is_relative root) -> root
      | _ -> failwith "--endpoint requires --root /absolute/path/on/service/host"
    in
    let client = Client.create endpoint in
    let%bind hello = Client.hello client >>| Or_error.ok_exn in
    let%map root, project =
      if not bound
      then return (root, None)
      else (
        match%map
          Client.open_project
            client
            { instance_id = hello.instance_id; root; environment = Inherit_daemon }
          >>| Or_error.ok_exn
        with
        | Ok p -> Project_root.to_absolute_path p.project.root, Some p.project.id
        | Error e -> raise_s [%sexp (e : V1.Error.t)])
    in
    ( root
    , project
    , fun operation ->
        (match%map
           Client.authoring client { instance_id = hello.instance_id; operation }
           >>| Or_error.ok_exn
         with
         | Ok response -> response
         | Error e -> raise_s [%sexp (e : V1.Error.t)]) )
;;

let unexpected = function
  | A.Response.Failed e -> raise_s [%sexp (e : A.Failure.t)]
  | r -> raise_s [%sexp "Unexpected authoring reply", (r : A.Response.t)]
;;

let publish ~bound (root, endpoint, apply) ~request =
  let%bind destination, project, call = connect ~bound root endpoint in
  match%bind call (request destination project) with
  | Previewed p ->
    printf "Project: %s\nProvider: %s %s\n" destination p.provider p.version;
    List.iter p.new_files ~f:(printf "  %s\n");
    Option.iter p.registration ~f:(fun edit ->
      printf
        "%s: %s\n%s\n"
        (if edit.manual then "Manual registration" else "Registration")
        edit.path
        edit.snippet);
    let preview_id = p.preview_id in
    (match%map call (if apply then Apply { preview_id } else Cancel { preview_id }) with
     | Cancelled -> printf "Preview only; no files created.\n"
     | Applied { created_files; registration } ->
       printf "Created %d file(s).\n" (List.length created_files);
       (match registration with
        | Skipped { path; reason } -> printf "Manual edit: %s: %s\n" path reason
        | Registered path -> printf "Registered: %s\n" path
        | Not_requested -> ())
     | r -> unexpected r)
  | r -> unexpected r
;;

let run flags ~recipe ~name ~library =
  publish ~bound:false flags ~request:(fun destination project ->
    Preview { recipe; name; target = { destination; project; object_id = library } })
;;

let new_chip =
  Command.async
    ~summary:"Add an independently buildable chip target to a Dune project"
    (let open Command.Let_syntax in
     let%map_open flags
     and library =
       flag "--from-ip" (optional string) ~doc:"DIR Use this project-relative IP library"
     and mapping =
       flag
         "--mapping"
         (optional string)
         ~doc:
           "MAP Explicit IP wiring: ui_in:uo_out:comb8 (8-bit combinational, no \
            clock/reset)"
     and no_register =
       flag "--no-register" no_arg ~doc:" Leave the project catalog untouched"
     and name = anon ("CHIP_TARGET" %: string) in
     fun () ->
       let source : A.Chip_source.t =
         match library, mapping with
         | None, None -> Example
         | Some library_directory, Some mapping -> Ip { library_directory; mapping }
         | _ -> failwith "--from-ip and --mapping must be supplied together"
       in
       publish ~bound:true flags ~request:(fun destination project ->
         Preview_chip
           { target = { destination; project; object_id = None }
           ; name
           ; source
           ; register = not no_register
           }))
;;

let new_ip =
  Command.async
    ~summary:"Create a reusable Hardcaml library and test"
    (let open Command.Let_syntax in
     let%map_open flags
     and template =
       flag
         "--template"
         (optional_with_default "empty" string)
         ~doc:"empty|sample Choose a starter (default: empty)"
     and name = anon ("LIBRARY_NAME" %: string) in
     fun () ->
       let recipe =
         match template with
         | "empty" -> A.ip_empty_recipe
         | "sample" -> A.ip_sample_recipe
         | _ -> failwith "--template must be empty or sample"
       in
       run flags ~recipe ~name ~library:None)
;;

let new_module =
  Command.async
    ~summary:"Add a source module to an existing Dune library"
    (let open Command.Let_syntax in
     let%map_open flags
     and library =
       flag
         "--library"
         (required string)
         ~doc:"DIR Library directory relative to the project root"
     and name = anon ("MODULE_NAME" %: string) in
     fun () -> run flags ~recipe:A.module_recipe ~name ~library:(Some library))
;;

let () =
  Command.group
    ~summary:"Preview or apply Silver project authoring operations"
    [ "new-chip", new_chip; "new-ip", new_ip; "new-module", new_module ]
  |> Command_unix.run
;;
