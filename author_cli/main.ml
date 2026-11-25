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
      ~doc:"DIR Project root (default: nearest Silver Bazel or Dune project)"
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

let connect ~bound ~authoring_only root = function
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
    let call operation =
      match%map
        Client.authoring client { instance_id = hello.instance_id; operation }
        >>| Or_error.ok_exn
      with
      | Ok r -> r
      | Error e -> raise_s [%sexp (e : V1.Error.t)]
    in
    let%map root, project =
      if not bound
      then return (root, None)
      else if authoring_only
      then (
        match%map call (Bind_owner_project { destination = root }) with
        | Owner_project_bound id -> root, Some id
        | r -> raise_s [%sexp (r : A.Response.t)])
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
    root, project, call
;;

let unexpected = function
  | A.Response.Failed e -> raise_s [%sexp (e : A.Failure.t)]
  | r -> raise_s [%sexp "Unexpected authoring reply", (r : A.Response.t)]
;;

let publish ?(authoring_only = false) ~bound (root, endpoint, apply) ~request =
  let%bind destination, project, call = connect ~bound ~authoring_only root endpoint in
  match%bind call (request destination project) with
  | Previewed p ->
    printf "Project: %s\nProvider: %s %s\n" destination p.provider p.version;
    let flow_authoring =
      List.mem
        [ A.new_flow_recipe; A.duplicate_profile_recipe ]
        p.operation.recipe
        ~equal:String.equal
    in
    if flow_authoring
    then printf "Owner chip: %s\n" (Option.value_exn p.operation.target.object_id);
    List.iter p.new_files ~f:(printf "  %s\n");
    if flow_authoring && not apply
    then List.iter p.files ~f:(fun f -> printf "\n--- %s ---\n%s\n" f.path f.contents);
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
       if flow_authoring && not (List.is_empty created_files)
       then
         printf
           "Source created. Build the owner chip and rediscover to verify it is runnable.\n";
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
    ~summary:"Create a reusable Hardcaml or Classic Bluespec IP library"
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
    ~summary:"Add a source module to an existing Hardcaml or Classic Bluespec library"
    (let open Command.Let_syntax in
     let%map_open flags
     and library =
       flag
         "--library"
         (required string)
         ~doc:"DIR Dune library or Bazel package directory relative to the project root"
     and name = anon ("MODULE_NAME" %: string) in
     fun () -> run flags ~recipe:A.module_recipe ~name ~library:(Some library))
;;

let owner destination project chip : A.Owner.t =
  { destination; project = Option.value_exn project; chip }
;;

let new_flow =
  Command.async
    ~summary:"Create a methodology and initial profile on a registered chip"
    (let open Command.Let_syntax in
     let%map_open flags
     and chip = flag "--chip" (required string) ~doc:"ID Owning chip catalog entry"
     and recipe =
       flag
         "--recipe"
         (optional_with_default "librelane_classic_v1" string)
         ~doc:"ID Provider recipe"
     and endpoints =
       flag
         "--endpoint-stage"
         (listed string)
         ~doc:"STAGE Declared endpoint (repeatable; default: recipe endpoints)"
     and initial_profile =
       flag
         "--initial-profile"
         (optional_with_default "balanced" string)
         ~doc:"ID Initial profile"
     and name = anon ("FLOW" %: string) in
     fun () ->
       publish ~authoring_only:true ~bound:true flags ~request:(fun destination project ->
         New_flow
           { owner = owner destination project chip
           ; name
           ; recipe
           ; endpoints
           ; initial_profile
           }))
;;

let duplicate_profile =
  Command.async
    ~summary:"Copy a profile's explicit assignments within its owning methodology"
    (let open Command.Let_syntax in
     let%map_open flags
     and chip = flag "--chip" (required string) ~doc:"ID Owning chip catalog entry"
     and flow = flag "--flow" (required string) ~doc:"ID Owning methodology"
     and source = flag "--from" (required string) ~doc:"ID Source profile"
     and edits =
       flag
         "--set"
         (listed string)
         ~doc:"KEY=VALUE Override an advertised assignment (KEY= removes it)"
     and name = anon ("PROFILE" %: string) in
     fun () ->
       let edits =
         List.map edits ~f:(fun edit ->
           String.lsplit2 edit ~on:'='
           |> Option.value_or_thunk ~default:(fun () ->
             failwith "--set requires KEY=VALUE"))
       in
       publish ~authoring_only:true ~bound:true flags ~request:(fun destination project ->
         Duplicate_profile
           { owner = owner destination project chip; flow; source; name; edits }))
;;

let () =
  Command.group
    ~summary:"Preview or apply Silver project authoring operations"
    [ "new-chip", new_chip
    ; "new-ip", new_ip
    ; "new-module", new_module
    ; "new-flow", new_flow
    ; "duplicate-profile", duplicate_profile
    ]
  |> Command_unix.run
;;
