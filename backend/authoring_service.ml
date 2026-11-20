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
  ; filename : string
  ; contents : string
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

let preview t (op : Operation.t) =
  if not (String.equal controlled_recipe op.recipe)
  then reject Invalid_operation "Unknown authoring recipe";
  if String.is_empty op.name
     || String.length op.name > 64
     || (not
           (String.for_all op.name ~f:(function
             | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
             | _ -> false)))
     || String.equal op.name "catalog"
  then reject Invalid_operation "Invalid controlled recipe name";
  let root, components = D.select t.roots op.target.destination in
  let snapshot = D.visit root components (fun _ snapshot -> snapshot) in
  let filename = op.name ^ ".txt" in
  let contents = "Controlled authoring fixture: " ^ op.name ^ "\n" in
  let registration = { Registration.path = "catalog.txt"; snippet = filename ^ "\n" } in
  (* One-use session receipt: even identical plans have independent cancel/apply
     lifetimes. Hash the exact operation, preconditions and frozen recipe output. *)
  let nonce = Cryptokit.Random.string Cryptokit.Random.secure_rng 32 in
  let preview_id =
    [%sexp
      (nonce : string)
      , (op : Operation.t)
      , (snapshot : D.snapshot)
      , (filename : string)
      , (contents : string)
      , (registration : Registration.t)]
    |> Sexp.to_string_mach
    |> Cryptokit.hash_string (Cryptokit.Hash.sha256 ())
    |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
  in
  let preview =
    { Preview.preview_id
    ; operation = op
    ; new_files = [ filename ]
    ; registration = Some registration
    }
  in
  t.pending
  <- { preview; root; components; snapshot; filename; contents }
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

let handle_locked t request =
  let created = ref [] in
  let failed kind message =
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
      D.visit p.root p.components (fun dir snapshot ->
        if not (D.equal_snapshot p.snapshot snapshot)
        then reject Stale_preview "Destination changed since preview";
        D.materialize dir snapshot (fun dir ->
          D.write dir ~name:p.filename ~contents:p.contents ~on_create:(fun () ->
            created := p.filename :: !created)));
      let registration =
        match p.preview.registration with
        | None -> Registration_result.Not_requested
        | Some edit ->
          Skipped
            { path = edit.path; reason = "Manual registration; use the preview snippet" }
      in
      Applied { created_files = List.rev !created; registration }
  with
  | Rejected (kind, message) -> failed kind message
  | D.Invalid message | D.Changed message -> failed location_error message
  | Core_unix.Unix_error ((ENOENT | EEXIST | ENOTDIR | ELOOP), _, _) ->
    failed location_error "Destination unavailable or changed"
  | exn -> failed Provider_failure (Exn.to_string exn)
;;

let handle t request = Lock.protect t.mutex (fun () -> handle_locked t request)
