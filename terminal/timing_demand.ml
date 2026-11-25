open! Core
open Silver_protocol

(* A finite client intention, not a daemon queue. Only [step] may issue work; a receipt
   alone is not completion when the daemon accepted a pending read. *)
type flight =
  { ticket : int
  ; key : string
  ; row_id : string
  ; failed : bool
  ; acknowledged : bool
  ; floor : int
  ; recoverable : bool
  }

type t =
  { origin : Inspection_view.t
  ; source : Asic_inspection.Index.t option
  ; observation : Inspection_view.observation option
  ; neighbors : int
  ; selected : string option
  ; order : string list
  ; attempted : string list
  ; automatic : bool
  ; flight : flight option
  ; serial : int
  }

type request =
  { ticket : int
  ; operation : Asic.Operation.t
  ; selected : bool
  }

let create ?(automatic = false) ~neighbors (view : Inspection_view.t) =
  if neighbors < 0 || neighbors > 2 then invalid_arg "Timing neighbors must be 0..2";
  { origin = view
  ; source = view.index
  ; observation = view.observation
  ; neighbors
  ; selected = None
  ; order = []
  ; attempted = []
  ; automatic
  ; flight = None
  ; serial = 0
  }
;;

let receipt ?(floor = 0) t ~ticket response =
  match t.flight with
  | Some flight when flight.ticket = ticket ->
    { t with
      flight =
        Some
          { flight with
            failed = Result.is_error response
          ; acknowledged = true
          ; floor
          ; recoverable = false
          }
    }
  | _ -> t
;;

let same_source = Inspection_view.same_index_source

let restart ?automatic ?neighbors t ~(view : Inspection_view.t) =
  let automatic = Option.value automatic ~default:t.automatic in
  let neighbors = Option.value neighbors ~default:t.neighbors in
  let next = { (create ~automatic ~neighbors view) with serial = t.serial } in
  if Run_ref.equal t.origin.run view.run
     && String.equal t.origin.stage view.stage
     && Option.equal Asic_inspection.Analysis_target.equal t.origin.analysis view.analysis
     && Option.equal String.equal t.origin.workspace_epoch view.workspace_epoch
     && Option.equal Inspection_view.equal_observation t.observation view.observation
     && Option.equal same_source t.source view.index
  then
    { next with
      flight = Option.filter t.flight ~f:(fun flight -> not flight.recoverable)
    }
  else next
;;

let is_automatic t = t.automatic

let step ?(revision = 0) ?(blocked = false) ?(allow_neighbors = true) ?joining t
  ~(view : Inspection_view.t) (snapshot : Asic.Snapshot.t) =
  let valid =
    Run_ref.equal t.origin.run view.run
    && String.equal t.origin.stage view.stage
    && Option.equal Asic_inspection.Analysis_target.equal t.origin.analysis view.analysis
    && Option.equal String.equal t.origin.workspace_epoch view.workspace_epoch
    && ((Option.is_none t.source && Option.is_none t.observation)
        || Option.equal Inspection_view.equal_observation t.observation view.observation)
    &&
    match t.source, view.index with
    | None, _ -> true
    | Some a, Some b -> same_source a b
    | Some _, None -> false
  in
  if not valid
  then None, view, None
  else (
    let source = Option.first_some t.source view.index in
    let order = List.map (Inspection_view.visible view) ~f:(fun row -> row.id) in
    let changed =
      (not (Option.equal String.equal t.selected view.selected))
      || not (List.equal String.equal t.order order)
    in
    let t =
      { t with
        source
      ; observation = view.observation
      ; selected = view.selected
      ; order
      ; attempted = (if changed then [] else t.attempted)
      }
    in
    let detail row_id =
      List.find snapshot.inspection_details ~f:(fun d ->
        Run_ref.equal d.Asic_inspection.Detail.run view.run
        && String.equal d.domain view.domain
        && String.equal d.stage view.stage
        && String.equal d.row_id row_id
        && Option.value_map source ~default:false ~f:(fun i ->
          String.equal i.source_digest d.source_digest))
    in
    let flight =
      Option.bind t.flight ~f:(fun flight ->
        let operation =
          List.find snapshot.operations ~f:(fun op -> String.equal op.key flight.key)
        in
        let published = detail flight.row_id in
        let completed =
          match operation with
          | Some op ->
            List.mem
              [ "completed"; "failed"; "cancelled"; "detached" ]
              op.state
              ~equal:String.equal
          | None -> Option.is_some published || t.automatic
        in
        let eligible = flight.acknowledged && revision >= flight.floor in
        if flight.failed || (eligible && completed)
        then None
        else
          Some
            { flight with
              recoverable =
                eligible && Option.is_none operation && Option.is_none published
            })
    in
    let t = { t with flight } in
    let t =
      match source, view.selected, flight with
      | Some index, Some row_id, None ->
         let key = Inspection_view.detail_key view ~source_digest:index.source_digest ~row_id in
         if Option.equal String.equal joining (Some key)
         then
           { t with attempted = row_id :: List.filter t.attempted ~f:(Fn.non (String.equal row_id)) }
        else t
      | _ -> t
    in
    match source, view.selected, flight with
    | Some index, Some selected, None when not blocked ->
      let position =
        List.findi order ~f:(fun _ id -> String.equal id selected)
        |> Option.value_map ~default:0 ~f:fst
      in
      let neighbors =
        (* Next, then previous; at an edge use the next closest available row. *)
        List.concat_map [ 1; 2 ] ~f:(fun distance ->
          List.filter_map
            [ position + distance; position - distance ]
            ~f:(fun n -> if n < 0 then None else List.nth order n))
         |> Fn.flip List.take (if allow_neighbors then t.neighbors else 0)
      in
      let candidate =
        List.find (selected :: neighbors) ~f:(fun id ->
          (not (List.mem t.attempted id ~equal:String.equal))
           &&
           match detail id with
           | None ->
             not
               (String.equal id selected
                && Option.exists view.detail ~f:(fun d -> Option.is_none d.error))
           | Some d ->
             (* A deliberate reopen/Enter can retry a failed selected detail, but must
                not re-read successful evidence already published. *)
             not t.automatic && String.equal id selected && Option.is_some d.error)
      in
      (match candidate with
       | None ->
         let view =
           if List.mem t.attempted selected ~equal:String.equal
              && Option.is_some view.requested
              && Option.is_none view.detail
              && Option.is_none view.pending_error
              && Option.is_none view.error
           then { view with error = Some "Timing detail unavailable · Enter retries" }
           else view
         in
         Some t, view, None
       | Some row_id ->
         let operation =
           Inspection_view.detail_operation
             view
             ~source_digest:index.source_digest
             ~row_id
         in
         let key =
           Inspection_view.detail_key view ~source_digest:index.source_digest ~row_id
         in
         let selected = String.equal row_id selected in
         let view =
           if not selected
           then view
           else
             { view with
               requested = Some (index.source_digest, row_id)
              ; operation_key = Option.some_if (not t.automatic) key
             ; error = None
             ; pending_error = None
             }
         in
         let ticket = t.serial + 1 in
         ( Some
             { t with
               serial = ticket
             ; attempted = row_id :: t.attempted
             ; flight =
                 Some
                   { ticket
                   ; key
                   ; row_id
                   ; failed = false
                   ; acknowledged = false
                   ; floor = 0
                   ; recoverable = false
                   }
             }
         , view
         , Some { ticket; operation; selected } ))
    | _ -> Some t, view, None)
;;

module Fixture = struct
  let run = Asic_snapshot_fixture.run_a

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
  ;;

  let index : Asic_inspection.Index.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; rows = [ row "a" 0.; row "b" 1.; row "c" 2.; row "d" 3. ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  ;;

  let snapshot = { Asic_snapshot_fixture.snapshot with inspections = [ index ] }
  let cold = Timing_workspace.create ~generation:1 ~run ~stage:"signoff"
  let view = Inspection_view.reconcile cold snapshot

  let detail ?error row_id : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id
    ; text = "provider detail " ^ row_id
    ; error
    }
  ;;

  let issued state view snapshot expected =
    let state, view, request = step state ~view snapshot in
    let state = Option.value_exn state in
    let request = Option.value_exn request in
    (match request.operation with
     | Inspect_detail { row_id; _ } -> assert (String.equal row_id expected)
     | _ -> assert false);
    state, view, request
  ;;

  let quiet state view snapshot =
    let state, _, request = step state ~view snapshot in
    assert (Option.is_none request);
    Option.value_exn state
  ;;
end

let%test_unit "production planner: cold/warm open, selected first, deferred completion, \
               finite warming"
  =
  let open Fixture in
  let initial = create ~neighbors:2 cold in
  let initial = quiet initial cold { snapshot with inspections = [] } in
  let state, view, selected = issued initial view snapshot "a" in
  assert selected.selected;
  (* Even a publication received while HTTP is held cannot issue a second request. *)
  let published = { snapshot with inspection_details = [ detail "a" ] } in
  let state = quiet state view published in
  let state = receipt state ~ticket:selected.ticket (Ok ()) in
  let state, view, neighbor = issued state view published "b" in
  assert (not neighbor.selected);
  assert (Option.equal String.equal view.selected (Some "a"));
  assert (
    Option.equal
      String.equal
      view.operation_key
      (Some
         (Asic_inspection.detail_key
            ~run
            ~domain:"timing"
            ~stage:"signoff"
            ~source_digest:"digest"
            ~row_id:"a")));
  let state = receipt state ~ticket:neighbor.ticket (Ok ()) in
  let state = quiet state view published in
  let published =
    { published with inspection_details = detail "b" :: published.inspection_details }
  in
  let state, view, last = issued state view published "c" in
  let state = receipt state ~ticket:last.ticket (Ok ()) in
  let published =
    { published with inspection_details = detail "c" :: published.inspection_details }
  in
  let state = quiet state view published in
  ignore
    (List.fold (List.init 100 ~f:Fn.id) ~init:state ~f:(fun state _ ->
       quiet state view published)
     : t);
  (* A warm index explicitly reopened starts selected demand again. *)
  ignore
    (issued (create ~neighbors:0 view) view snapshot "a"
     : t * Inspection_view.t * request)
;;

let%test_unit "production planner: navigation priority, stale receipts, failed reads do \
               not poll-retry"
  =
  let open Fixture in
  let state, view, first = issued (create ~neighbors:2 view) view snapshot "a" in
  let view = { view with selected = Some "d"; requested = None; detail = None } in
  let state = quiet state view snapshot in
  let state = receipt state ~ticket:first.ticket (Error "failed a") in
  let state, view, next = issued state view snapshot "d" in
  (* A late receipt for a cannot acknowledge or release d. *)
  let state = receipt state ~ticket:first.ticket (Error "stale") in
  let published = { snapshot with inspection_details = [ detail "d" ] } in
  let state = quiet state view published in
  let state = receipt state ~ticket:next.ticket (Error "transport") in
  let state, view, neighbor = issued state view snapshot "c" in
  let state = receipt state ~ticket:neighbor.ticket (Ok ()) in
  let failed =
    { snapshot with inspection_details = [ detail ~error:"provider failed" "c" ] }
  in
  let state, view, last = issued state view failed "b" in
  let state = receipt state ~ticket:last.ticket (Error "transport") in
  let state = quiet state view failed in
  ignore
    (List.fold (List.init 100 ~f:Fn.id) ~init:state ~f:(fun state _ ->
       quiet state view failed)
     : t);
  (* Enter/reopen creates a new finite intention; failures are retryable explicitly. *)
  ignore
    (issued (create ~neighbors:0 view) view failed "d" : t * Inspection_view.t * request)
;;

let%test_unit "production planner: neighbors use current filtered/sorted order; zero \
               disables speculation"
  =
  let open Fixture in
  let view =
    Inspection_view.normalize
      { view with sort = Numeric_descending; selected = Some "c"; filter = "" }
  in
  let view =
    { view with
      index =
        Some
          { index with
            rows = List.filter index.rows ~f:(fun row -> not (String.equal row.id "b"))
          }
    ; cache = None
    }
  in
  let state, view, first = issued (create ~neighbors:1 view) view snapshot "c" in
  let state = receipt state ~ticket:first.ticket (Error "done") in
  ignore (issued state view snapshot "a" : t * Inspection_view.t * request);
  let state, view, first = issued (create ~neighbors:0 view) view snapshot "c" in
  let state = receipt state ~ticket:first.ticket (Error "done") in
  ignore (quiet state view snapshot : t)
;;

let%test_unit "production planner: exact lifecycle invalidation stops scheduling" =
  let open Fixture in
  let state, view, _ = issued (create ~neighbors:2 view) view snapshot "a" in
  List.iter
    [ { view with stage = "routing" }
    ; { view with run = Asic_snapshot_fixture.run_b }
    ; { view with workspace_epoch = Some "reselected" }
    ; { view with index = None }
    ; { view with index = Some { index with source_digest = "new" } }
    ; { view with index = Some { index with execution_sha256 = "new" } }
    ; { view with index = Some { index with execution_file = "/new" } }
    ; { view with index = Some { index with rows = [ row "a" 99. ] } }
    ]
    ~f:(fun view ->
      let next, _, request = step state ~view snapshot in
      assert (Option.is_none next && Option.is_none request))
;;

let%test_unit "selected successful detail survives publication eviction only for exact \
               source and row"
  =
  let open Fixture in
  let _, view, _ = issued (create ~neighbors:0 view) view snapshot "a" in
  let loaded =
    Inspection_view.reconcile view { snapshot with inspection_details = [ detail "a" ] }
  in
  let evicted = Inspection_view.reconcile loaded snapshot in
  assert (Option.is_some evicted.detail);
  List.iter
    [ { index with source_digest = "new" }
    ; { index with execution_sha256 = "new" }
    ; { index with execution_file = "/new" }
    ; { index with rows = [ row "a" 99. ] }
    ; { index with rows = [] }
    ]
    ~f:(fun index ->
      let invalid =
        Inspection_view.reconcile loaded { snapshot with inspections = [ index ] }
      in
      assert (Option.is_none invalid.detail && Option.is_none invalid.requested));
  let failed =
    Inspection_view.reconcile
      view
      { snapshot with inspection_details = [ detail ~error:"failed" "a" ] }
  in
  assert (Option.is_none (Inspection_view.reconcile failed snapshot).detail)
;;

let%test_unit "production planner: receipt floor and active retry fence old detail \
               publications"
  =
  let open Fixture in
  let state, view, first = issued (create ~neighbors:2 view) view snapshot "a" in
  let published = { snapshot with inspection_details = [ detail "a" ] } in
  let state = receipt ~floor:10 state ~ticket:first.ticket (Ok ()) in
  let next, _, request = step ~revision:9 state ~view published in
  assert (Option.is_none request);
  let state = Option.value_exn next in
  let key = Option.value_exn view.operation_key in
  let operation : Asic.Pending.t =
    { key
    ; kind = "inspection-detail"
    ; state = "executing"
    ; run = Some run
    ; error = None
    ; activity = Evidence_read
    }
  in
  let pending = { published with operations = [ operation ] } in
  let next, _, request = step ~revision:10 state ~view pending in
  assert (Option.is_none request);
  let state = Option.value_exn next in
  let completed =
    { published with operations = [ { operation with state = "completed" } ] }
  in
  let _, _, request = step ~revision:11 state ~view completed in
  assert (Option.is_some request)
;;

let%test_unit "production planner: reopen keeps held work serial and source restart \
               rejects stale ticket"
  =
  let open Fixture in
  let state, view, first = issued (create ~neighbors:2 view) view snapshot "a" in
  let state = restart state ~view in
  let state = quiet state view snapshot in
  let changed = { view with index = Some { index with source_digest = "new" } } in
  let state = restart state ~view:changed in
  let state, changed, next = issued state changed snapshot "a" in
  assert (next.ticket > first.ticket);
  let state = receipt state ~ticket:first.ticket (Error "obsolete") in
  ignore (quiet state changed snapshot : t)
;;

let%test_unit "exact run observation fences retained detail and demand through repeated \
               unverified advances"
  =
  let open Fixture in
  let registered = List.find_exn snapshot.runs ~f:(fun r -> Run_ref.equal r.run run) in
  let state, selected, request = issued (create ~neighbors:2 view) view snapshot "a" in
  let ticket = Inspection_view.capture selected request.operation in
  let loaded =
    Inspection_view.reconcile
      selected
      { snapshot with inspection_details = [ detail "a" ] }
  in
  assert (Option.is_some (Inspection_view.reconcile loaded snapshot).detail);
  let unverified = { index with cached_unverified = true } in
  let advanced registered =
    { snapshot with
      inspections = [ unverified ]
    ; runs =
        registered
        :: List.filter snapshot.runs ~f:(fun r -> not (Run_ref.equal r.run run))
    }
  in
  let assert_invalid state selected snapshot =
    let next = Inspection_view.reconcile selected snapshot in
    assert (Option.is_none next.detail && Option.is_none next.requested);
    assert (next.generation > selected.Inspection_view.generation);
    assert (
      Option.is_none (Inspection_view.apply_response next ticket (Error "obsolete")).error);
    let demand, _, request = step state ~view:next snapshot in
    assert (Option.is_none demand && Option.is_none request);
    next
  in
  (* A reference replacement alone is sufficient, even with identical bytes and cursor. *)
  ignore
    (assert_invalid
       state
       loaded
       { (advanced
            { registered with
              reference = { registered.reference with attempt = "/replacement" }
            })
         with
         inspections = [ index ]
       }
     : Inspection_view.t);
  (* Also stop on a trust transition even if no run observation changed. *)
  ignore (assert_invalid state loaded (advanced registered) : Inspection_view.t);
  let registered = { registered with cursor = registered.cursor + 1 } in
  let stale = advanced registered in
  let next = assert_invalid state loaded stale in
  (* An explicit warm unverified open may read detail, but never relabels the index
     verified. *)
  let state, selected, _ = issued (create ~neighbors:2 next) next stale "a" in
  assert (Option.value_exn selected.index).cached_unverified;
  assert (
    List.exists
      (Timing_workspace.rows ~pane:Context ~scroll:0 ~width:120 ~height:100 selected)
      ~f:(String.is_substring ~substring:"CACHED UNVERIFIED"));
  let loaded =
    Inspection_view.reconcile selected { stale with inspection_details = [ detail "a" ] }
  in
  assert (Option.is_some (Inspection_view.reconcile loaded stale).detail);
  ignore
    (assert_invalid
       state
       loaded
       (advanced
          { registered with
            reference = { registered.reference with attempt = "/replacement-unverified" }
          })
     : Inspection_view.t);
  (* The boolean stays true on this second cursor advance: identity must still fence it. *)
  ignore
    (assert_invalid
       state
       loaded
       (advanced { registered with cursor = registered.cursor + 1 })
     : Inspection_view.t)
;;

let%test_unit "vanished acknowledged completion is quiet on polls and recoverable by \
               explicit retry"
  =
  let open Fixture in
  let state, view, first = issued (create ~neighbors:2 view) view snapshot "a" in
  let state = receipt ~floor:10 state ~ticket:first.ticket (Ok ()) in
  (* Missing records in a snapshot issued before the receipt do not authorize recovery. *)
  let next, _, request = step ~revision:9 state ~view snapshot in
  assert (Option.is_none request);
  let held = restart (Option.value_exn next) ~view in
  ignore (quiet held view snapshot : t);
  (* Once both records are absent after the floor, preserve a quiet, explicitly retryable
     slot. *)
  let next, _, request = step ~revision:10 state ~view snapshot in
  assert (Option.is_none request);
  let state = Option.value_exn next in
  let state =
    List.fold (List.init 100 ~f:Fn.id) ~init:state ~f:(fun state _ ->
      let next, _, request = step ~revision:10 state ~view snapshot in
      assert (Option.is_none request);
      Option.value_exn next)
  in
  let state, view, retry = issued (restart state ~view) view snapshot "a" in
  assert (retry.ticket > first.ticket && retry.selected);
  let state = receipt state ~ticket:first.ticket (Error "late obsolete receipt") in
  ignore (quiet state view snapshot : t);
  let state = receipt state ~ticket:retry.ticket (Ok ()) in
  let completed = { snapshot with inspection_details = [ detail "a" ] } in
  ignore (issued state view completed "b" : t * Inspection_view.t * request)
;;

let%test_unit "highlight attaches exact published detail and joins a matching held read" =
  let open Fixture in
  let snapshot = { snapshot with inspection_details = [ detail "a"; detail "b" ] } in
  let choose id =
    Timing_workspace.attach_selected { view with selected = Some id } snapshot
    |> Timing_workspace.want_selected_detail
  in
  let b = choose "b" in
  assert (String.equal (Option.value_exn b.detail).text "provider detail b");
  let _, _, request = step (create ~automatic:true ~neighbors:0 b) ~view:b snapshot in
  assert (Option.is_none request);
  let c = choose "c" in
  assert (Option.is_none c.detail && Option.is_some c.requested);
  let demand = create ~automatic:true ~neighbors:0 c in
  let held, _, request = step ~blocked:true demand ~view:c snapshot in
  assert (Option.is_none request);
  ignore (issued (Option.value_exn held) c snapshot "c" : t * Inspection_view.t * request);
  let joined, _, request =
    let key = Inspection_view.detail_key c ~source_digest:index.source_digest ~row_id:"c" in
    step ~blocked:true ~joining:key demand ~view:c snapshot
  in
  assert (Option.is_none request);
  let failed, view, request = step (Option.value_exn joined) ~view:c snapshot in
  assert (Option.is_some view.error && Option.is_none request);
  ignore (quiet (Option.value_exn failed) view snapshot : t)
;;
