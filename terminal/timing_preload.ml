open! Core
open Hardcaml_workbench_protocol

(** A bounded, level-triggered planner. Candidates are recomputed from current exact
    workspace bindings; there is deliberately no backlog of obsolete selections. An
    attempt is remembered even on failure/missing publication. Only an explicit user
    action retries it. Scope includes connection and project identity. *)
type t =
  { scope : string
  ; attempted : string list
  ; running : string option
  }

let empty = { scope = ""; attempted = []; running = None }
let limit = 128
let max_details = 5

let valid_detail_count n = n >= 0 && n <= max_details

let detail_source (view : Inspection_view.t) (index : Asic_inspection.Index.t) =
  (* Same identity as the daemon's reusable cache, excluding observation timestamps
     and the offline label. Do not retry because a publication window evicts a row. *)
  Plain_rpc.digest
    (Sexp.to_string_mach
       [%sexp
         (view.observation : (Asic.Reference.t * int * string option) option),
         ({ index with times = Evidence_time.Index.empty; cached_unverified = false }
          : Asic_inspection.Index.t)])
;;

let detail_attempt_key ~source ~row_id = source ^ ":" ^ row_id

let detail_candidates (view : Inspection_view.t) snapshot ~count =
  Option.value_map view.index ~default:[] ~f:(fun index ->
    let rows =
      Timing_workspace.top_path_ids view ~count
      |> List.filter ~f:(fun row_id ->
        Option.is_none (Timing_workspace.published_detail view snapshot ~row_id))
    in
    if List.is_empty rows
    then []
    else (
      let source = detail_source view index in
      List.map rows ~f:(fun row_id ->
        ( detail_attempt_key ~source ~row_id
        , ( view
          , Inspection_view.detail_operation view ~source_digest:index.source_digest ~row_id )
        ))))
;;

let remember t ~scope ~key =
  let t = if String.equal t.scope scope then t else { empty with scope } in
  if List.length t.attempted >= limit || List.mem t.attempted key ~equal:String.equal
  then t
  else { t with attempted = key :: t.attempted }
;;

let step t ~scope ~enabled ~interactive ~candidates =
  let t = if String.equal t.scope scope then t else { empty with scope } in
  if (not enabled)
     || interactive
     || Option.is_some t.running
     || List.length t.attempted >= limit
  then t, None
  else (
    match
      List.find candidates ~f:(fun key ->
        not (List.mem t.attempted key ~equal:String.equal))
    with
    | None -> t, None
    | Some key -> { t with attempted = key :: t.attempted; running = Some key }, Some key)
;;

let finish t ~scope ~key =
  if String.equal t.scope scope && Option.equal String.equal t.running (Some key)
  then { t with running = None }
  else t
;;

let%test_unit "selection changes discard backlog without releasing active work" =
  let step t candidates =
    step t ~scope:"s" ~enabled:true ~interactive:false ~candidates
  in
  let t, _ = step empty [ "old-source"; "obsolete-selection" ] in
  let t, request = step t [ "new-source" ] in
  assert (Option.is_none request);
  assert (Option.equal String.equal t.running (Some "old-source"));
  let unrelated = finish t ~scope:"s" ~key:"new-source" in
  assert (Option.equal String.equal unrelated.running t.running);
  let t = finish t ~scope:"s" ~key:"old-source" in
  let _, request = step t [ "new-source" ] in
  assert (Option.equal String.equal request (Some "new-source"))
;;

let%test_unit "finite failure, coalescing, priority, scope fences and bounded memory" =
  let plan = step in
  let step ?(enabled = true) ?(interactive = false) t candidates =
    step t ~scope:"connection/project" ~enabled ~interactive ~candidates
  in
  let t, request = step empty [ "exact-a"; "exact-b" ] in
  assert (Option.equal String.equal request (Some "exact-a"));
  assert (Option.is_none (snd (step t [ "exact-a"; "exact-b" ])));
  let stale = finish t ~scope:"old-connection/project" ~key:"exact-a" in
  assert (Option.is_some stale.running);
  let t = finish t ~scope:"connection/project" ~key:"exact-a" in
  for _ = 1 to 100 do
    assert (Option.is_none (snd (step t [ "exact-a" ])))
  done;
  assert (Option.is_none (snd (step ~interactive:true t [ "exact-b" ])));
  assert (Option.is_none (snd (step ~enabled:false t [ "exact-b" ])));
  let t, request = step t [ "exact-b" ] in
  assert (Option.equal String.equal request (Some "exact-b"));
  let t =
    List.fold (List.init 1000 ~f:Int.to_string) ~init:t ~f:(fun t key ->
      let t = { t with running = None } in
      fst (step t [ key ]))
  in
  assert (List.length t.attempted = limit);
  assert (
    Option.is_none (snd (step { t with running = None } [ "exact-a"; "never-seen" ])));
  let _, request =
    plan
      t
      ~scope:"new-connection/project"
      ~enabled:true
      ~interactive:false
      ~candidates:[ "exact-a" ]
  in
  assert (Option.is_some request)
;;

let%test_unit "top details follow path order, skip cache publications, and do not poll-retry" =
  let run = Asic_snapshot_fixture.run_a in
  let row id value : Asic_inspection.Row.t =
    { id
    ; name = id
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; value = Some value
    ; unit_ = Some "ns"
    ; status = "met"
    ; source = "/report"
    ; fields = []
    }
  in
  let detail ?error row_id : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id
    ; text = "provider detail " ^ row_id
    ; error
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; rows =
        [ row "a" 0.
        ; row "c" 2.
        ; row "a" 0.
        ; row "b" 1.
        ; row "d" 3.
        ; { (row "not-a-path" 4.) with category = "input_reference" }
        ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { Asic_snapshot_fixture.snapshot with inspections = [ index ] } in
  let view = Timing_workspace.create ~generation:1 ~run ~stage:"signoff" in
  let view = Inspection_view.reconcile { view with sort = Numeric_descending } snapshot in
  assert (
    List.equal String.equal (Timing_workspace.top_path_ids view ~count:5) [ "d"; "c"; "b"; "a" ]);
  let published =
    { snapshot with inspection_details = [ detail "d"; detail ~error:"missing" "c" ] }
  in
  let candidates = detail_candidates view published ~count:5 in
  assert (
    List.equal String.equal
      (List.map candidates ~f:(function
         | _, (_, Asic.Operation.Inspect_detail { row_id; _ }) -> row_id
         | _ -> assert false))
      [ "b"; "a" ]);
  let keys = List.map candidates ~f:fst in
  let plan t candidates =
    step t ~scope:"project" ~enabled:true ~interactive:false ~candidates
  in
  let t, key = plan empty keys in
  let key = Option.value_exn key in
  let t = finish t ~scope:"project" ~key in
  assert (Option.is_none (snd (plan t [ key ])));
  assert (Option.is_some (snd (plan t keys)));
  (* Reusing the public digest and row IDs with different execution bytes is a new source. *)
  let replacement = { view with index = Some { index with execution_sha256 = "other" } } in
  let keys = List.map (detail_candidates replacement published ~count:5) ~f:fst in
  assert (List.length keys = 2 && not (List.mem keys key ~equal:String.equal))
;;
