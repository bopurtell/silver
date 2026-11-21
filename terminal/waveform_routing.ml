open! Core
module Host = Workspace_host
module Waveforms = Hardcaml_workbench_workspaces.Waveforms
module View = Waveform_view

type action =
  | Host
  | Host_boundary
  | Waveform of View.input
  | Waves of View.input
  | Signals of View.input
  | Pane of View.input
  | Close_quick
  | Consume

let key event input =
  match View.edit_key event with
  | Some key -> Some key
  | None ->
    (match event, input with
     | Bonsai_term.Event.Key_press { key = Arrow `Left; mods = [] }, _ -> Some View.Left
     | Key_press { key = Arrow `Right; mods = [] }, _ -> Some View.Right
     | _, Some (Host.Character c) -> Some (View.Char c)
     | _, Some Enter -> Some Enter
     | _, Some Escape -> Some Escape
     | _, Some Backspace -> Some Backspace
     | _, Some Next -> Some Down
     | _, Some Previous -> Some Up
     | _ -> None)
;;

let clear_view view = view |> View.clear_count |> View.clear_selection

let navigation_changed (before : Host.t) (after : Host.t) =
  let open Hardcaml_workbench_protocol.Workspace in
  let kind host = Option.map (Host.focused host) ~f:(fun tile -> tile.kind) in
  not (Option.equal Workspace_id.equal before.active after.active)
  || not (Option.equal Tile_id.equal before.focus after.focus)
  || not (Option.equal String.equal (kind before) (kind after))
;;

let route (host : Host.t) ~quick ~editing_text ~identity_modal event =
  let input = Host.decode_event event in
  let boundary =
    Option.is_some host.palette
    || host.prefix > 0
    || host.paste
    || host.editing_filter
    || Option.exists input ~f:(function
      | Host.Character ' ' -> not editing_text
      | Focus | Focus_previous | Paste_start | Paste_end -> true
      | _ -> false)
  in
  if boundary
  then Host_boundary
  else (
    let key = key event input in
    let modal = editing_text || identity_modal in
    if modal || quick
    then (
      match key with
      | Some (Escape | Char 'q') when not modal -> Close_quick
      (* The quick overlay has no focused Waves tile and keeps its old shortcuts. *)
      | Some (Char ('0' .. '9')) when not modal -> Consume
      | Some key -> Waveform key
      | None -> Consume)
    else (
      let pane = Option.bind (Host.focused host) ~f:(fun tile -> Waveforms.pane tile.kind) in
      match pane, key with
       | Some Waves, Some (Char ('0' .. '9') as key) -> Waves key
       | Some Waves, Some key when Option.is_some (View.transition_direction key) ->
         Waves key
      | Some Signals, Some (Char ('0' .. '9' | 'V') as key) -> Signals key
      | ( Some (Session | Signals | Waves)
        , Some
            (( Char
                 ('j' | 'k' | 'h' | 'l' | 'H' | 'L' | '[' | ']' | '+' | '=' | '-' | ':'
                 | '/' | 'g' | 'G' | 'i' | '{' | '}')
             | Up | Down | Left | Right | Enter | Escape ) as key) ) ->
         (match pane with
          | Some Waves -> Waves key
          | Some Signals -> Signals key
          | _ -> Waveform key)
      | Some Picker, Some ((Char ('j' | 'k') | Down | Up | Enter) as key)
      | Some Logs, Some ((Char ('j' | 'k' | 'G') | Down | Up) as key) -> Pane key
      | _ -> Host))
;;

let test_host () =
  let open Hardcaml_workbench_protocol in
  let s = Workspace.initial ~session_id:(Workspace.Session_id.of_string "waveform-routing") in
  let window = (List.hd_exn s.windows).id in
  let registry =
    Workspace.apply
      s
      (Mutate { expected_revision = s.revision; mutation = Waveforms.create ~window })
    |> Result.ok
    |> Option.value_exn
  in
  let workspace = Waveforms.find registry |> Option.value_exn in
  let host = Host.switch (Host.receive Host.empty registry) workspace.id in
  fun pane ->
    let tile =
      List.find_exn (Host.tiles host) ~f:(fun tile ->
        String.equal tile.kind (Waveforms.kind pane))
    in
    { host with focus = Some tile.id }
;;

let ascii c = Bonsai_term.Event.Key_press { key = ASCII c; mods = [] }

let%test_unit "focused pane owns bare digits independently of trace availability" =
  let focus = test_host () in
  let route pane c =
    route (focus pane) ~quick:false ~editing_text:false ~identity_modal:false (ascii c)
  in
  List.iter [ '0'; '2'; '9' ] ~f:(fun c ->
    assert (Poly.equal (route Waves c) (Waves (Char c)));
    assert (Poly.equal (route Signals c) (Signals (Char c)));
    List.iter [ Waveforms.Session; Picker; Logs ] ~f:(fun pane ->
      assert (Poly.equal (route pane c) Host)));
  assert (Poly.equal (route Picker 'j') (Pane (Char 'j')));
  assert (Poly.equal (route Logs 'G') (Pane (Char 'G')))
;;

let%test_unit "leaders and editors take precedence; Signals gets visual and toggle keys" =
  let host = test_host () Signals in
  let route ?(host = host) ?(editing_text = false) ?(identity_modal = false) event =
    route host ~quick:false ~editing_text ~identity_modal event
  in
  assert (Poly.equal (route (ascii 'V')) (Signals (Char 'V')));
  let key key = Bonsai_term.Event.Key_press { key; mods = [] } in
  assert (Poly.equal (route (key Enter)) (Signals Enter));
  assert (Poly.equal (route (key Escape)) (Signals Escape));
  assert (Poly.equal (route (ascii ' ')) Host_boundary);
  assert (Poly.equal (route (key Tab)) Host_boundary);
  assert (Poly.equal (route ~host:{ host with prefix = 1 } (ascii '2')) Host_boundary);
  assert (Poly.equal (route ~host:{ host with paste = true } (ascii '2')) Host_boundary);
  assert (Poly.equal (route ~editing_text:true (ascii '2')) (Waveform (Char '2')));
  assert (Poly.equal (route ~editing_text:true (ascii ' ')) (Waveform (Char ' ')));
  assert (Poly.equal (route ~identity_modal:true (ascii '2')) (Waveform (Char '2')));
  assert (Poly.equal (route ~host:Host.empty (ascii '2')) Host)
;;

let%test_unit "transition keys belong only to focused Waves outside modals" =
  let focus = test_host () in
  let route_event = route in
  let route ?(quick = false) ?(editing_text = false) ?(identity_modal = false) host c =
    route_event host ~quick ~editing_text ~identity_modal (ascii c)
  in
  List.iter [ 'w'; 'b'; 'n'; 'p' ] ~f:(fun c ->
    let host = focus Waves in
    assert (Poly.equal (route host c) (Waves (Char c)));
    assert (Poly.equal (route ~quick:true host c) (Waveform (Char c)));
    assert (Poly.equal (route ~editing_text:true host c) (Waveform (Char c)));
    assert (Poly.equal (route ~identity_modal:true host c) (Waveform (Char c)));
    assert (Poly.equal (route { host with prefix = 1 } c) Host_boundary);
    assert (Poly.equal (route Host.empty c) Host);
    List.iter [ Waveforms.Session; Signals; Picker; Logs ] ~f:(fun pane ->
      assert (Poly.equal (route (focus pane) c) Host)));
  let host = focus Waves in
  let host_step host c = Host.input host (Character c) ~commands:[] in
  let leader = fst (host_step (fst (host_step host ' ')) 'c') in
  assert (Poly.equal (route leader 'p') Host_boundary);
  (match snd (host_step leader 'p') with
   | Execute (_, Toggle_palette_hints) -> ()
   | _ -> assert false);
  let palette = fst (host_step leader 'c') in
  assert (Option.is_some palette.palette);
  List.iter [ 'n'; 'p' ] ~f:(fun c ->
    assert (Poly.equal (route palette c) Host_boundary);
    assert (Poly.equal (route { host with editing_filter = true } c) Host_boundary);
    assert (Poly.equal (route { host with paste = true } c) Host_boundary);
    assert (Poly.equal (route host (Char.uppercase c)) Host);
    let ctrl = Bonsai_term.Event.Key_press { key = ASCII c; mods = [ Ctrl ] } in
    assert (
      Poly.equal
        (route_event host ~quick:false ~editing_text:false ~identity_modal:false ctrl)
        Host))
;;

let%test_unit "leaving Waves discards its count; Signals applies and cancels a visual range" =
  let focus = test_host () in
  let waves = focus Waves and signals = focus Signals in
  let artifact : Hardcaml_workbench_protocol.Simulation.Artifact.t =
    { id = "trace"
    ; attempt_id = "attempt"
    ; case_id = None
    ; label = "trace"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = None
    ; sha256 = None
    ; availability = Available
    }
  in
  let data =
    Waveform_data.parse
      "$timescale 1ns $end $var wire 1 ! a $end $var wire 1 @ b $end \
       $enddefinitions $end #0 0! 0@ #9 1! 1@ #12 0! #16 1!"
  in
  let step host view event =
    let editing_text = Option.is_some view.View.editing in
    let identity_modal = Option.is_some view.identity_scroll in
    match route host ~quick:false ~editing_text ~identity_modal event with
    | Waveform key -> View.input view key
    | Waves key -> View.waves_input view key
    | Signals key -> View.signals_input view key
    | Host_boundary -> clear_view view
    | _ -> assert false
  in
  let key key = Bonsai_term.Event.Key_press { key; mods = [] } in
  let view = View.receive (View.create ~project:"project" artifact) data in
  let pending = step waves (step waves view (ascii '2')) (ascii '0') in
  assert (Option.equal Int.equal pending.pending_count (Some 20));
  assert (Int64.equal pending.cursor view.cursor);
  assert (Option.is_none (step waves pending (ascii ' ')).pending_count);
  assert (Option.is_none (step waves pending (key Tab)).pending_count);
  let editor = step waves pending (ascii '/') in
  assert (Option.is_none editor.pending_count && Option.is_some editor.editing);
  assert (not (navigation_changed waves waves));
  let move_focus before after view =
    if navigation_changed before after then clear_view view else view
  in
  let view = move_focus waves signals pending in
  let view = step signals view (ascii '2') in
  assert (Option.is_none view.pending_count);
  let view = step waves (move_focus signals waves view) (ascii 'L') in
  assert (Int64.equal view.cursor 1L);
  let jumped = step waves (step waves view (ascii '3')) (ascii 'n') in
  assert (Int64.equal jumped.cursor 16L && Option.is_none jumped.pending_count);
  let returned = step waves (step waves jumped (ascii '2')) (ascii 'p') in
  assert (Int64.equal returned.cursor 9L && Option.is_none returned.pending_count);
  let visual = step signals (step signals view (ascii 'V')) (ascii 'j') in
  assert (Option.is_some visual.visual_selection);
  assert (Option.is_none (move_focus signals waves visual).visual_selection);
  assert (Option.is_none (step signals visual (ascii ' ')).visual_selection);
  let cancelled = step signals visual (key Escape) in
  assert (Option.is_none cancelled.visual_selection && Set.equal cancelled.selected view.selected);
  let applied = step signals visual (key Enter) in
  assert (Option.is_none applied.visual_selection && Set.is_empty applied.selected)
;;
