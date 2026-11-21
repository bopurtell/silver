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

let named_commands host ~asic ~remembered =
  let run = workspace_run host in
  let stages =
    Option.value_map run ~default:[] ~f:(fun run -> O.observed_stages ~asic ~run)
  in
  let endpoints =
    let chosen =
      Option.first_some
        (Launch_preferences.for_target asic remembered)
        (if Option.is_some (Launch_preferences.chip_target asic)
         then None
         else Option.bind run ~f:(observed_selection asic))
      |> Option.map ~f:(fun s -> s.Asic.Selection.flow)
    in
    let flow =
      Option.first_some
        chosen
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
    @ [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
    |> List.stable_dedup ~compare:String.compare
  in
  List.map names ~f:(fun endpoint ->
    let intent =
      match
        List.find stages ~f:(fun s ->
          String.equal s.id endpoint && Option.is_some s.action)
      with
      | Some stage when Option.is_none (Launch_preferences.chip_target asic) ->
        Stage_action.Physical_stage stage
      | _ -> Fresh_endpoint endpoint
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
      ("stage.launch-view." ^ endpoint)
      (Artifact_view.safe
         ("Launch "
          ^ endpoint
          ^ " and view"
          ^ (match action, Launch_preferences.chip_target asic with
             | Ok (H.Launch_stage_and_view (_, _, selection)), Some _ ->
               " — " ^ Launch_preferences.chip_label selection.chip_target
               ^ " · " ^ selection.flow ^ " / " ^ selection.profile
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
  @ Option.value_map asic ~default:[] ~f:(fun snapshot ->
    List.filter_map snapshot.Asic.Snapshot.workflows ~f:(fun w ->
      if Planned_run.workflow_active w
      then
        Some
          (H.command
             ("workflow.cancel." ^ w.id)
             ("Cancel fresh workflow "
              ^ w.key
              ^ " (Elaboration: "
              ^ w.elaboration_status
              ^ ")")
             "stop build emit physical workflow"
             (H.Asic (Cancel_workflow w.id)))
      else None))
;;

let chip_commands = H.chip_commands
