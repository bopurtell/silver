open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module W = Workspace
module O = Overview_tiles

(** Palette commands carry the selected stage/run, never a request to look up whichever
    row happens to be selected when Enter is pressed. Registry capture and the existing
    dispatcher fence the context; named shortcuts additionally capture resolved inputs. *)
let selected_checklist host ~asic =
  let open Result.Let_syntax in
  let%bind registry =
    Option.value_map
      host.H.registry
      ~default:(Error "Workspace registry unavailable")
      ~f:Result.return
  in
  let candidates =
    List.filter registry.tiles ~f:(fun tile ->
      String.equal tile.kind "stage-checklist"
      && Option.equal W.Workspace_id.equal host.active (Some tile.workspace))
  in
  let candidates =
    match
      List.find candidates ~f:(fun tile ->
        Option.equal W.Tile_id.equal host.focus (Some tile.id))
    with
    | Some focused -> [ focused ]
    | None -> candidates
  in
  let resolve tile =
    let%bind reference =
      W.resolve_tile registry tile.W.Tile.id
      |> Result.map_error ~f:(fun error -> error.V1.Error.message)
    in
    let run = reference.run in
    let items = O.selectable_checklist ~asic ~remembered:host.remembered_selection ~run in
    H.checklist_cursor_for (H.local host tile.id) ~run ~items
    |> Option.value_map
         ~default:
           (Error
              (Option.value
                 (Result.error
                    (Stage_action.checklist_inputs
                       ~snapshot:asic
                       ~remembered:host.remembered_selection))
                 ~default:"No fresh endpoints advertised for the selected flow"))
         ~f:(fun item -> Ok (item, run))
  in
  match candidates with
  | [] -> Error "No stage checklist in the active workspace"
  | first :: rest ->
    let%bind item, run = resolve first in
    if List.for_all rest ~f:(fun tile ->
         match resolve tile with
         | Ok (other, other_run) ->
           Option.equal Run_ref.equal run other_run
           && String.equal (O.checklist_id item) (O.checklist_id other)
         | Error _ -> false)
    then Ok (item, run)
    else Error "Multiple checklist selections; focus the intended stage checklist"
;;

let fresh_selection ~asic ~remembered (item : O.checklist_item) =
  match item with
  | Catalog_endpoint endpoint ->
    Stage_action.checklist_fresh ~snapshot:asic ~remembered endpoint
  | Physical_stage stage ->
    Stage_action.checklist_fresh ~snapshot:asic ~remembered stage.id
  | Timing_analysis _ -> Stage_action.checklist_fresh ~snapshot:asic ~remembered "timing"
  | Elaboration_preparation ->
    Result.bind
      (Stage_action.checklist_inputs ~snapshot:asic ~remembered)
      ~f:(fun (s, flow) ->
        let endpoint =
          if List.mem flow.fresh_stage_endpoints s.endpoint ~equal:String.equal
          then Some s.endpoint
          else Launch_preferences.default_endpoint flow
        in
        Option.value_map
          endpoint
          ~default:(Error "No fresh endpoints advertised for Elaboration")
          ~f:(fun endpoint -> Ok { s with endpoint }))
;;

let manual_action ~asic ~remembered (item, run) =
  match item, run with
  | O.Catalog_endpoint _, _ ->
    Result.map (fresh_selection ~asic ~remembered item) ~f:(fun s -> H.Asic (Plan s))
  | Elaboration_preparation, _ -> Ok H.Prepare_project
  | Physical_stage stage, Some run -> Ok (H.Prepare_stage (stage, run))
  | Timing_analysis _, Some run -> Ok (H.Prepare_endpoint ("timing", run))
  | _, None -> Error "No run selected for historical stage"
;;

let quick_action host ~asic ~remembered (item, run) =
  let open Result.Let_syntax in
  let%bind selection = fresh_selection ~asic ~remembered item in
  let%map () =
    match item with
    | Elaboration_preparation ->
      Preparation_view.stage
        ~snapshot:host.H.preparation
        ~selection:(Ok selection)
        ~expected_plan_identity:None
      |> Result.map ~f:ignore
    | _ -> Ok ()
  in
  H.Quick_launch_selected (item, run, selection)
;;

let selected_commands host ~asic =
  let target = selected_checklist host ~asic in
  let actions quick =
    Result.bind target ~f:(fun (item, run) ->
      if quick
      then quick_action host ~asic ~remembered:host.H.remembered_selection (item, run)
      else (
        let eligibility =
          match item, run, Launch_preferences.chip_target asic with
          | Timing_analysis _, Some run, Some _ ->
            Stage_action.validate_evidence
              ~snapshot:asic
              ~observed:(O.execution ~asic ~run |> Option.bind ~f:(fun r -> r.selection))
          | Physical_stage stage, Some run, Some _ ->
            Stage_action.resolve
              ~stage
              ~remembered:host.H.remembered_selection
              ~observed:(O.execution ~asic ~run |> Option.bind ~f:(fun r -> r.selection))
              ~snapshot:asic
            |> Result.map ~f:ignore
          | _ -> Ok ()
        in
        Result.bind eligibility ~f:(fun () ->
          manual_action ~asic ~remembered:host.remembered_selection (item, run))))
  in
  List.map
    [ "stage.quick-selected", "Quick launch selected stage", true
    ; "stage.plan-selected", "Plan selected checklist stage for manual launch", false
    ]
    ~f:(fun (id, title, quick) ->
      let actions = actions quick in
      H.command
        ?unavailable:(Result.error actions)
        id
        (Artifact_view.safe
           (title
            ^ Option.value_map
                (Launch_preferences.chip_target asic)
                ~default:""
                ~f:(fun t -> " — " ^ Launch_preferences.chip_label (Some t))))
        (if quick then "quick launch selected checklist stage" else "stage input plan")
        (actions |> Result.ok |> Option.value ~default:H.Unavailable_launch))
;;

let workspace_run host =
  Option.bind host.H.registry ~f:(fun registry ->
    Option.bind (H.active host) ~f:(fun workspace ->
      (W.context registry workspace.context).selected_run))
;;

let validate_selected host ~asic ~item ~run =
  Result.bind (selected_checklist host ~asic) ~f:(fun (current, current_run) ->
    let same_action =
      match item, current with
      | O.Physical_stage before, O.Physical_stage after ->
        Option.equal Asic.Selection.equal before.action after.action
      | _ -> true
    in
    if Option.equal Run_ref.equal run current_run
       && String.equal (O.checklist_id item) (O.checklist_id current)
       && same_action
    then Ok ()
    else Error "Captured checklist selection changed; reopen the palette")
;;

let observed_selection asic run =
  O.execution ~asic ~run |> Option.bind ~f:(fun execution -> execution.selection)
;;

let resolve ~asic ~remembered ~run intent =
  Stage_action.resolve_intent
    ~intent
    ~remembered
    ~observed:(Option.bind run ~f:(observed_selection asic))
    ~snapshot:asic
;;

(** An advertised action may authorize an endpoint absent from the catalog, but only while
    the current observation still advertises that exact action. Historical status alone is
    never a capability. *)
let validate_named ~asic ~remembered ~run ~intent ~selection =
  let open Result.Let_syntax in
  let%bind () =
    match intent with
    | Stage_action.Physical_stage stage when Option.is_some stage.action ->
      let stages =
        Option.value_map run ~default:[] ~f:(fun run -> O.observed_stages ~asic ~run)
      in
      if List.exists stages ~f:(fun current ->
           String.equal current.id stage.id
           && Option.equal Asic.Selection.equal current.action stage.action)
      then Ok ()
      else Error "Captured stage action is no longer advertised; reopen the palette"
    | _ -> Ok ()
  in
  let%bind current = resolve ~asic ~remembered ~run intent in
  if Asic.Selection.equal current selection
  then Ok ()
  else Error "Stage launch inputs changed; reopen the palette"
;;

let legacy_named_action ~asic ~remembered ~endpoint (stage : Asic.Stage.t) =
  Option.is_none (Launch_preferences.chip_target asic)
  && not (Option.exists asic ~f:(fun snapshot -> not (List.is_empty snapshot.flows)))
  && String.equal stage.id endpoint
  && Option.exists stage.action ~f:(fun action ->
    String.equal action.endpoint endpoint
    && Option.for_all (Launch_preferences.for_target asic remembered) ~f:(fun s ->
      Asic.Selection.equal { s with endpoint } action))
;;

let validate_named_launch ~asic ~remembered ~run ~intent ~selection =
  match intent with
  | Stage_action.Physical_stage stage
    when not (legacy_named_action ~asic ~remembered ~endpoint:stage.id stage) ->
    Error "Current fresh stage launch inputs changed; reopen the palette"
  | _ -> validate_named ~asic ~remembered ~run ~intent ~selection
;;

let named_commands host ~asic ~remembered =
  let run = workspace_run host in
  let stages =
    Option.value_map run ~default:[] ~f:(fun run -> O.observed_stages ~asic ~run)
  in
  let endpoints =
    let flow =
      Option.first_some
        (Option.map (Launch_preferences.for_target asic remembered) ~f:(fun s -> s.flow))
        (Option.bind asic ~f:(fun s -> Option.map s.catalog_default ~f:(fun p -> p.flow)))
    in
    Option.bind asic ~f:(fun s ->
      List.find s.flows ~f:(fun candidate ->
        Option.equal String.equal flow (Some candidate.id)))
    |> Option.value_map ~default:[] ~f:(fun flow -> flow.fresh_stage_endpoints)
  in
  (* Known names stay discoverable with explicit disabled reasons. Custom endpoints come
     only from this selected flow or an observed stage, and undergo the same resolver. *)
  let names =
    endpoints
    @ List.map stages ~f:(fun s -> s.Asic.Stage.id)
    @ H.known_stage_endpoints
    |> List.stable_dedup ~compare:String.compare
  in
  List.map names ~f:(fun endpoint ->
    let intent, run =
      (* Named launches use the remembered recipe or the catalog default, never the
         viewed run's inputs. Legacy providers without a catalog can still advertise
         an exact action if it does not conflict with the current recipe. *)
      match List.find stages ~f:(legacy_named_action ~asic ~remembered ~endpoint) with
      | Some stage -> Stage_action.Physical_stage stage, run
      | None -> Fresh_endpoint endpoint, None
    in
    let action =
      if Option.is_none (H.launch_target host)
      then
        Error
          "Active workspace context unavailable; cannot capture launch-and-view target"
      else
        Result.map (resolve ~asic ~remembered ~run intent) ~f:(fun selection ->
          H.Launch_stage_and_view (intent, run, selection))
    in
    H.command
      ?unavailable:(Result.error action)
      (H.named_stage_command_id endpoint)
      (Artifact_view.safe
         ("Launch "
          ^ endpoint
          ^ " and view"
           ^ (match action, Launch_preferences.chip_target asic with
              | Ok (H.Launch_stage_and_view (_, _, selection)), _ ->
                " — " ^ Launch_preferences.label selection
             | _, Some target when Option.is_some (Option.bind asic ~f:Launch_preferences.missing_target) ->
               " — missing " ^ Launch_preferences.chip_label (Some target) ^ "; select chip target"
             | _, Some target -> " — " ^ Launch_preferences.chip_label (Some target)
             | _ -> "")))
      ("quick launch " ^ endpoint ^ " fresh stage new run captured context")
      (Result.ok action |> Option.value ~default:H.Unavailable_launch))
;;

let elaboration_command host ~asic ~remembered =
  let selection = Preparation_view.selection ~remembered ~asic in
  let action =
    Preparation_view.stage
      ~snapshot:host.H.preparation
      ~selection
      ~expected_plan_identity:None
    |> Result.map ~f:(function
      | Preparation.Operation.Stage { selection; _ } ->
        H.Launch_elaboration_bundle selection
      | _ -> assert false)
  in
  H.command
    ?unavailable:(Result.error action)
    "preparation.quick-launch"
    (Artifact_view.safe
       ("Launch elaboration bundle (build and emit; context retained)"
        ^ Option.value_map (Result.ok selection) ~default:"" ~f:(fun s ->
          " — " ^ Launch_preferences.label s)))
    "quick launch elaboration bundle preparation build emit no ASIC allocation"
    (Result.ok action |> Option.value ~default:H.Unavailable_launch)
;;

let validate_elaboration ~asic ~remembered selection =
  Result.bind (Preparation_view.selection ~remembered ~asic) ~f:(fun current ->
    if Asic.Selection.equal current selection
    then Ok ()
    else Error "Elaboration input selection changed; reopen the palette")
;;

let inspected_run host =
  match H.focused host with
  | Some tile -> H.tile_run host tile
  | None -> workspace_run host
;;

type cancellable_flow =
  { operation : Asic.Operation.t
  ; run : Run_ref.t option
  ; target : Asic.Chip_target.t option
  ; label : string
  ; explicit_title : string
  }

let cancellable_flows (snapshot : Asic.Snapshot.t) =
  let workflows =
    List.filter_map snapshot.workflows ~f:(fun w ->
      if Planned_run.workflow_active w && not w.cancel_requested
      then
        Some
          { operation = Cancel_workflow w.id
          ; run = w.run
          ; target = w.intent.selection.chip_target
          ; label = w.intent.selection.flow ^ " · " ^ w.key
          ; explicit_title =
              "Cancel fresh workflow " ^ w.key ^ " (Elaboration: " ^ w.elaboration_status ^ ")"
          }
      else None)
  in
  (* A fresh workflow owns its build, emission, and physical "run:" producer.
     Don't count the latter independently (nor count its observation reader).
     Standalone finalizations have separate keys and independent ownership. *)
  workflows
  @ List.filter_map snapshot.finalizations ~f:(fun f ->
    if f.owned
       && List.exists snapshot.operations ~f:(fun op ->
         String.equal op.kind "finalize"
         && String.equal op.key ("finalize:" ^ f.key)
         && Option.equal Run_ref.equal op.run (Some f.run)
         && Asic_intents.cancellable op)
    then
      let target =
        observed_selection (Some snapshot) f.run |> Option.bind ~f:(fun s -> s.chip_target)
      in
      Some
        { operation = Cancel_finalization { key = f.key; run = f.run }
        ; run = Some f.run
        ; target
        ; label = "Finalization · " ^ f.key
        ; explicit_title = "Cancel finalization " ^ f.key
        }
    else None)
;;

let selected_cancel_chip (snapshot : Asic.Snapshot.t) =
  match snapshot.chip_target with
  | None -> Error "Select a chip target first"
  | Some chip when Launch_preferences.has_target snapshot chip -> Ok chip
  | Some _ -> Error "Chip/variant missing from catalog"
;;

let viewed_flow host ~inspected flows =
  let focused_kind kind =
    Option.exists (H.focused host) ~f:(fun tile -> String.equal tile.kind kind)
  in
  let open Result.Let_syntax in
  let%bind inspected =
    if Option.is_some inspected
       || List.exists [ "run-selector"; "planned-run"; "stage-checklist" ] ~f:focused_kind
    then Ok inspected
    else (
      (* Focus can be on a utility tile. Use a run displayed elsewhere only if
         visible tiles agree; don't guess between independent/pinned runs. *)
      match List.filter_map (H.tiles host) ~f:(H.tile_run host)
            |> List.dedup_and_sort ~compare:Run_ref.compare with
      | [] -> Ok None
      | [ run ] -> Ok (Some run)
      | _ -> Error "Multiple runs in view; focus the intended run")
  in
  let planned_workflow = Planned_run.workflow host.H.planned_run in
  let displayed_workflow =
    if focused_kind "planned-run" || (focused_kind "stage-checklist" && Option.is_none inspected)
    then Option.map planned_workflow ~f:(fun w -> Asic.Operation.Cancel_workflow w.id)
    else None
  in
  let candidates =
    List.filter flows ~f:(fun flow ->
      match displayed_workflow, inspected with
      | Some op, _ -> Asic.Operation.equal op flow.operation
      | None, Some run when not (focused_kind "planned-run") ->
        Option.equal Run_ref.equal flow.run (Some run)
      | _ -> false)
  in
  match candidates with
  | [ flow ] -> Ok flow
  | [] -> Error "No cancellable ASIC flow in view"
  | _ -> Error "Multiple active flows for this run; select an explicit cancellation command"
;;

let cancellation_commands host ~project ~asic ~inspected =
  let flows = Option.value_map asic ~default:[] ~f:cancellable_flows in
  let make ?bulk_chip ?(viewed = false) id title aliases operations =
    let action =
      match project, operations with
      | None, _ -> Error "No open ASIC project"
      | Some _, Error reason -> Error reason
      | Some project, Ok operations ->
        Ok (H.Cancel_asic_flows { project; bulk_chip; viewed; operations })
    in
    match action with
    | Ok action -> H.command id (Artifact_view.safe title) aliases action
    | Error reason ->
      H.command ~unavailable:reason id (Artifact_view.safe title) aliases (H.Unavailable reason)
  in
  let viewed = viewed_flow host ~inspected flows in
  let single =
    make ~viewed:true H.cancel_flow_command_id
      ("Cancel — " ^ Option.value_map (Result.ok viewed) ~default:"flow in view" ~f:(fun flow -> flow.label))
      "stop viewed ASIC flow" (Result.map viewed ~f:(fun flow -> [ flow.operation ]))
  in
  let selected =
    Option.value_map asic ~default:(Error "ASIC snapshot unavailable") ~f:selected_cancel_chip
  in
  let bulk_flows =
    Option.value_map (Result.ok selected) ~default:[] ~f:(fun chip ->
      List.filter flows ~f:(fun flow -> Option.equal Asic.Chip_target.equal (Some chip) flow.target))
  in
  let bulk =
    let title =
      match Launch_preferences.chip_target asic, selected with
      | None, _ -> "Cancel All — no chip selected"
      | Some chip, Error _ -> "Cancel All — " ^ Launch_preferences.chip_label (Some chip)
      | Some chip, Ok _ ->
        let n = List.length bulk_flows in
        sprintf "Cancel All — %s (%d %s)" (Launch_preferences.chip_label (Some chip)) n
          (if n = 1 then "flow" else "flows")
    in
    make ?bulk_chip:(Result.ok selected) H.cancel_all_flows_command_id title "stop all chip flows"
      (Result.bind selected ~f:(fun _ ->
         match bulk_flows with
         | [] -> Error "No active flows for the selected chip"
         | flows -> Ok (List.map flows ~f:(fun flow -> flow.operation))))
  in
  [ single; bulk ]
  @ List.map flows ~f:(fun flow ->
    let id =
      match flow.operation with
      | Cancel_workflow id -> "workflow.cancel." ^ id
      | Cancel_finalization { key; _ } -> "finalization.cancel." ^ key
      | _ -> assert false
    in
    make id flow.explicit_title "stop explicit ASIC workflow or finalization" (Ok [ flow.operation ]))
;;

let commands ?inspected host ~asic ~remembered =
  (let run = Option.value_or_thunk inspected ~default:(fun () -> inspected_run host) in
   match run, Option.bind run ~f:(observed_selection asic)
         |> Option.bind ~f:(fun s -> s.chip_target) with
   | Some run, Some target ->
     [ H.command
         ?unavailable:(if Option.exists asic ~f:(fun s ->
           Launch_preferences.has_target s target) then None
           else Some "This run's chip/variant is missing from the current catalog")
         "asic.use-run-target"
         (Artifact_view.safe ("Use this run's chip/variant as launch target — "
          ^ Launch_preferences.chip_label (Some target)))
         "retarget inspected run evidence"
         (H.Use_run_target (run, target)) ]
   | _ -> [])
  @ selected_commands host ~asic
  @ [ elaboration_command host ~asic ~remembered ]
  @ named_commands host ~asic ~remembered
;;

let chip_commands = H.chip_commands
