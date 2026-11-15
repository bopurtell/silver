open! Core
open Hardcaml_workbench_protocol
module H = Workspace_host
module W = Workspace

let native_event bytes =
  match Notty.Unescape.decode (String.to_list bytes |> List.map ~f:Uchar.of_char) with
  | [ `Key (key, mods) ] ->
    let key =
      match key with
      | `Backspace -> Bonsai_term.Event.Key.Backspace
      | `ASCII c -> ASCII c
      | `Uchar u -> Uchar u
      | _ -> assert false
    in
    let mods =
      List.map mods ~f:(function
        | `Ctrl -> Bonsai_term.Event.Modifier.Ctrl
        | `Meta -> Meta
        | `Shift -> Shift)
    in
    Bonsai_term.Event.Key_press { key; mods }
  | _ -> assert false
;;

let word_events =
  List.map [ "\008"; "\023"; "\027\127" ] ~f:native_event
  @ [ Key_press { key = Backspace; mods = [ Ctrl ] }
    ; Key_press { key = Backspace; mods = [ Meta; Shift ] }
    ; Key_press { key = ASCII 'W'; mods = [ Ctrl ] }
    ; Key_press { key = Uchar (Uchar.of_char 'w'); mods = [ Ctrl ] }
    ]
;;

let step host event =
  let host, effect = H.input host event ~commands:[] in
  (match effect with
   | No_effect -> ()
   | _ -> assert false);
  host
;;

let decode event = Option.value_exn (H.decode_event event)

let%test_unit "shared deletion keeps Unicode codepoints and waveform word boundaries" =
  List.iter
    [ "", ""; "aé", "a"; "a界", "a"; "a🙂", "a"; "é", "e" ]
    ~f:(fun (before, after) ->
      [%test_result: string] (Text_edit.drop_character before) ~expect:after);
  List.iter
    [ "", ""
    ; "./[]  ", ""
    ; "foo bar   ", "foo "
    ; "top.data_bus", "top."
    ; "top.data[7:0]", "top.data[7:"
    ; "top.é界🙂́", "top."
    ]
    ~f:(fun (before, after) ->
      [%test_result: string] (Text_edit.delete_word before) ~expect:after)
;;

let%test_unit "native and explicit word gestures edit every palette argument locally" =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "word-forms") in
  let host = H.receive H.empty snapshot in
  let tile = List.hd_exn snapshot.tiles in
  let capture = Option.value_exn (H.capture host) in
  let suite : Simulation.Suite.t =
    { id = "suite"; label = "Suite"; default_seed = "1"; cases = []; parameters = [] }
  in
  let form = Simulation_view.Form.create suite in
  let arguments =
    [ None
    ; Some (H.Plan_endpoint ("flow", "profile"))
    ; Some (Preparation_inputs ("flow", "profile"))
    ; Some (Finalization_attempt Fs0_fixture.run_a)
    ; Some (Resource_path false)
    ; Some (Resource_path true)
    ; Some (Acceptance (Fs0_fixture.run_a, "key", "/execution"))
    ]
    @ List.init 3 ~f:(fun field ->
      Some (H.Simulation_selection (tile.id, "scope", "digest", { form with field })))
  in
  List.iter arguments ~f:(fun argument ->
    let before =
      { host with
        palette =
          Some { capture; commands = []; query = "top.界é🙂   "; index = 3; argument }
      }
    in
    List.iter word_events ~f:(fun event ->
      let after = step before (decode event) in
      let palette = Option.value_exn after.palette in
      [%test_result: string] palette.query ~expect:"top.";
      assert (palette.index = 0);
      assert (Poly.equal palette.argument argument);
      assert (phys_equal after.registry before.registry);
      assert (Option.equal W.Tile_id.equal after.focus before.focus));
    let before =
      { before with
        palette = Option.map before.palette ~f:(fun p -> { p with query = "top.界é🙂" })
      }
    in
    let after = step before (decode (native_event "\127")) in
    [%test_result: string] (Option.value_exn after.palette).query ~expect:"top.界é";
    let after = step after H.Delete_word |> fun h -> step h H.Delete_word in
    assert (String.is_empty (Option.value_exn after.palette).query);
    assert (String.is_empty (Option.value_exn (step after H.Delete_word).palette).query);
    let pasted = step before H.Paste_start in
    let after = step pasted (decode (List.hd_exn word_events)) in
    [%test_result: string] (Option.value_exn after.palette).query ~expect:"top.界é🙂";
    assert after.paste)
;;

let%test_unit "single-line tile filters accept Unicode and isolate deletion to focus" =
  List.iter
    [ "synthesis"; "resources"; "hierarchy"; "simulation-catalog"; "logs" ]
    ~f:(fun kind ->
      let snapshot = W.initial ~session_id:(W.Session_id.of_string ("word-" ^ kind)) in
      let tile = { (List.hd_exn snapshot.tiles) with kind } in
      let snapshot = { snapshot with tiles = tile :: List.tl_exn snapshot.tiles } in
      let other = List.last_exn snapshot.tiles in
      let host = H.receive H.empty snapshot in
      let host = H.set_filter host other.id "keep" in
      let host = { host with focus = Some tile.id; editing_filter = true } in
      let typed = step host (H.Text "top.界é🙂") in
      [%test_result: string] (H.local typed tile.id).filter ~expect:"top.界é🙂";
      let erased = step typed (decode (native_event "\127")) in
      [%test_result: string] (H.local erased tile.id).filter ~expect:"top.界é";
      List.iter word_events ~f:(fun event ->
        let after = step typed (decode event) in
        [%test_result: string] (H.local after tile.id).filter ~expect:"top.";
        [%test_result: string] (H.local after other.id).filter ~expect:"keep";
        assert after.editing_filter;
        assert (phys_equal after.registry typed.registry));
      let after = step (step typed H.Paste_start) H.Delete_word in
      [%test_result: string] (H.local after tile.id).filter ~expect:"top.界é🙂")
;;

let%test_unit "production inspector and shared Timing filter gate edits without requests" =
  List.iter [ "overview"; "timing-paths" ] ~f:(fun kind ->
    let snapshot = W.initial ~session_id:(W.Session_id.of_string ("gate-" ^ kind)) in
    let tile = { (List.hd_exn snapshot.tiles) with kind } in
    let snapshot = { snapshot with tiles = tile :: List.tl_exn snapshot.tiles } in
    let workspace = W.workspace snapshot tile.workspace in
    let context = W.context snapshot workspace.context in
    let snapshot =
      W.apply
        snapshot
        (Mutate
           { expected_revision = snapshot.revision
           ; mutation =
               Select_run
                 { workspace = workspace.id
                 ; context = context.id
                 ; expected_selection_revision = context.selection_revision
                 ; run = Some Fs0_fixture.run_a
                 }
           })
      |> Result.ok
      |> Option.value_exn
    in
    let host = H.receive H.empty snapshot in
    let host = { host with focus = Some tile.id; chrome = false } in
    let view =
      { (Inspection_view.create
           ~run:Fs0_fixture.run_a
           ~domain:"timing"
           ~stage:"signoff"
           ())
        with
        editing = true
      ; filter = "top.界é🙂"
      ; generation = 7
      }
    in
    let host = H.set_inspection host tile.id (Some view) in
    let send host event =
      match H.route_inspection_filter_event host event with
      | Filter_handled host -> host
      | _ -> assert false
    in
    let current host = Option.value_exn (H.inspection host tile.id) in
    List.iter word_events ~f:(fun event ->
      let after = send host event in
      [%test_result: string] (current after).filter ~expect:"top.";
      assert ((current after).editing && (current after).generation = 7);
      assert (Option.is_none (current after).requested);
      assert (phys_equal after.registry host.registry));
    let after = send host (native_event "\127") in
    [%test_result: string] (current after).filter ~expect:"top.界é";
    let after = send (send host (Paste `Start)) (List.hd_exn word_events) in
    [%test_result: string] (current after).filter ~expect:"top.界é🙂";
    assert after.paste;
    assert (Option.is_some (current after).filter_notice))
;;

let%test_unit "inspector action API reuses Unicode deletion and protects paste" =
  let view =
    { (Inspection_view.create ~run:Fs0_fixture.run_a ~domain:"timing" ~stage:"signoff" ()) with
      editing = true
    ; filter = "top.界é🙂"
    }
  in
  let apply view action =
    let view, operation = Inspection_view.input ~width:100 ~height:30 view action in
    assert (Option.is_none operation);
    Option.value_exn view
  in
  [%test_result: string] (apply view Backspace).filter ~expect:"top.界é";
  [%test_result: string] (apply view Delete_word).filter ~expect:"top.";
  [%test_result: string]
    (apply { view with pasting = true } Delete_word).filter
    ~expect:view.filter
;;
