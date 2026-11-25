open! Core
open Silver_protocol
open Terminal_presentation
module H = Workspace_host

let () =
  let flows, catalog_default =
    Silver_backend.Asic_public.flow_catalog
      (Yojson.Safe.from_file (Sys.get_argv ()).(1))
  in
  let snapshot = { Asic_snapshot_fixture.snapshot with flows; catalog_default } in
  let query ?remembered ?(snapshot = snapshot) flow profile =
    Launch_preferences.endpoint_query ~remembered ~asic:(Some snapshot) ~flow ~profile
  in
  let selection : Asic.Selection.t =
    { chip_target = None
    ; flow = "standard"
    ; profile = "balanced"
    ; endpoint = "synthesis"
    ; assignments = []
    }
  in
  assert (String.equal (query "standard" "balanced") "synthesis");
  assert (
    Asic.Selection.equal
      (Result.ok_or_failwith
         (Preparation_view.selection ~remembered:None ~asic:(Some snapshot)))
      selection);
  let remembered = { selection with endpoint = "routing"; assignments = [ "WIDTH=8" ] } in
  assert (String.equal (query ~remembered "standard" "balanced") "routing WIDTH=8");
  assert (String.equal (query ~remembered "standard" "synth_delay") "synthesis");
  assert (String.is_empty (query "missing" "balanced"));
  assert (String.is_empty (query "standard" "missing"));
  assert (
    String.is_empty
      (Launch_preferences.endpoint_query
         ~remembered:None
         ~asic:None
         ~flow:"standard"
         ~profile:"balanced"));
  List.iter [ []; [ "routing" ] ] ~f:(fun endpoints ->
    let snapshot =
      { snapshot with
        flows =
          List.map flows ~f:(fun flow -> { flow with fresh_stage_endpoints = endpoints })
      }
    in
    assert (
      String.equal
        (query ~snapshot "standard" "balanced")
        (Option.value (List.hd endpoints) ~default:"")));
  let host, _, find =
    Host_view.refinement_fixture Silver_workspaces.Overview.definition
  in
  let capture = H.capture host |> Option.value_exn in
  let enter argument query =
    H.input
      { host with
        palette =
          Some { capture; commands = []; query; index = 0; viewport = `Follow 0; argument = Some argument }
      }
      Enter
      ~commands:[]
  in
  let arguments =
    [ H.Plan_endpoint ("standard", "balanced")
    ; H.Preparation_inputs ("standard", "balanced")
    ]
  in
  let corpus =
    [ ""
    ; "SYNTH_STRATEGY=DELAY 1"
    ; "SYNTH_ABC_BUFFERING=false"
    ; " leading and trailing "
    ; "QUOTE=one'and\"two"
    ; "PATH=C:\\literal\\path"
    ; "LITERAL=$(touch /never);`command`|*&~$HOME"
    ; "UNICODE=界"
    ]
  in
  List.iter corpus ~f:(fun first ->
    List.iter corpus ~f:(fun second ->
      let remembered = { selection with assignments = [ first; second; first ] } in
      let encoded = query ~remembered "standard" "balanced" in
      assert (
        List.equal
          String.equal
          (Or_error.ok_exn (Launch_preferences.Prompt.decode encoded))
          (remembered.endpoint :: remembered.assignments));
      List.iter arguments ~f:(fun argument ->
        match snd (enter argument encoded) with
        | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
          assert (Asic.Selection.equal actual remembered)
        | _ -> assert false)));
  for code = 32 to 126 do
    let literal = String.of_char (Char.of_int_exn code) in
    let tokens = [ ""; literal; literal ^ "\\\"' end" ] in
    assert (
      List.equal
        String.equal
        tokens
        (Launch_preferences.Prompt.encode tokens
         |> Launch_preferences.Prompt.decode
         |> Or_error.ok_exn))
  done;
  List.iter
    [ "synthesis SYNTH_STRATEGY='DELAY 1'", [ "SYNTH_STRATEGY=DELAY 1" ]
    ; "synthesis SYNTH_STRATEGY=\"DELAY 1\"", [ "SYNTH_STRATEGY=DELAY 1" ]
    ; "  synthesis  A=1 A=2  ", [ "A=1"; "A=2" ]
    ; "synthesis PATH=C:\\literal\\path", [ "PATH=C:\\literal\\path" ]
    ; "synthesis LITERAL=$HOME;$(whoami)", [ "LITERAL=$HOME;$(whoami)" ]
    ; "synthesis '' \"\" a''b\"\"", [ ""; ""; "ab" ]
    ; "synthesis 'a b'\"c d\"e", [ "a bc de" ]
    ; "synthesis a\\ b", [ "a\\"; "b" ]
    ; "synthesis \"a\\\"b\\\\c\"", [ "a\"b\\c" ]
    ]
    ~f:(fun (text, assignments) ->
      let actual =
        Launch_preferences.Prompt.selection
          text
          ~flow:selection.flow
          ~profile:selection.profile
        |> Or_error.ok_exn
      in
      assert (Asic.Selection.equal actual { selection with assignments }));
  List.iter
    [ "synthesis 'unclosed", "Unclosed quote"
    ; "synthesis \"unclosed", "Unclosed quote"
    ; "synthesis \"bad\\q\"", "only quote and backslash"
    ; "synthesis A=1\nB=2", "one line"
    ; "synthesis A=1\rB=2", "one line"
    ; "synthesis A=1\tB=2", "one line"
    ; "synthesis A=\000", "control characters"
    ; "synthesis A=\127", "control characters"
    ; "\"\" A=1", "nonempty endpoint"
    ]
    ~f:(fun (text, diagnostic) ->
      List.iter arguments ~f:(fun argument ->
        let rejected, effect = enter argument text in
        assert (
          match effect with
          | No_effect -> true
          | _ -> false);
        assert (String.is_substring rejected.notice ~substring:diagnostic);
        assert (
          Host_view.render_palette
            rejected
            { width = 200; height = 60 }
            (Bonsai_term.View.text "")
          |> Host_view.plain_text
          |> String.is_substring ~substring:"Invalid typed input:");
        assert (
          Option.value_map rejected.palette ~default:false ~f:(fun p ->
            String.equal p.query text))));
  List.iter
    [ H.Plan_endpoint ("standard", "balanced")
    ; H.Preparation_inputs ("standard", "balanced")
    ]
    ~f:(fun argument ->
      let host =
        { host with
          palette =
            Some
              { capture
              ; commands = []
              ; query = query "standard" "balanced"
              ; index = 0
              ; viewport = `Follow 0
              ; argument = Some argument
              }
        }
      in
      let text =
        Host_view.render_palette
          host
          { width = 120; height = 40 }
          (Bonsai_term.View.text "")
        |> Host_view.plain_text
      in
      assert (String.is_substring text ~substring:"synthesis");
      match snd (H.input host Enter ~commands:[]) with
      | Execute (_, (Asic (Plan actual) | Select_preparation actual)) ->
        assert (Asic.Selection.equal actual selection)
      | _ -> assert false);
  let diagnostic = "source input unavailable: exact-diagnostic-123" in
  List.iter [ false; true ] ~f:(fun fresh ->
    let planned_run, ticket =
      if fresh
      then Planned_run.begin_fresh host.planned_run ~elaboration_only:false selection
      else Planned_run.begin_plan host.planned_run selection
    in
    let planned_run =
      if fresh
      then Planned_run.fresh_receipt planned_run ticket ~floor:1 (Error diagnostic)
      else Planned_run.receipt planned_run ticket ~floor:1 (Error diagnostic)
    in
    List.iter [ false; true ] ~f:(fun detail ->
      let tile = find "planned-run" in
      let host =
        { host with planned_run; planned_preparation = false; stage_preparation = None }
      in
      let local = H.local host tile.id in
      let host = H.set_local host tile.id { local with utility_detail = detail } in
      let rows = Host_view.planned_source_rows host tile in
      assert (
        List.exists rows ~f:(fun row ->
          Planned_run.equal_role row.role Error
          && String.is_substring row.text ~substring:diagnostic))));
  print_endline "catalog endpoint prompts and plan diagnostics: ok"
;;

let () =
  let flow id fresh_stage_endpoints : Asic.Flow.t =
    { id; profiles = [ "one"; "two" ]; default_profile = "one"; fresh_stage_endpoints }
  in
  let remembered : Asic.Selection.t =
    { flow = "chosen"
    ; profile = "one"
    ; endpoint = "routing"
    ; chip_target = None
    ; assignments = [ "Z=last"; "A=contains spaces"; "Z=again" ]
    }
  in
  let endpoints =
    [ "signoff"; "timing"; "routing"; "cts"; "placement"; "floorplan"; "synthesis" ]
  in
  for mask = 0 to (1 lsl List.length endpoints) - 1 do
    let chosen = List.filteri endpoints ~f:(fun i _ -> mask land (1 lsl i) <> 0) in
    List.iter
      [ chosen; List.rev chosen ]
      ~f:(fun chosen ->
        let expected =
          if List.mem chosen "synthesis" ~equal:String.equal
          then Some "synthesis"
          else List.hd chosen
        in
        let snapshot =
          { Asic_snapshot_fixture.snapshot with
            flows = [ flow "decoy" [ "synthesis" ]; flow "chosen" chosen ]
          ; catalog_default = Some { flow = "chosen"; profile = "one" }
          }
        in
        let query ?remembered flow profile =
          Launch_preferences.endpoint_query
            ~remembered
            ~asic:(Some snapshot)
            ~flow
            ~profile
        in
        assert (String.equal (query "chosen" "one") (Option.value expected ~default:""));
        assert (
          String.equal
            (query ~remembered "chosen" "two")
            (Option.value expected ~default:""));
        assert (String.equal (query ~remembered "decoy" "one") "synthesis");
        assert (
          List.equal
            String.equal
            (Launch_preferences.Prompt.decode (query ~remembered "chosen" "one")
             |> Or_error.ok_exn)
            (remembered.endpoint :: remembered.assignments));
        match
          Preparation_view.selection ~remembered:None ~asic:(Some snapshot), expected
        with
        | Error _, None -> ()
        | Ok selected, Some endpoint ->
          assert (
            Asic.Selection.equal selected { remembered with endpoint; assignments = [] })
        | _ -> failwith "Preparation default disagrees with catalog endpoint order")
  done;
  List.iter
    [ None; Some { Asic_snapshot_fixture.snapshot with catalog_default = None } ]
    ~f:(fun asic ->
      assert (Result.is_error (Preparation_view.selection ~remembered:None ~asic));
      assert (
        Result.equal
          Asic.Selection.equal
          String.equal
          (Preparation_view.selection ~remembered:(Some remembered) ~asic)
          (Ok remembered)))
;;
