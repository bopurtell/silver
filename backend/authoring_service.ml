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
  Option.some_if (String.equal op.recipe add_to_project_recipe) op.name
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

let integrate (op : Operation.t) snapshot files =
  let module I = Hardcaml_workbench_project_integration in
  let prefix = D.design_dir op.name ^ "/" in
  if not (List.for_all files ~f:(fun f -> String.is_prefix f.File.path ~prefix))
  then failwith "Existing-project renderer returned a file outside the starter directory";
  List.iter [ "dune"; "project.ml"; "chip.ml" ] ~f:(fun path ->
    if not (List.exists files ~f:(fun f -> String.equal f.File.path (prefix ^ path)))
    then failwith ("Existing-project renderer omitted " ^ prefix ^ path));
  let target = prefix ^ "project.exe" in
  let rooted = Filename.concat op.target.destination in
  let config filename sexp =
    { File.path = ".workbench/" ^ filename; contents = Sexp.to_string_hum sexp ^ "\n" }
  in
  let asic =
    config
      I.Asic_config.filename
      [%sexp
        { schema_version = (1 : int)
        ; project_executable = (rooted ("_build/default/" ^ target) : string)
        ; results_root = (rooted "_flow_results/workbench/asic" : string)
        ; toolchain = (rooted "_flow_tools" : string)
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
         ; results_root = rooted "_flow_results/workbench/preparation"
         ; timeout_seconds = 600
         })
  in
  let entry = `Assoc [ "id", `String op.name; "executable", `String target ] in
  let registration =
    Some { Registration.path = D.catalog; snippet = Yojson.Basic.to_string entry }
  in
  let files = files @ [ asic; preparation ] in
  if D.catalog_exists snapshot
  then files, registration
  else (
    let catalog =
      `Assoc
        [ "schema_version", `Int 1
        ; "default_target", `String op.name
        ; "targets", `List [ entry ]
        ]
    in
    ( files
      @ [ { File.path = D.catalog
          ; contents = Yojson.Basic.pretty_to_string catalog ^ "\n"
          }
        ]
    , registration ))
;;

let preview t (op : Operation.t) =
  let controlled = String.equal controlled_recipe op.recipe in
  let existing = existing_name op in
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
    D.visit ?existing ?addition root components (fun _ snapshot -> snapshot)
  in
  let manual =
    match addition with
    | Some (Module _) -> D.manual_modules snapshot
    | _ -> false
  in
  let provider, version, files, registration =
    if controlled
    then (
      let path = op.name ^ ".txt" in
      ( "controlled"
      , "1"
      , [ { File.path; contents = "Controlled authoring fixture: " ^ op.name ^ "\n" } ]
      , Some { Registration.path = "catalog.txt"; snippet = path ^ "\n" } ))
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
          | None -> (if Option.is_some existing then "render-existing" else "render"), []
        in
        let provider, version, files =
          Authoring_starter.parse (Authoring_starter.render ~command ~arguments op.name)
        in
        let files, registration =
          match addition with
          | Some (Ip name) ->
            let prefix = "ip/" ^ name ^ "/" in
            if not
                 (List.for_all files ~f:(fun f -> String.is_prefix f.File.path ~prefix)
                  && List.exists files ~f:(fun f ->
                    String.equal f.File.path (prefix ^ "dune")))
            then failwith "Unexpected IP renderer paths";
            files, None
          | Some (Module (parts, name)) ->
            let local file = String.concat ~sep:"/" (parts @ [ file ]) in
            (match files with
             | [ file ] when String.equal file.path (name ^ ".ml") ->
               ( [ { file with path = local file.path } ]
               , Option.some_if
                   manual
                   { Registration.path = local "dune"
                   ; snippet =
                       "Review the library's (modules ...) list and include "
                       ^ String.capitalize name
                       ^ " manually."
                   } )
             | _ -> failwith "Unexpected module renderer paths")
          | None ->
            if Option.is_some existing then integrate op snapshot files else files, None
        in
        provider, version, files, registration
      with
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
  t.pending <- { preview; root; components; snapshot } :: List.take t.pending 127;
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

let handle_locked t request =
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
    | Preview _ -> Failure.Destination_denied
    | Apply _ | Cancel _ -> Stale_preview
  in
  try
    match request with
    | Preview op -> preview t op
    | Cancel { preview_id } ->
      ignore (take t preview_id : plan);
      Cancelled
    | Apply { preview_id } ->
      let p = take t preview_id in
      D.visit
        ?existing:(existing_name p.preview.operation)
        ?addition:(addition p.preview.operation)
        p.root
        p.components
        (fun dir snapshot ->
           if not (D.equal_snapshot p.snapshot snapshot)
           then reject Stale_preview "Destination changed since preview";
           let on_mkdir path = if Option.is_none !first_dir then first_dir := Some path in
           D.materialize ~on_mkdir dir snapshot (fun dir ->
             D.publish dir snapshot p.preview.files ~on_mkdir ~on_create:(fun path ->
               created := path :: !created)));
      let registration =
        match p.preview.registration with
        | None -> Registration_result.Not_requested
        | Some edit when List.mem p.preview.new_files edit.path ~equal:String.equal ->
          Registered edit.path
        | Some edit ->
          Skipped
            { path = edit.path; reason = "Manual registration; use the preview snippet" }
      in
      Applied { created_files = p.preview.new_files; registration }
  with
  | Rejected (kind, message) -> failed kind message
  | D.Invalid message | D.Changed message -> failed location_error message
  | Core_unix.Unix_error ((ENOENT | EEXIST | ENOTDIR | ELOOP), _, _) ->
    failed location_error "Destination unavailable or changed"
  | exn -> failed Provider_failure (Exn.to_string exn)
;;

let handle t request = Lock.protect t.mutex (fun () -> handle_locked t request)
