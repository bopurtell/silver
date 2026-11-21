open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module W = Workspace
module C = Stage_launch_commands

let fixture () =
  let selection : Asic.Selection.t =
    { chip_target = None
    ; flow = "selected"
    ; profile = "balanced"
    ; endpoint = "synthesis"
    ; assignments = [ "X=1" ]
    }
  in
  let stage id : Asic.Stage.t =
    { id
    ; name = String.capitalize id
    ; status = Completed
    ; requested = true
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let preview : Asic.Preview.t =
    { selection; plan_identity = "captured-plan"; plan_json = "{}" }
  in
  let snapshot =
    { Fs0_fixture.snapshot with
      flows =
        [ { Asic.Flow.id = "selected"
          ; profiles = [ "balanced" ]
          ; default_profile = "balanced"
          ; fresh_stage_endpoints = [ "synthesis"; "routing"; "timing"; "metal-fill" ]
          }
        ; { id = "unselected"
          ; profiles = [ "other" ]
          ; default_profile = "other"
          ; fresh_stage_endpoints = [ "unselected-only" ]
          }
        ]
    ; catalog_default = Some { flow = "selected"; profile = "balanced" }
    ; preview = Some preview
    ; operations =
        [ { Asic.Pending.key =
              List.hd_exn (Plain_rpc.keys (Plan selection) Fs0_fixture.snapshot)
          ; kind = "plan"
          ; state = "completed"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
        ]
    ; runs =
        [ { (Fs0_fixture.run Fs0_fixture.run_a) with
            selection = Some selection
          ; stages = List.map [ "synthesis"; "placement"; "routing"; "signoff" ] ~f:stage
          }
        ]
    }
  in
  let registry = W.initial ~session_id:(W.Session_id.of_string "launch-palette") in
  let overview = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Hardcaml_workbench_workspaces.Definition.apply
               Hardcaml_workbench_workspaces.Overview.definition
               ~workspace:overview.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let registry =
    { registry with
      contexts =
        List.map registry.contexts ~f:(fun context ->
          if W.Context_id.equal context.id overview.context
          then { context with selected_run = Some Fs0_fixture.run_a }
          else context)
    }
  in
  let checklist =
    List.find_exn registry.tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace overview.id
      && String.equal tile.kind "stage-checklist")
  in
  let host =
    { (H.receive H.empty registry) with
      focus = Some checklist.id
    ; quick_launch_view = false
    ; planned_preparation = false
    ; preparation =
        Some { (Preparation_view.fixture_snapshot ()) with latest = None; history = [] }
    ; planned_run = Planned_run.receive Planned_run.empty ~revision:1 snapshot
    }
  in
  let host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with
        cursor = Some "routing"
      ; stage_run = Some Fs0_fixture.run_a
      }
  in
  host, checklist, snapshot, selection
;;

let%test_unit "R takes only the endpoint from historical evidence and stages current inputs" =
  let host, _, snapshot, old = fixture () in
  let old_chip = Some { Asic.Chip_target.chip = "chip"; variant = "old" }
  and chip_target = Some { Asic.Chip_target.chip = "chip"; variant = "new" } in
  let old = { old with chip_target = old_chip } in
  let catalog = { (List.hd_exn snapshot.flows) with
    id = "current"; profiles = ["area"; "delay"]; default_profile = "delay" } in
  let snapshot = { snapshot with chip_target; flows = [catalog];
    catalog_default = Some { flow = "current"; profile = "delay" };
    runs = List.map snapshot.runs ~f:(fun run ->
      { run with selection = Some old; stages = List.map run.stages ~f:(fun s ->
          { s with action = Some { old with endpoint = s.id } }) }) } in
  let action snapshot remembered_selection =
    let commands = C.selected_commands {host with remembered_selection} ~asic:(Some snapshot) in
    List.hd_exn commands
  in
  let fresh = { Asic.Selection.flow = "current"; profile = "delay"; endpoint = "routing";
                         chip_target; assignments = [] } in
  let expect remembered expected =
    match (action snapshot remembered).action with
    | Quick_launch_selected (Physical_stage _, Some _, selection) ->
      assert (Asic.Selection.equal selection expected)
    | _ -> assert false
  in
  expect None fresh;
  expect (Some old) fresh;
  expect (Some {old with chip_target}) fresh;
  let custom = {fresh with profile = "area"; assignments = ["W=12"]} in
  expect (Some {custom with endpoint = "synthesis"}) custom;
  assert (String.is_substring
    (Option.value_exn (action {snapshot with flows = [{catalog with fresh_stage_endpoints = []}]} None).unavailable)
    ~substring:"Unsupported fresh endpoint");
  assert (Option.is_some (action {snapshot with catalog_default = None} None).unavailable)
;;

let full_catalog host snapshot selection =
  (* Include actual settings, aliases, project/tile/workspace actions, and the same launch
     families assembled by main, with competing settings deliberately placed first. *)
  H.contextual
    host
    (H.catalog host ~project:(Some Baseline_fixture.project) ~jobs:[]
     @ [ H.command
           "fixture.settings"
           "Quick launch behavior diagnostics"
           "launch and view settings"
           H.Toggle_chrome
       ; H.command
           "fixture.alias"
           "Inspect syntax report"
           "launch synth metadata"
           H.Toggle_chrome
       ]
     @ C.commands host ~asic:(Some snapshot) ~remembered:(Some selection)
     @ H.launch_commands host ~preview:snapshot.preview ~view_pending:false)
;;

let%test_unit "chip picker, Overview and launch all use the catalog target, never \
               imported evidence"
  =
  let host, _, snapshot, evidence = fixture () in
  let target : Asic.Chip_target.t = { chip = "tiny"; variant = "mac" } in
  let other = { target with variant = "fifo" } in
  let chips : Asic.Chip.t list =
    [ { id = "tiny"
      ; label = "Tiny"
      ; default_variant = "fifo"
      ; variants = [ { id = "fifo"; label = "FIFO" }; { id = "mac"; label = "MAC" } ]
      }
    ]
  in
  let s = { snapshot with chip_target = Some target; chips } in
  let picker = C.chip_commands s in
  assert (List.length picker = 2);
  assert (
    List.exists picker ~f:(fun c ->
      match c.action with
      | Asic (Select_chip chosen) -> Asic.Chip_target.equal chosen other
      | _ -> false));
  let selection =
    C.resolve
      ~asic:(Some s)
      ~remembered:(Some evidence)
      ~run:(Some Fs0_fixture.run_a)
      (Fresh_endpoint "routing")
    |> Result.ok_or_failwith
  in
  assert (Option.equal Asic.Chip_target.equal selection.chip_target (Some target));
  assert (List.is_empty selection.assignments);
  let preview = { (Option.value_exn snapshot.preview) with selection } in
  let completed =
    { (List.hd_exn snapshot.operations) with
      key = List.hd_exn (Plain_rpc.keys (Plan selection) snapshot)
    }
  in
  let ready_snapshot = { s with preview = Some preview; operations = [ completed ] } in
  let retained = Planned_run.receive host.planned_run ~revision:2 ready_snapshot in
  assert (not (Planned_run.launchable retained preview));
  let staging, ticket = Planned_run.begin_plan retained selection in
  let ready = Planned_run.receipt staging ticket ~floor:3 (Ok ()) in
  let ready = Planned_run.receive ready ~revision:3 ready_snapshot in
  assert (Planned_run.launchable ready preview);
  let _, suspended = Planned_run.suspend ready |> Option.value_exn in
  assert (Planned_run.launchable (Planned_run.resume retained suspended) preview);
  let stale =
    Planned_run.receive ready ~revision:4 { ready_snapshot with chip_target = Some other }
  in
  assert (not (Planned_run.launchable stale preview));
  assert (Planned_run.equal_status (Planned_run.model stale).status Stale);
  let intent = { (Fs0_fixture.fresh_intent "captured") with selection } in
  let s = { s with fresh_intent = Some intent } in
  let before =
    { host with
      planned_run = Planned_run.receive host.planned_run ~revision:2 s
    ; remembered_selection = Some selection
    }
  in
  assert (not (Planned_run.fresh_launchable before.planned_run intent));
  let missing = { s with chips = List.map chips ~f:(fun c ->
    { c with variants = List.filter c.variants ~f:(fun v ->
      not (String.equal v.id target.variant)) }) } in
  let disabled =
    C.named_commands before ~asic:(Some missing) ~remembered:(Some selection)
    |> List.find_exn ~f:(fun c -> String.equal c.id "stage.launch-view.synthesis")
  in
  assert (String.is_substring (Option.value_exn disabled.unavailable)
            ~substring:"select a launch target explicitly");
  let inspected = { (List.hd_exn snapshot.runs) with
    selection = Some { selection with chip_target = Some other } } in
  let commands = C.commands before ~asic:(Some { s with runs = [ inspected ] })
                   ~remembered:(Some selection) in
  (match (List.find_exn commands ~f:(fun c -> String.equal c.id "asic.use-run-target")).action with
   | Use_run_target (run, chip) ->
     assert (Run_ref.equal run inspected.run && Asic.Chip_target.equal chip other)
   | _ -> assert false);
  (* Browsing a different run in the selector does not switch the workspace's
     active run. The explicit retarget action must still use that browsed row. *)
  let browsed = { inspected with run = Fs0_fixture.run_b; selection = Some selection } in
  let from_cursor run =
    C.commands before ~inspected:run ~asic:(Some { s with runs = [ inspected; browsed ] })
      ~remembered:(Some selection)
    |> List.find_map ~f:(fun c ->
      match c.action with Use_run_target (run, chip) -> Some (run, chip) | _ -> None)
  in
  assert (Option.is_none (from_cursor None));
  let run, chip = Option.value_exn (from_cursor (Some browsed.run)) in
  assert (Run_ref.equal run browsed.run && Asic.Chip_target.equal chip target);
  let named = List.find_exn commands ~f:(fun c -> String.equal c.id "stage.launch-view.synthesis") in
  assert (String.is_substring named.title ~substring:(Launch_preferences.chip_label (Some target)));
  assert (String.is_substring named.title ~substring:selection.profile);
  (match named.action with
   | Launch_stage_and_view (_, _, s) ->
     assert (Option.equal Asic.Chip_target.equal s.chip_target (Some target))
   | _ -> assert false);
  let registry = Option.value_exn before.registry in
  let tile =
    List.find_exn registry.tiles ~f:(fun t -> String.equal t.kind "planned-run")
  in
  let press h event = H.input h event ~commands:[] in
  let focused = { before with focus = Some tile.id } in
  let keyboard, effect = press focused (Character 't') in
  assert (Poly.equal effect H.No_effect);
  let check_picker h =
    let p = Option.value_exn h.H.palette in
    assert (List.equal String.equal (List.map p.commands ~f:(fun c -> c.id))
              (List.map picker ~f:(fun c -> c.id)));
    assert (Option.equal W.Tile_id.equal h.focus (Some tile.id));
    let searched, _ = press h (Text "fifo") in
    match press searched Enter with
    | closed, Execute (_, Asic (Select_chip selected)) ->
      assert (Option.is_none closed.palette && Asic.Chip_target.equal selected other)
    | _ -> assert false
  in
  check_picker keyboard;
  let _, data, _ = Host_view.refinement_fixture Hardcaml_workbench_workspaces.Overview.definition in
  let click h ~width row =
    Host_view.select_body_row h data tile ~width ~height:10 ~row
  in
  List.iter [ 0; 1 ] ~f:(fun row -> check_picker (click before ~width:64 row));
  List.iter [ 2; 3 ] ~f:(fun row -> assert (Option.is_none (click before ~width:64 row).palette));
  let scrolled = H.set_local before tile.id { (H.local before tile.id) with utility_detail = true; scroll = 2 } in
  check_picker (click scrolled ~width:8 0);
  let changed =
    { keyboard with
      planned_run = Planned_run.receive keyboard.planned_run ~revision:3 { s with chip_target = Some other }
    }
  in
  (match press changed Enter with
   | closed, No_effect -> assert (Option.is_none closed.palette)
   | _ -> assert false);
  assert (Option.is_none (fst (press keyboard Escape)).palette);
  assert (Option.is_none (fst (press { host with focus = Some tile.id } (Character 't'))).palette);
  assert (Option.is_none (click host ~width:64 0).palette);
  assert (Option.is_none (fst (press before (Character 't'))).palette);
  assert (
    List.exists (Host_view.planned_rows before tile ~width:64) ~f:(fun r ->
      String.is_substring r.text ~substring:"t: switch target · click chip/variant"));
  let fields host width =
    Host_view.planned_rows host tile ~width
    |> List.filter_map ~f:(fun r -> Option.some_if (Planned_run.equal_role r.role Fact) r.text)
    |> Fn.flip List.take 5
  in
  assert (
    List.equal String.equal (fields before 64)
      [ "Launch chip: tiny"
      ; "Variant:     mac"
      ; "Flow:        selected"
      ; "Profile:     balanced"
      ; "Endpoint:    routing"
      ]);
  List.iter2_exn (fields before 16) [ "tiny"; "mac"; "selecte"; "balance"; "routing" ]
    ~f:(fun line value ->
      assert (Host_view.cell_width line <= 16);
      assert (String.is_suffix line ~suffix:value));
  assert (not (String.is_prefix (List.hd_exn (fields host 64)) ~prefix:"Launch chip"));
  let capture = H.capture before |> Option.value_exn in
  let form =
    { before with
      palette =
        Some
          { capture
          ; commands = []
          ; query = "timing"
          ; index = 0
          ; argument = Some (H.Plan_endpoint ("selected", "balanced"))
          }
    }
  in
  (match snd (H.input form Enter ~commands:[]) with
   | Execute (_, Asic (Plan typed)) ->
     assert (Option.equal Asic.Chip_target.equal typed.chip_target (Some target))
   | _ -> assert false);
  let after =
    { form with
      planned_run =
        Planned_run.receive
          before.planned_run
          ~revision:3
          { s with chip_target = Some other }
    }
  in
  assert (not (H.current after capture));
  (match snd (H.input after Enter ~commands:[]) with
   | No_effect -> ()
   | _ -> assert false);
  assert (not (Planned_run.fresh_launchable after.planned_run intent));
  let restored =
    { after with planned_run = Planned_run.receive after.planned_run ~revision:4 s }
  in
  assert (not (H.current restored capture));
  (match snd (H.input restored Enter ~commands:[]) with
   | No_effect -> ()
   | _ -> assert false);
  let pending, ticket =
    Planned_run.begin_fresh before.planned_run ~elaboration_only:false selection
  in
  let switched =
    Planned_run.receive
      pending
      ~revision:4
      { s with chip_target = Some other; fresh_intent = None; preview = None }
  in
  let late = Planned_run.fresh_receipt switched ticket ~floor:5 (Ok intent) in
  assert (Option.is_none (Planned_run.fresh_intent late));
  assert (not (Planned_run.current_ticket late ticket));
  let run = List.hd_exn snapshot.runs in
  let stage =
    { (List.hd_exn run.stages) with
      action = Some { selection with chip_target = Some other }
    }
  in
  assert (
    Result.is_error
      (C.resolve
         ~asic:(Some s)
         ~remembered:None
         ~run:(Some run.run)
         (Physical_stage stage)));
  assert (
    Result.is_ok
      (C.resolve
         ~asic:(Some s)
         ~remembered:None
         ~run:(Some run.run)
         (Fresh_endpoint stage.id)));
  List.iter
    (H.launch_commands after ~preview:snapshot.preview ~view_pending:false)
    ~f:(fun c -> assert (Option.is_some c.unavailable))
;;

let open_palette host commands =
  List.fold [ ' '; 'c'; 'c' ] ~init:host ~f:(fun host c ->
    fst (H.input host (Character c) ~commands))
;;

let selected host =
  let palette = Option.value_exn host.H.palette in
  List.nth_exn (H.matches palette) palette.index
;;

let type_query host commands query =
  String.fold query ~init:host ~f:(fun host c ->
    let next, _ = H.input host (Character c) ~commands in
    let palette = Option.value_exn next.palette in
    assert (palette.index = 0);
    next)
;;

let%test_unit "WB-076 exact launch aliases dispatch by identity against stronger fuzzy matches" =
  let host, _, snapshot, historical = fixture () in
  let selection = { historical with endpoint = "cts"; assignments = [ "X=2" ] } in
  let preview = { (Option.value_exn snapshot.preview) with selection } in
  let snapshot =
    { snapshot with
      preview = Some preview
    ; operations =
        List.map snapshot.operations ~f:(fun op ->
          { op with key = List.hd_exn (Plain_rpc.keys (Plan selection) snapshot) })
    ; runs =
        List.map snapshot.runs ~f:(fun run ->
          { run with
            stages =
              List.map run.stages ~f:(fun stage ->
                if String.equal stage.id "synthesis"
                then { stage with action = Some historical }
                else stage)
          })
    }
  in
  let staging, ticket = Planned_run.begin_plan host.planned_run selection in
  let ready = Planned_run.receipt staging ticket ~floor:2 (Ok ()) in
  let host = { host with planned_run = Planned_run.receive ready ~revision:2 snapshot } in
  assert (Planned_run.launchable host.planned_run preview);
  let competitors =
    List.map [ "a launch"; "synth" ] ~f:(fun query ->
      H.command ("fixture.competing." ^ query) query "" Toggle_chrome)
  in
  let catalog = competitors @ full_catalog host snapshot selection in
  let dispatch ?(competing = true) ~host ~catalog query =
    let typed = type_query (open_palette host catalog) catalog query in
    let palette = Option.value_exn typed.palette in
    if competing
    then (
      (* Check that this fixture actually exercises an ordering conflict rather than
         relying on an incidental fuzzy order that would pass without the pin. *)
      let fuzzy =
        Palette_search.rank ~query
          (List.map palette.commands ~f:(fun c ->
             ( c
             , [ { Palette_search.text = c.title; weight = 100 }
               ; { text = c.aliases; weight = 85 }
               ; { text = c.id; weight = 75 }
               ] )))
      in
      assert (String.equal (List.hd_exn fuzzy).item.id ("fixture.competing." ^ query)));
    H.input typed Enter ~commands:catalog
  in
  (match dispatch ~host ~catalog "a launch" with
   | closed, Execute (_, Launch_asic (actual, _)) ->
     assert (Option.is_none closed.palette);
     assert (Asic.Preview.equal actual preview)
   | _ -> failwith "a launch did not dispatch the exact CTS preview");
  (match dispatch ~host ~catalog "synth" with
   | closed, Execute (_, Launch_stage_and_view (Fresh_endpoint "synthesis", _, actual)) ->
     assert (Option.is_none closed.palette);
     assert (Asic.Selection.equal actual { selection with endpoint = "synthesis" })
   | _ -> failwith "synth did not dispatch fresh synthesis in view");
  (match dispatch ~competing:false ~host ~catalog "synth rows" with
   | closed, Execute (_, Discover_asic) -> assert (Option.is_none closed.palette)
   | _ -> failwith "synth rows did not dispatch discovery");
  let unstaged = { host with planned_run = Planned_run.empty } in
  let catalog =
    competitors @ full_catalog unstaged { snapshot with preview = None } selection
  in
  match dispatch ~host:unstaged ~catalog "a launch" with
  | rejected, No_effect ->
    assert (String.is_substring rejected.notice ~substring:"No staged plan")
  | _ -> failwith "a launch dispatched another command in the absence of a staged plan"
;;

let%test_unit "reserved aliases block when missing only in the global palette" =
  let host, _, snapshot, _ = fixture () in
  let cases =
    [ "synth", "stage.launch-view.synthesis"
    ; "a launch", "asic.launch"
    ; "cts", "stage.launch-view.cts"
    ; "elaboration", "preparation.quick-launch"
    ; "chip", "asic.pick-chip"
    ]
  in
  let chips =
    List.map (List.map cases ~f:fst) ~f:(fun name ->
      { Asic.Chip.id = name
      ; label = name
      ; default_variant = "default"
      ; variants = [ { id = "default"; label = "Default" } ]
      })
  in
  let host =
    { host with
      planned_run = Planned_run.receive host.planned_run ~revision:2 { snapshot with chips }
    }
  in
  List.iter cases ~f:(fun (query, launch_id) ->
    let commands = [ H.command "fixture.competing" query "" Toggle_chrome ] in
    let global = type_query (open_palette host commands) commands query in
    let fallback = selected global in
    assert (String.equal fallback.id launch_id);
    let blocked, effect = H.input global Enter ~commands in
    (match effect with
     | No_effect -> assert (String.equal blocked.notice (Option.value_exn fallback.unavailable))
     | _ -> failwith "global exact alias fell through to a competing command");
    let picker = type_query (H.open_chip_picker host) commands query in
    (match snd (H.input picker Enter ~commands) with
    | Execute (_, Asic (Select_chip target)) ->
       assert (String.equal target.chip query && String.equal target.variant "default")
     | _ -> failwith "global alias shadowed a chip in the scoped picker"))
;;

let%test_unit "bare stage names dispatch the captured launch behind stronger fuzzy matches" =
  let host, _, snapshot, selection = fixture () in
  let physical =
    [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "timing"; "signoff" ]
  in
  let flow = List.hd_exn snapshot.flows in
  let snapshot =
    { snapshot with
      flows =
        { flow with fresh_stage_endpoints = physical @ [ "metal-fill"; "chip"; "elaboration" ] }
        :: List.tl_exn snapshot.flows
    }
  in
  let dispatch ?(extra = []) snapshot query =
    let competing =
      H.command "fixture.competing.stage" (String.strip query) "" Toggle_chrome
    in
    let catalog = competing :: (full_catalog host snapshot selection @ extra) in
    let typed = type_query (open_palette host catalog) catalog query in
    let command = selected typed in
    let next, effect = H.input typed Enter ~commands:catalog in
    command, next, effect
  in
  List.iter
    (List.map (physical @ [ "metal-fill" ]) ~f:(fun id -> id, id) @ [ " CtS ", "cts" ])
    ~f:(fun (query, endpoint) ->
      let command, closed, effect = dispatch snapshot query in
      assert (String.equal command.id ("stage.launch-view." ^ endpoint));
      assert (Option.is_none closed.palette);
      match effect with
      | Execute (_, Launch_stage_and_view (Fresh_endpoint actual, _, resolved)) ->
        assert (String.equal actual endpoint);
        assert (Asic.Selection.equal resolved { selection with endpoint })
      | _ -> failwithf "%S did not dispatch fresh %s in view" query endpoint ());
  let command, closed, effect = dispatch snapshot "elaboration" in
  assert (String.equal command.id "preparation.quick-launch");
  assert (Option.is_none closed.palette);
  (match effect with
   | Execute (_, Launch_elaboration_bundle resolved) ->
     assert (Asic.Selection.equal resolved selection)
   | _ -> failwith "elaboration did not dispatch the preparation bundle action");
  let picker = H.command "asic.pick-chip" "Select Launch Target…" "" Pick_chip_target in
  let command, closed, effect = dispatch ~extra:[ picker ] snapshot "chip" in
  assert (String.equal command.id "asic.pick-chip");
  assert (Option.is_none closed.palette);
  (match effect with
   | Execute (_, Pick_chip_target) -> ()
   | _ -> failwith "chip did not dispatch the target picker");
  let unavailable =
    { snapshot with
      flows = [ { flow with fresh_stage_endpoints = [ "synthesis" ] } ]
    }
  in
  let command, rejected, effect = dispatch unavailable "cts" in
  assert (String.equal command.id "stage.launch-view.cts");
  assert (Option.is_some rejected.palette);
  (match effect with
   | No_effect ->
     assert (String.is_substring rejected.notice ~substring:"Unsupported fresh endpoint")
   | _ -> failwith "unavailable CTS dispatched a competing command");
  let command, _, effect = dispatch snapshot "unselected-only" in
  assert (String.equal command.id "fixture.competing.stage");
  match effect with
  | Execute (_, Toggle_chrome) -> ()
  | _ -> failwith "an endpoint from an unselected flow displaced the fuzzy match"
;;

let%test_unit "saved workspace with no Overview tiles can search and select a chip" =
  let host, _, snapshot, selection = fixture () in
  let registry = Option.value_exn host.registry in
  let registry = { registry with tiles = [] } in
  let host = { (H.receive host registry) with focus = None } in
  let chip : Asic.Chip.t =
    { id = "budget"
    ; label = "Budget"
    ; default_variant = "two_slot"
    ; variants =
        [ { id = "two_slot"; label = "Two SRAM" }
        ; { id = "three_slot"; label = "Three SRAM" }
        ]
    }
  in
  let snapshot = { snapshot with chips = [ chip ] } in
  let catalog =
    H.contextual host (full_catalog host snapshot selection @ C.chip_commands snapshot)
  in
  let typed = type_query (open_palette host catalog) catalog "three_slot" in
  match snd (H.input typed Enter ~commands:catalog) with
  | Execute (_, Asic (Select_chip t)) ->
    assert (String.equal t.chip "budget" && String.equal t.variant "three_slot")
  | _ -> assert false
;;

let%test_unit "incremental action-first launch queries rank actual catalog ahead of \
               settings and aliases"
  =
  let host, _, snapshot, selection = fixture () in
  let catalog = full_catalog host snapshot selection in
  List.iter
    [ "launch and vi", "asic.launch-view"
    ; "quick lau", "stage.quick-selected"
    ; "quick launch", "stage.quick-selected"
    ; "launch syn", "stage.launch-view.synthesis"
    ; "launch elab", "preparation.quick-launch"
    ; "quick launch synthesis", "stage.launch-view.synthesis"
    ; "quick launch elaboration", "preparation.quick-launch"
    ]
    ~f:(fun (query, expected) ->
      let typed = type_query (open_palette host catalog) catalog query in
      let actual = (selected typed).id in
      if not (String.equal actual expected)
      then failwithf "query %S selected %S rather than %S" query actual expected ());
  let typed =
    type_query (open_palette host catalog) catalog "quick-launch behavior keep"
  in
  assert (String.equal (selected typed).id "launch.quick.no-view");
  List.iter catalog ~f:(fun command ->
    match command.H.action with
    | Set_quick_launch_view _ ->
      assert (not (String.is_substring command.title ~substring:"R "))
    | _ -> ())
;;

let%test_unit "manual arrows and Enter retain explicit choice; editing and backspace \
               follow new top rank"
  =
  let host, _, snapshot, selection = fixture () in
  let catalog = full_catalog host snapshot selection in
  let typed = type_query (open_palette host catalog) catalog "launch and vi" in
  let moved, _ = H.input typed Next ~commands:catalog in
  assert (not (String.equal (selected typed).id (selected moved).id));
  let chosen = selected moved in
  let unchanged =
    { moved with
      palette = Option.map moved.palette ~f:(fun p -> H.palette_query p p.query)
    }
  in
  assert (String.equal (selected unchanged).id chosen.id);
  let _, effect = H.input unchanged Enter ~commands:catalog in
  (match chosen.unavailable, effect with
   | None, Execute (_, _) -> ()
   | Some reason, No_effect ->
     let next, _ = H.input unchanged Enter ~commands:catalog in
     assert (String.equal next.notice reason)
   | _ -> assert false);
  let edited, _ = H.input moved (Character 'e') ~commands:catalog in
  assert ((Option.value_exn edited.palette).index = 0);
  assert (String.equal (selected edited).id "asic.launch-view");
  let back, _ = H.input edited Backspace ~commands:catalog in
  assert ((Option.value_exn back.palette).index = 0);
  assert (String.equal (selected back).id "asic.launch-view")
;;

let%test_unit "selected shortcut captures checklist from another tile and rejects \
               ambiguous or changed selections"
  =
  let host, checklist, snapshot, selection = fixture () in
  let asic = Some snapshot in
  let other =
    List.find_exn (Option.value_exn host.registry).tiles ~f:(fun tile ->
      W.Workspace_id.equal tile.workspace checklist.workspace
      && not (String.equal tile.kind "stage-checklist"))
  in
  let unfocused = { host with focus = Some other.id } in
  let shortcut = List.hd_exn (C.selected_commands unfocused ~asic) in
  assert (Option.is_none shortcut.unavailable);
  (match shortcut.action with
   | Quick_launch_selected (item, run, inputs) ->
     assert (String.equal (Overview_tiles.checklist_id item) "routing");
     assert (Option.equal Run_ref.equal run (Some Fs0_fixture.run_a));
     assert (List.is_empty inputs.assignments);
     assert (Result.is_ok (C.validate_selected unfocused ~asic ~item ~run));
     let changed =
       H.set_local
         unfocused
         checklist.id
         { (H.local host checklist.id) with cursor = Some "synthesis" }
     in
     assert (Result.is_error (C.validate_selected changed ~asic ~item ~run))
   | _ -> assert false);
  let registry = Option.value_exn host.registry in
  let second = { checklist with id = W.Tile_id.of_string "second-checklist" } in
  let ambiguous =
    H.receive unfocused { registry with tiles = registry.tiles @ [ second ] }
  in
  let disabled = List.hd_exn (C.selected_commands ambiguous ~asic) in
  assert (
    String.is_substring
      (Option.value_exn disabled.unavailable)
      ~substring:"Multiple checklist");
  let focused = { ambiguous with focus = Some checklist.id } in
  assert (Option.is_none (List.hd_exn (C.selected_commands focused ~asic)).unavailable);
  let absent =
    H.receive
      unfocused
      { registry with
        tiles =
          List.filter registry.tiles ~f:(fun t ->
            not (String.equal t.kind "stage-checklist"))
      }
  in
  assert (
    String.is_substring
      (Option.value_exn (List.hd_exn (C.selected_commands absent ~asic)).unavailable)
      ~substring:"No stage checklist");
  let catalog = full_catalog absent snapshot selection in
  let disabled_query = type_query (open_palette absent catalog) catalog "quick lau" in
  assert (String.equal (selected disabled_query).id "stage.quick-selected");
  let rejected, effect = H.input disabled_query Enter ~commands:catalog in
  assert (String.is_substring rejected.notice ~substring:"No stage checklist");
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  let no_run =
    H.receive
      host
      { registry with
        contexts = List.map registry.contexts ~f:(fun c -> { c with selected_run = None })
      }
  in
  match (List.hd_exn (C.selected_commands no_run ~asic)).action with
  | Quick_launch_selected (Catalog_endpoint "synthesis", None, s) ->
    assert (String.equal s.endpoint "synthesis")
  | _ -> assert false
;;

let%test_unit "named shortcuts capture fresh inputs, force view independently of \
               preference, and reject capability drift"
  =
  let host, _, snapshot, selection = fixture () in
  let named = C.named_commands host ~asic:(Some snapshot) ~remembered:(Some selection) in
  let find endpoint =
    List.find_exn named ~f:(fun c ->
      String.equal c.H.id ("stage.launch-view." ^ endpoint))
  in
  assert (Option.is_some (find "placement").unavailable);
  assert (Option.is_none (find "timing").unavailable);
  assert (Option.is_none (find "metal-fill").unavailable);
  assert (
    not
      (List.exists named ~f:(fun c ->
         String.is_substring c.H.id ~substring:"unselected-only")));
  assert (not host.quick_launch_view);
  (match (find "synthesis").action with
   | Launch_stage_and_view (intent, run, captured) ->
     assert (Asic.Selection.equal captured selection);
     assert (
       Result.is_ok
         (C.validate_named
            ~asic:(Some snapshot)
            ~remembered:(Some selection)
            ~run
            ~intent
            ~selection:captured));
     let stale = { snapshot with flows = [] } in
     assert (
       Result.is_error
         (C.validate_named
            ~asic:(Some stale)
            ~remembered:(Some selection)
            ~run
            ~intent
            ~selection:captured));
     assert (
       Result.is_error
         (C.validate_named
            ~asic:(Some snapshot)
            ~remembered:(Some { selection with assignments = [ "X=changed" ] })
            ~run
            ~intent
            ~selection:captured))
   | _ -> assert false);
  let execution = List.hd_exn snapshot.runs in
  let stage = { (List.hd_exn execution.stages) with action = Some selection } in
  let advertised =
    { snapshot with flows = []; runs = [ { execution with stages = [ stage ] } ] }
  in
  let command =
    List.find_exn
      (C.named_commands host ~asic:(Some advertised) ~remembered:(Some selection))
      ~f:(fun c -> String.equal c.H.id "stage.launch-view.synthesis")
  in
  assert (Option.is_none command.unavailable);
  match command.action with
  | Launch_stage_and_view (intent, run, captured) ->
    assert (
      Result.is_ok
        (C.validate_named
           ~asic:(Some advertised)
           ~remembered:(Some selection)
           ~run
           ~intent
           ~selection:captured));
    assert (
      Result.is_error
        (C.validate_named
           ~asic:(Some { advertised with runs = [] })
           ~remembered:(Some selection)
           ~run
           ~intent
           ~selection:captured))
  | _ -> assert false
;;

let%test_unit "named fresh launch can fill an empty context; elaboration captures inputs \
               and never claims ASIC allocation"
  =
  let host, _, snapshot, selection = fixture () in
  let registry = Option.value_exn host.registry in
  let empty_context =
    H.receive
      host
      { registry with
        contexts = List.map registry.contexts ~f:(fun c -> { c with selected_run = None })
      }
  in
  let synthesis =
    List.find_exn
      (C.named_commands empty_context ~asic:(Some snapshot) ~remembered:(Some selection))
      ~f:(fun c -> String.equal c.H.id "stage.launch-view.synthesis")
  in
  assert (Option.is_none synthesis.unavailable);
  (match synthesis.action with
   | Launch_stage_and_view (_, None, captured) ->
     assert (Asic.Selection.equal captured selection)
   | _ -> assert false);
  let prep =
    C.elaboration_command host ~asic:(Some snapshot) ~remembered:(Some selection)
  in
  assert (Option.is_none prep.unavailable);
  assert (String.is_substring prep.title ~substring:"context retained");
  (match prep.action with
   | Launch_elaboration_bundle captured ->
     assert (Asic.Selection.equal captured selection);
     assert (
       Result.is_ok
         (C.validate_elaboration
            ~asic:(Some snapshot)
            ~remembered:(Some selection)
            captured));
     assert (
       Result.is_error
         (C.validate_elaboration
            ~asic:(Some snapshot)
            ~remembered:(Some { selection with profile = "changed" })
            captured))
   | _ -> assert false);
  let unavailable =
    C.elaboration_command
      { host with preparation = None }
      ~asic:(Some snapshot)
      ~remembered:(Some selection)
  in
  assert (
    String.is_substring
      (Option.value_exn unavailable.unavailable)
      ~substring:"capability unavailable")
;;

let%test_unit "launch-and-view prefix follows the captured staged preparation rather \
               than a physical or settings action"
  =
  let host, _, snapshot, selection = fixture () in
  let staged : Preparation.Staged.t =
    { id = "captured-preparation"
    ; selection
    ; expected_plan_identity = None
    ; source_root = "/captured/source"
    ; build_target = "publisher.exe"
    ; source_executable = "/captured/source/_build/default/publisher.exe"
    ; results_root = "/captured/results"
    ; timeout_seconds = 30
    ; environment = Inherit_daemon
    ; created_at = Timestamp.of_time_ns Time_ns.epoch
    }
  in
  let host =
    { host with
      planned_preparation = true
    ; preparation = Some { (Option.value_exn host.preparation) with staged = Some staged }
    }
  in
  let catalog = full_catalog host snapshot selection in
  let typed = type_query (open_palette host catalog) catalog "launch and vi" in
  let chosen = selected typed in
  assert (String.equal chosen.id "asic.launch-view");
  assert (String.is_prefix chosen.title ~prefix:"Launch and view planned PREPARATION");
  (match chosen.action with
   | Launch_preparation id -> assert (String.equal id staged.id)
   | _ -> assert false);
  let registry = Option.value_exn host.registry in
  let stale =
    H.receive
      typed
      { registry with
        revision = registry.revision + 1
      ; contexts =
          List.map registry.contexts ~f:(fun c ->
            { c with selection_revision = c.selection_revision + 1 })
      }
  in
  let _, effect = H.input stale Enter ~commands:catalog in
  match effect with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "live selected launch guards reject tile-local drift and same-row \
               capability withdrawal after resolution"
  =
  let host, checklist, snapshot, selection = fixture () in
  let item, run =
    C.selected_checklist host ~asic:(Some snapshot) |> Result.ok_or_failwith
  in
  let stage =
    match item with
    | Overview_tiles.Physical_stage stage -> stage
    | _ -> assert false
  in
  let intent = Stage_action.Physical_stage stage in
  let resolved =
    C.resolve ~asic:(Some snapshot) ~remembered:(Some selection) ~run intent
    |> Result.ok_or_failwith
  in
  let captured = H.capture host |> Option.value_exn in
  let current_host = ref host
  and current_snapshot = ref snapshot in
  (* A long-running action reads live state at each boundary, rather than validating just
     when the palette action is converted to a preparation action. *)
  let validate () =
    Result.bind
      (C.validate_selected !current_host ~asic:(Some !current_snapshot) ~item ~run)
      ~f:(fun () ->
        C.validate_named
          ~asic:(Some !current_snapshot)
          ~remembered:(Some selection)
          ~run
          ~intent
          ~selection:resolved)
  in
  assert (Result.is_ok (validate ()));
  current_host
  := H.set_local
       host
       checklist.id
       { (H.local host checklist.id) with cursor = Some "synthesis" };
  assert (H.current !current_host captured);
  assert (Result.is_error (validate ()));
  current_host := host;
  current_snapshot
  := { snapshot with
       flows =
         List.map snapshot.flows ~f:(fun flow ->
           { flow with
             fresh_stage_endpoints =
               List.filter flow.fresh_stage_endpoints ~f:(Fn.non (String.equal "routing"))
           })
     };
  assert (H.current !current_host captured);
  assert (
    Result.is_ok
      (C.validate_selected !current_host ~asic:(Some !current_snapshot) ~item ~run));
  assert (Result.is_error (validate ()));
  let advertised = { stage with action = Some resolved } in
  let execution = List.hd_exn snapshot.runs in
  let action_snapshot =
    { snapshot with flows = []; runs = [ { execution with stages = [ advertised ] } ] }
  in
  let action_host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with cursor = Some stage.id }
  in
  assert (
    Result.is_ok
      (C.validate_selected
         action_host
         ~asic:(Some action_snapshot)
         ~item:(Physical_stage advertised)
         ~run));
  assert (
    Result.is_ok
      (C.validate_named
         ~asic:(Some action_snapshot)
         ~remembered:(Some selection)
         ~run
         ~intent:(Physical_stage advertised)
         ~selection:resolved));
  let withdrawn =
    { action_snapshot with
      runs = [ { execution with stages = [ { advertised with action = None } ] } ]
    }
  in
  assert (H.current action_host captured);
  assert (
    Result.is_error
      (C.validate_selected
         action_host
         ~asic:(Some withdrawn)
         ~item:(Physical_stage advertised)
         ~run));
  assert (
    Result.is_error
      (C.validate_named
         ~asic:(Some withdrawn)
         ~remembered:(Some selection)
         ~run
         ~intent:(Physical_stage advertised)
         ~selection:resolved));
  let preparation = Overview_tiles.Elaboration_preparation in
  let prep_host =
    H.set_local
      host
      checklist.id
      { (H.local host checklist.id) with
        cursor = Some (Overview_tiles.checklist_id preparation)
      }
  in
  assert (
    Result.is_ok
      (C.validate_selected prep_host ~asic:(Some snapshot) ~item:preparation ~run));
  assert (H.current host captured);
  assert (
    Result.is_error
      (C.validate_selected host ~asic:(Some snapshot) ~item:preparation ~run))
;;
