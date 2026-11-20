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
    flag "--root" (optional string) ~doc:"DIR Project root (default: nearest Dune project)"
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

let connect root = function
  | None ->
    let root =
      match root with
      | Some root -> Discovery.explicit_root root
      | None ->
        Result.map (Discovery.discover ~explicit_flag:"--root" ()) ~f:(fun d -> d.root)
    in
    let root = Result.ok_or_failwith root in
    let service = Service.create ~permitted_roots:[ root ] in
    return (root, fun req -> In_thread.run (fun () -> Service.handle service req))
  | Some endpoint ->
    let root =
      match root with
      | Some root when not (Filename.is_relative root) -> root
      | _ -> failwith "--endpoint requires --root /absolute/path/on/service/host"
    in
    let client = Client.create endpoint in
    let%map hello = Client.hello client >>| Or_error.ok_exn in
    ( root
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

let run (root, endpoint, apply) ~recipe ~name ~library =
  let%bind destination, call = connect root endpoint in
  let operation =
    { A.Operation.recipe
    ; name
    ; target = { destination; project = None; object_id = library }
    }
  in
  match%bind call (Preview operation) with
  | Previewed p ->
    printf "Project: %s\nProvider: %s %s\n" destination p.provider p.version;
    List.iter p.new_files ~f:(printf "  %s\n");
    Option.iter p.registration ~f:(fun edit -> printf "%s: %s\n" edit.path edit.snippet);
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
    [ "new-ip", new_ip; "new-module", new_module ]
  |> Command_unix.run
;;
