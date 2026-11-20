module Lock = Mutex
open! Core
module Authoring = Hardcaml_workbench_protocol.Authoring
module D = Authoring_destination
open Authoring

let controlled_recipe = "controlled-v1"

type plan =
  { preview : Preview.t
  ; root : D.root
  ; components : string list
  ; snapshot : D.snapshot
  ; library : string list option
  ; catalog_contents : string option
  }

type t =
  { roots : D.root list
  ; mutex : Lock.t
  ; mutable pending : plan list
  }

let create ~permitted_roots =
  { roots = List.map permitted_roots ~f:D.root; mutex = Lock.create (); pending = [] }
;;

exception Rejected of Failure.kind * string

let reject kind message = raise (Rejected (kind, message))

let existing_name (op : Operation.t) =
  Option.some_if
    (List.mem [ add_to_project_recipe; chip_recipe ] op.recipe ~equal:String.equal)
    op.name
;;

let addition (op : Operation.t) =
  if String.equal op.recipe module_recipe
  then (
    match op.target.object_id with
    | Some dir -> Some (D.Module (D.module_directory dir, op.name))
    | None -> reject Invalid_operation "Select a project-relative Dune library directory")
  else if List.mem [ ip_empty_recipe; ip_sample_recipe ] op.recipe ~equal:String.equal
  then (
    if Option.is_some op.target.object_id
    then reject Invalid_operation "IP requires a project root";
    Some (D.Ip op.name))
  else None
;;

let integrate (op : Operation.t) snapshot files ~register =
  let module I = Hardcaml_workbench_project_integration in
  let prefix = D.design_dir op.name ^ "/" in
  let fresh = String.equal op.recipe starter_recipe in
  if fresh
     && not (List.exists files ~f:(fun f -> String.equal f.File.path "dune-project"))
  then failwith "Missing project root";
  if not
       (List.for_all files ~f:(fun f ->
          String.is_prefix f.File.path ~prefix
          || (fresh && String.equal f.path "dune-project")))
  then failwith "Existing-project renderer returned a file outside the starter directory";
  List.iter [ "dune"; "project.ml"; "chip.ml" ] ~f:(fun path ->
    if not (List.exists files ~f:(fun f -> String.equal f.File.path (prefix ^ path)))
    then failwith ("Existing-project renderer omitted " ^ prefix ^ path));
  let target = prefix ^ "project.exe" in
  let config filename sexp =
    { File.path = ".workbench/" ^ filename; contents = Sexp.to_string_hum sexp ^ "\n" }
  in
  let asic =
    config
      I.Asic_config.filename
      [%sexp
        { schema_version = (1 : int)
        ; project_executable = ("_build/default/" ^ target : string)
        ; results_root = ("_flow_results/workbench/asic" : string)
        ; toolchain = ("_flow_tools" : string)
        ; python = (None : string option)
        ; support_tools = (None : string option)
        ; pdk_root = (None : string option)
        ; stage_timeout_seconds = (None : int option)
        }]
  and preparation =
    config
      I.Preparation_config.filename
      (I.Preparation_config.sexp_of_t
         { schema_version = 1
         ; build_target = target
         ; results_root = "_flow_results/workbench/preparation"
         ; timeout_seconds = 600
         })
  in
  let registration, contents =
    Authoring_chip.catalog_plan snapshot ~register ~name:op.name ~target
  in
  ( (if (not (String.equal op.recipe chip_recipe))
        || (register
            && Option.is_none (D.catalog_text snapshot)
            && D.configs_absent snapshot)
     then files @ [ asic; preparation ]
     else files)
  , registration
  , contents )
;;

let preview ?chip ?project_identity t (op : Operation.t) =
  let controlled = String.equal controlled_recipe op.recipe in
  let existing = existing_name op in
  if String.equal chip_recipe op.recipe && Option.is_none chip
  then reject Invalid_operation "Use Preview_chip for a chip target";
  let source, register =
    match chip with
    | None -> Chip_source.Example, true
    | Some (c : Chip_request.t) ->
      if Option.is_none c.target.project
      then reject Invalid_operation "Select an open project";
      c.source, c.register
  in
  let library =
    match source with
    | Example -> None
    | Ip { library_directory; _ } -> Some (D.module_directory library_directory)
  in
  let addition = addition op in
  if not
       (controlled
        || String.equal starter_recipe op.recipe
        || Option.is_some existing
        || Option.is_some addition)
  then reject Invalid_operation "Unknown authoring recipe";
  if String.is_empty op.name
     || String.length op.name > 64
     || (not
           (String.for_all op.name ~f:(function
             | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
             | _ -> false)))
     || (controlled && String.equal op.name "catalog")
  then reject Invalid_operation "Invalid recipe name";
  if (not controlled)
     && ((not (Char.is_lowercase op.name.[0]))
         || String.exists op.name ~f:Char.is_uppercase)
  then reject Invalid_operation "Starter names must match [a-z][a-z0-9_-]{0,63}";
  if Option.is_some addition && String.contains op.name '-'
  then reject Invalid_operation "IP and module names must match [a-z][a-z0-9_]{0,63}";
  if Option.is_some existing && Option.is_some op.target.object_id
  then reject Invalid_operation "Adding a starter requires a project root, not an object";
  if String.equal starter_recipe op.recipe
     && (Option.is_some op.target.project || Option.is_some op.target.object_id)
  then reject Invalid_operation "A new project requires an unbound destination";
  let root, components = D.select t.roots op.target.destination in
  let snapshot =
    D.visit
      ?existing
      ?addition
      ?library
      ~configs_required:(Option.is_none chip)
      root
      components
      (fun _ snapshot -> snapshot)
  in
  Option.iter project_identity ~f:(fun id ->
    if not (D.matches_project snapshot id)
    then reject Destination_denied "The open project directory was replaced");
  let manual =
    match addition with
    | Some (Module _) -> D.manual_modules snapshot
    | _ -> false
  in
  let provider, version, files, registration, catalog_contents =
    if controlled
    then (
      let path = op.name ^ ".txt" in
      ( "controlled"
      , "1"
      , [ { File.path; contents = "Controlled authoring fixture: " ^ op.name ^ "\n" } ]
      , Some { Registration.path = "catalog.txt"; snippet = path ^ "\n"; manual = true }
      , None ))
    else (
      try
        let command, arguments =
          match addition with
          | Some (Ip _) ->
            ( "render-ip"
            , [ "--template"
              ; (if String.equal op.recipe ip_empty_recipe then "empty" else "sample")
              ] )
          | Some (Module _) -> "render-module", []
          | None ->
            let args =
              match source with
              | Example -> []
              | Ip { library_directory; mapping } ->
                (try
                   Authoring_chip.library_arguments
                     snapshot
                     ~directory:library_directory
                     ~mapping
                 with
                 | exn -> reject Invalid_operation (Exn.to_string exn))
            in
            (if Option.is_some existing then "render-target" else "render"), args
        in
        let provider, version, files =
          Authoring_starter.parse (Authoring_starter.render ~command ~arguments op.name)
        in
        let files, registration, catalog_contents =
          match addition with
          | Some (Ip name) ->
            let prefix = "ip/" ^ name ^ "/" in
            if not
                 (List.for_all files ~f:(fun f -> String.is_prefix f.File.path ~prefix)
                  && List.exists files ~f:(fun f ->
                    String.equal f.File.path (prefix ^ "dune")))
            then failwith "Unexpected IP renderer paths";
            files, None, None
          | Some (Module (parts, name)) ->
            let local file = String.concat ~sep:"/" (parts @ [ file ]) in
            (match files with
             | [ file ] when String.equal file.path (name ^ ".ml") ->
               ( [ { file with path = local file.path } ]
               , Option.some_if
                   manual
                   { Registration.path = local "dune"
                   ; manual = true
                   ; snippet =
                       "Review the library's (modules ...) list and include "
                       ^ String.capitalize name
                       ^ " manually."
                   }
               , None )
             | _ -> failwith "Unexpected module renderer paths")
          | None -> integrate op snapshot files ~register
        in
        provider, version, files, registration, catalog_contents
      with
      | Rejected _ as exn -> raise exn
      | D.Invalid _ as exn -> raise exn
      | Core_unix.Unix_error (ENOENT, _, _) ->
        reject
          Provider_failure
          "Cannot start hardcaml-asic-starter on the service host; check its \
           installation and PATH"
      | exn -> reject Provider_failure (Exn.to_string exn))
  in
  (* One-use receipt for the frozen in-memory plan. *)
  let nonce = Cryptokit.Random.string Cryptokit.Random.secure_rng 32 in
  let preview_id = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) nonce in
  let preview =
    { Preview.preview_id
    ; operation = op
    ; new_files = List.map files ~f:(fun file -> file.File.path)
    ; provider
    ; version
    ; files
    ; registration
    }
  in
  t.pending
  <- { preview; root; components; snapshot; library; catalog_contents }
     :: List.take t.pending 127;
  Response.Previewed preview
;;

let take t id =
  let matches plan = String.equal plan.preview.preview_id id in
  match List.find t.pending ~f:matches with
  | None -> reject Stale_preview "Unknown, expired or consumed preview"
  | Some plan ->
    t.pending <- List.filter t.pending ~f:(Fn.non matches);
    plan
;;

let handle_locked ?project_identity t request =
  let created = ref [] in
  let first_dir = ref None in
  let failed kind message =
    let message =
      if List.is_empty !created && Option.is_none !first_dir
      then message
      else
        message
        ^ ". Partial output was retained. Inspect the reported files"
        ^ Option.value_map !first_dir ~default:"" ~f:(fun p -> " and directory " ^ p)
        ^ " before previewing again."
    in
    Response.Failed { kind; message; created_files = List.rev !created }
  in
  let location_error =
    match (request : Request.t) with
    | Preview _ | Preview_chip _ -> Failure.Destination_denied
    | Apply _ | Cancel _ -> Stale_preview
  in
  try
    match request with
    | Preview op -> preview t op
    | Preview_chip chip ->
      preview
        ~chip
        ?project_identity
        t
        { Operation.target = chip.target; name = chip.name; recipe = chip_recipe }
    | Cancel { preview_id } ->
      ignore (take t preview_id : plan);
      Cancelled
    | Apply { preview_id } ->
      let p = take t preview_id in
      D.visit
        ?existing:(existing_name p.preview.operation)
        ?addition:(addition p.preview.operation)
        ?library:p.library
        ~configs_required:(not (String.equal p.preview.operation.recipe chip_recipe))
        p.root
        p.components
        (fun dir snapshot ->
          if not (D.equal_snapshot p.snapshot snapshot)
          then reject Stale_preview "Destination changed since preview";
          let on_mkdir path = if Option.is_none !first_dir then first_dir := Some path in
          D.materialize ~on_mkdir dir snapshot (fun dir ->
            let on_create path = created := path :: !created in
            D.publish dir snapshot p.preview.files ~on_mkdir ~on_create;
            Option.iter p.catalog_contents ~f:(fun text ->
              D.publish_catalog dir snapshot text ~on_create)));
      let registration =
        match p.preview.registration with
        | None -> Registration_result.Not_requested
        | Some edit when Option.is_some p.catalog_contents -> Registered edit.path
        | Some edit ->
          Skipped
            { path = edit.path; reason = "Manual registration; use the preview snippet" }
      in
      let created_files =
        if Option.is_some p.catalog_contents && Option.is_none (D.catalog_text p.snapshot)
        then p.preview.new_files @ [ D.catalog ]
        else p.preview.new_files
      in
      Applied { created_files; registration }
  with
  | Rejected (kind, message) -> failed kind message
  | D.Invalid message | D.Changed message -> failed location_error message
  | Core_unix.Unix_error ((ENOENT | EEXIST | ENOTDIR | ELOOP), _, _) ->
    failed location_error "Destination unavailable or changed"
  | exn -> failed Provider_failure (Exn.to_string exn)
;;

let handle ?project_identity t request =
  Lock.protect t.mutex (fun () -> handle_locked ?project_identity t request)
;;
