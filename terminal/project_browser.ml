open! Core
open Bonsai_term
module H = Workspace_host

type item =
  { label : string
  ; destination : string
  ; commands : H.command list
  }

let item label destination commands =
  { label = Artifact_view.safe label
  ; destination = Artifact_view.safe destination
  ; commands
  }
;;

let profile_items chip flows =
  List.concat_map flows ~f:(fun (flow, profiles) ->
    item ("    " ^ flow) (chip ^ "/" ^ flow) []
    :: List.map profiles ~f:(fun profile ->
      item
        ("      " ^ profile)
        (chip ^ "/" ^ flow ^ "/" ^ profile)
        [ H.command
            "project.duplicate-profile"
            "Duplicate Profile…"
            "copy profile"
            (Duplicate_profile (Some (chip, flow, profile)))
        ]))
;;

let catalog
  ?(build_tool = Presentation.Build_tool.Dune)
  ?share
  ?ip
  ?new_module
  ~libraries
  (asic : Silver_protocol.Asic.Snapshot.t option)
  =
  item
    "Project"
    "Project"
    (Option.to_list ip @ Option.to_list new_module @ Option.to_list share)
  :: (List.map libraries ~f:(fun (name, dir) ->
         item ("IP library: " ^ name) dir (H.library_authoring_commands ~build_tool dir))
      @ Option.value_map asic ~default:[] ~f:(fun s ->
        List.concat_map s.chips ~f:(fun chip ->
          let active =
            Option.exists s.chip_target ~f:(fun target ->
              String.equal target.chip chip.id)
          in
          item
            ("Chip: " ^ chip.id)
            chip.id
            (H.command "project.new-flow" "New Flow…" "new flow" (New_flow (Some chip.id))
             :: Option.to_list
                  (Option.some_if
                     (not active)
                     (H.command
                        "browser.profiles"
                        "Browse flows and profiles…"
                        "read only"
                        (Browse_chip_profiles chip.id))))
          ::
          (if active
           then profile_items chip.id (List.map s.flows ~f:(fun f -> f.id, f.profiles))
           else []))))
;;

type region =
  | Objects
  | Commands

type viewport = [ `Follow of int | `Scroll of int ]

type t =
  { lifetime : unit ref
  ; message : string
  ; capture : H.capture
  ; items : item list
  ; region : region
  ; object_index : int
  ; object_top : viewport
  ; command_index : int
  ; command_top : viewport
  ; query : string option
  ; editing : bool
  ; count : int
  ; pasting : bool
  }

let create capture items =
  { lifetime = ref ()
  ; message = ""
  ; capture
  ; items
  ; region = Objects
  ; object_index = 0
  ; object_top = `Follow 0
  ; command_index = 0
  ; command_top = `Follow 0
  ; query = None
  ; editing = false
  ; count = 0
  ; pasting = false
  }
;;

let objects t =
  match t.query with
  | None -> t.items
  | Some q ->
    List.filter t.items ~f:(fun i ->
      String.is_substring
        (String.lowercase (i.label ^ " " ^ i.destination))
        ~substring:(String.lowercase q))
;;

let selected t = List.nth (objects t) t.object_index

let receive_owner t ~chip ~parent = function
  | Ok (Silver_protocol.Authoring.Response.Owner_described desc) ->
    let children =
      profile_items
        chip
        (List.map desc.flows ~f:(fun flow -> flow.id, List.map flow.profiles ~f:fst))
    in
    (* An overlapping click can already have expanded this captured row. *)
    let items =
      List.concat_map t.items ~f:(fun i ->
        if phys_equal i parent
        then
          { i with commands = List.take i.commands 1 }
          ::
          (if List.is_empty children
           then [ item "    No flows advertised" chip [] ]
           else children)
        else [ i ])
    in
    let keep = selected t in
    let t = { t with items; message = "" } in
    let index =
      Option.bind keep ~f:(fun keep ->
        List.findi (objects t) ~f:(fun _ i -> phys_equal i keep) |> Option.map ~f:fst)
    in
    { t with
      object_index = Option.value index ~default:t.object_index
    ; command_index = 0
    ; command_top = `Follow 0
    }
  | Error msg | Ok (Failed { message = msg; _ }) ->
    { t with message = Artifact_view.safe msg }
  | _ -> { t with message = "Unexpected catalog response" }
;;

let commands t = Option.value_map (selected t) ~default:[] ~f:(fun i -> i.commands)

let footer_rows ~hints t height =
  if height < 10 then 0 else 1 + Bool.to_int (hints || not (String.is_empty t.message))
;;

let geometry ~width ~height =
  Panel.geometry ~framed:(width >= 32 && height >= 12) ~width ~height
    ~horizontal_padding:0 ~vertical_padding:0
;;

type layout =
  { bounds : Palette_view.bounds
  ; geometry : Panel.geometry
  ; pad : int
  ; inner : int
  ; top : int
  ; footer : int
  ; object_lines : int
  ; action_lines : int
  }

let layout ~hints t (d : Dimensions.t) =
  let axis n margin cap =
    let size =
      Int.max 0 (Int.min cap (if n >= margin * 12 then n - (2 * margin) else n))
    in
    (n - size) / 2, size
  in
  let x, width = axis d.width 2 132
  and y, height = axis d.height 1 38 in
  let bounds : Palette_view.bounds = { x; y; width; height } in
  let g = geometry ~width ~height in
  let width = g.content_width and height = g.content_height in
  let pad = if width >= 20 then 1 else 0 in
  let inner = width - (2 * pad) in
  let top = if height >= 6 || t.editing then 2 else 1 in
  let footer = footer_rows ~hints t height in
  let room = Int.max 0 (height - top - footer) in
  let object_lines, action_lines =
    if inner >= 96
    then room, room
    else if room < 4
    then (
      match t.region with
      | Objects -> room, 0
      | Commands -> 0, room)
    else (
      let action_lines = Int.min (room / 2) (1 + Int.max 1 (List.length (commands t))) in
      room - action_lines, action_lines)
  in
  { bounds; geometry = g; pad; inner; top; footer; object_lines; action_lines }
;;

let viewport ~hints t d region =
  let { object_lines; action_lines; _ } = layout ~hints t d in
  match region with
  | Objects ->
    t.object_top, t.object_index, List.length (objects t), Int.max 0 (object_lines - 1)
  | Commands ->
    t.command_top, t.command_index, List.length (commands t), Int.max 0 (action_lines - 1)
;;

let set_top t region top =
  match region with
  | Objects -> { t with object_top = top }
  | Commands -> { t with command_top = top }
;;

let visible_top top ~index ~length ~capacity =
  match top with
  | `Follow top -> List_viewport.reveal ~top ~index ~length ~capacity
  | `Scroll top -> List_viewport.clamp ~top ~length ~capacity
;;

let current_top ~hints t d region =
  let top, index, length, capacity = viewport ~hints t d region in
  visible_top top ~index ~length ~capacity
;;

let reveal ~hints t d region ~top =
  let _, index, length, capacity = viewport ~hints t d region in
  set_top t region (`Follow (List_viewport.reveal ~top ~index ~length ~capacity))
;;

type result =
  | Stay of t
  | Close
  | Invoke of H.command

type target =
  | Object of int
  | Command of int
  | Back
  | Filter
  | Focus_region of region

let finish_filter t = { t with editing = false; count = 0 }

let commit t (command : H.command) =
  let command_index =
    List.findi (commands t) ~f:(fun _ c -> String.equal c.id command.id)
    |> Option.value_map ~default:t.command_index ~f:fst
  in
  { (finish_filter t) with region = Commands; command_index }
;;

let default_dimensions : Dimensions.t = { width = 80; height = 24 }

let choose ?(hints = false) ?(dimensions = default_dimensions) t =
  function
  | Back -> Close
  | Filter -> Stay { t with editing = true; region = Objects; count = 0 }
  | Focus_region region -> Stay { (finish_filter t) with region }
  | Object i ->
    let top = current_top ~hints t dimensions Objects in
    let selection =
      if i = t.object_index
      then t
      else { t with object_index = i; command_index = 0; command_top = `Follow 0 }
    in
    Stay (reveal ~hints { (finish_filter selection) with region = Objects } dimensions Objects ~top)
  | Command i ->
    Option.value_map (List.nth (commands t) i) ~default:(Stay t) ~f:(fun c -> Invoke c)
;;

let input ?(hints = false) ?(dimensions = default_dimensions) t (key : H.input) =
  let choose = choose ~hints ~dimensions in
  let move delta =
    let next n len = Int.max 0 (Int.min (len - 1) (n + (delta * Int.max 1 t.count))) in
    match t.region with
    | Objects -> choose t (Object (next t.object_index (List.length (objects t))))
    | Commands ->
      let top = current_top ~hints t dimensions Commands in
      let t =
        { t with command_index = next t.command_index (List.length (commands t)); count = 0 }
      in
      Stay (reveal ~hints t dimensions Commands ~top)
  in
  let scroll delta =
    let viewport, index, length, capacity = viewport ~hints t dimensions t.region in
    let top = visible_top viewport ~index ~length ~capacity in
    let next = List_viewport.scroll ~top ~delta:(delta * Int.max 1 t.count) ~length ~capacity in
    let t = if t.count = 0 then t else { t with count = 0 } in
    Stay (if next = top then t else set_top t t.region (`Scroll next))
  in
  let query q =
    Stay
      { t with
        query = Some q
      ; object_index = 0
      ; object_top = `Follow 0
      ; command_index = 0
      ; command_top = `Follow 0
      ; count = 0
      }
  in
  let append q text =
    if String.length q + String.length text <= 512 then query (q ^ text) else Stay t
  in
  let edit = Option.some_if t.editing (Option.value t.query ~default:"") in
  match key, edit with
  | Paste_start, _ -> Stay { t with pasting = true }
  | Paste_end, _ -> Stay { t with pasting = false }
  | _, _ when t.pasting -> Stay t
  | Escape, Some _ -> Stay (finish_filter t)
  | Escape, None -> Close
  | (Focus | Focus_previous), _ ->
    choose
      t
      (Focus_region
         (match t.region with
          | Objects -> Commands
          | Commands -> Objects))
  | Enter, _ when Poly.equal t.region Objects -> choose t (Focus_region Commands)
  | Enter, _ -> choose t (Command t.command_index)
  | Character c, Some q when Poly.equal t.region Objects -> append q (String.of_char c)
  | Text s, Some q when Poly.equal t.region Objects -> append q s
  | Backspace, Some q -> query (Text_edit.apply Backspace q)
  | Delete_word, Some q -> query (Text_edit.delete_word q)
  | Clear_filter, Some _ -> query ""
  | Scroll_up, None -> scroll (-1)
  | Scroll_down, None -> scroll 1
  | Character '/', _ -> choose t Filter
  | Character ('0' .. '9' as ch), _ ->
    Stay { t with count = Int.min 9999 ((10 * t.count) + Char.to_int ch - 48) }
  | Character (('g' | 'G') as ch), _ ->
    let last =
      match t.region with
      | Objects -> List.length (objects t)
      | Commands -> List.length (commands t)
    in
    move (if Char.equal ch 'g' then -last else last)
  | (Character 'j' | Next), _ -> move 1
  | (Character 'k' | Previous), _ -> move (-1)
  | _ -> Stay t
;;

(* Half-open cell spans in panel coordinates. Padding and the pane gutter do not acquire a
   neighbour's target, even when a long label is clipped. *)
type cell =
  { col : int
  ; row : int
  ; width : int
  ; text : string
  ; role : Host_view.Role.t
  ; target : target option
  }

let selection_marker = " › "

let page ?(hints = false) t d =
  let { bounds; geometry = g; pad; inner; top; footer; object_lines; action_lines } =
    layout ~hints t d
  in
  let height = g.content_height in
  let cell col row width role ?target text = { col; row; width; role; target; text } in
  let back = if inner >= 44 then "[Back to inspection]" else "[Back]" in
  let bw = Int.min inner (String.length back) in
  let chrome =
    [ cell pad 0 (Int.max 0 (inner - bw - 1)) Heading "Manage This Project"
    ; cell (pad + inner - bw) 0 bw Foreground ~target:Back back
    ]
  in
  let filter =
    let prefix = "Filter: " in
    let q = Option.value t.query ~default:"" in
    let text =
      if t.editing
      then prefix ^ Host_view.fit_label ~width:(Int.max 0 (inner - 9)) q ^ "▏"
      else if String.is_empty q
      then (if hints then "[/ filter]" else "[Filter]")
      else prefix ^ q
    in
    let width = if t.editing then inner else Int.min inner (View.width (View.text text)) in
    cell pad 1 width (if t.editing then Heading else Foreground) ~target:Filter text
  in
  let objs = objects t
  and cmds = commands t in
  let pane r col row width lines index offset label items describe =
    let capacity = Int.max 0 (lines - 1) in
    let total = List.length items in
    let focused = Poly.equal t.region r in
    let heading =
      (if focused then "▶ " else "  ")
      ^ label
      ^ if total > capacity then sprintf " · %d/%d" (index + 1) total else ""
    in
    let offset = visible_top offset ~index ~length:total ~capacity in
    let rows =
      if total = 0 && capacity > 0
      then
        [ cell
            col
            (row + 1)
            width
            Muted
            (if Poly.equal r Objects then "  (no match)" else "  (no actions)")
        ]
      else
        List.take (List.drop items offset) capacity
        |> List.mapi ~f:(fun n item ->
          let i = offset + n in
          let text, target = describe i item in
          cell
            col
            (row + n + 1)
            width
            (if focused && index = i then Selection else Foreground)
            ~target
            ((if index = i then selection_marker else "   ") ^ text))
    in
    if lines <= 0
    then []
    else
      cell
        col
        row
        width
        (if focused then Heading else Muted)
        ~target:(Focus_region r)
        heading
      :: rows
  in
  let objects col row width lines =
    pane Objects col row width lines t.object_index t.object_top "Objects" objs (fun i o ->
      o.label, Object i)
  and actions col row width lines =
    pane Commands col row width lines t.command_index t.command_top "Actions" cmds (fun i c ->
      ( String.substr_index c.H.title ~pattern:" · "
        |> Option.value_map ~default:c.title ~f:(String.prefix c.title)
      , Command i ))
  in
  let body =
    if inner >= 96
    then (
      let left = inner / 2 in
      objects pad top left object_lines
      @ actions (pad + left + 1) top (inner - left - 1) action_lines)
    else
      objects pad top inner object_lines
      @ actions pad (top + object_lines) inner action_lines
  in
  let foot =
    if footer = 0
    then []
    else
      [ cell
          pad
           (height - footer)
          inner
          Muted
          ("For: "
           ^ Option.value_map (selected t) ~default:"(no match)" ~f:(fun i ->
             Host_view.fit_label ~width:(Int.max 0 (inner - 5)) i.destination))
       ]
      @ (if footer = 2
         then
           [ cell pad (height - 1) inner Muted
               (if not (String.is_empty t.message)
                then t.message
                else if t.editing
                then "Type to filter · Tab actions · Esc finish filter"
                 else "Tab switch pane · j/k move · Ctrl-y/e scroll · Enter select · Esc back")
           ]
         else [])
  in
  ( bounds
   , List.filter_map
       (chrome @ (if top = 2 then [ filter ] else []) @ body @ foot)
       ~f:(fun c ->
         Option.some_if (c.row < height && c.width > 0)
           { c with col = c.col + g.border; row = c.row + g.border }) )
;;

let hit ?(hints = false) t d ~x ~y =
  let bounds, cells = page ~hints t d in
  let col = x - bounds.x
  and row = y - bounds.y in
  List.find_map cells ~f:(fun c ->
    if row = c.row && col >= c.col && col < c.col + c.width then c.target else None)
;;

let scroll ?(hints = false) t d ~x ~y ~direction =
  let bounds, cells = page ~hints t d in
  let col = x - bounds.x
  and row = y - bounds.y in
  let g = geometry ~width:bounds.width ~height:bounds.height in
  (* Pane headers mark each rectangle, including blank rows below short lists. *)
  let region =
    if row >= bounds.height - g.border - footer_rows ~hints t g.content_height
    then None
    else
      List.fold cells ~init:None ~f:(fun region c ->
        match c.target with
        | Some (Focus_region r) when row >= c.row && col >= c.col && col < c.col + c.width
          -> Some r
        | _ -> region)
  in
  match region with
  | None -> Stay t
  | Some region ->
    input
      ~hints
      ~dimensions:d
      { (finish_filter t) with region }
      (match direction with
       | `Up -> Previous
       | `Down -> Next)
;;

let render ?(hints = false) t appearance d background =
  let bounds, cells = page ~hints t d in
  let g = geometry ~width:bounds.width ~height:bounds.height in
  let surface = Host_view.Role.backdrop appearance Foreground
  and raised = Host_view.Role.backdrop appearance Selection
  and ink = Host_view.Role.foreground appearance Foreground
  and secondary = Host_view.Role.foreground appearance Muted in
  let accent = Host_view.Role.foreground appearance Focus in
  let attrs fg bg = [ Attr.fg fg; Attr.bg bg ] in
  let paper = attrs ink surface in
  let label c =
    match c.role, c.target with
    | Selection, _ ->
      (* Only the marker carries the scheme accent; keep the label in ink. *)
      let text = String.chop_prefix_exn c.text ~prefix:selection_marker in
      ( View.hcat
          [ View.text ~attrs:(attrs accent raised) selection_marker
          ; View.text ~attrs:(attrs ink raised) text
          ]
      , attrs ink raised )
    | role, target ->
      let style =
        match role, target with
        | Heading, Some (Focus_region _) -> Attr.bold :: attrs accent surface
        | Heading, _ -> Attr.bold :: paper
        | Muted, _ | _, Some (Back | Filter) -> attrs secondary surface
        | _ -> paper
      in
      View.text ~attrs:style c.text, paper
  in
  let paint c =
    let label, attrs = label c in
    (* Clip first; the painted rectangle supplies opaque padding for short labels. *)
    let label = View.crop ~r:(Int.max 0 (View.width label - c.width)) label in
    View.zcat [ label; View.rectangle ~attrs ~width:c.width ~height:1 () ]
    |> View.pad ~l:(c.col - g.border) ~t:(c.row - g.border)
  in
  let base = View.rectangle ~attrs:paper ~width:g.content_width ~height:g.content_height () in
  let outline = attrs (Host_view.Role.foreground appearance Border) surface in
  let content = View.zcat (List.map cells ~f:paint @ [ base ]) in
  let panel =
    Panel.render ~rounded:true appearance ~attrs:outline ~title:View.none
      ~geometry:g ~width:bounds.width ~height:bounds.height content
  in
  let panel =
    if g.border = 1 && Appearance.Icons.equal appearance.icons Unicode
    then View.zcat [ View.pad ~l:2 (View.text ~attrs:(attrs accent surface) "───"); panel ]
    else panel
  in
  Palette_view.overlay ~background ~panel bounds
;;

module%test Permanent_project_window = struct
  let state =
    let capture : H.capture =
      { session = H.W.Session_id.of_string "browser"
      ; chip_target = None
      ; chip_epoch = 0
      ; revision = 0
      ; workspace = H.W.Workspace_id.of_string "inspection"
      }
    in
    let cmds =
      List.init 20 ~f:(fun i ->
        let label = sprintf "Action %02d" i in
        H.command label label "" H.Manage_project)
    in
    create
      capture
      (List.init 40 ~f:(fun i ->
         let label = sprintf "Object %02d" i in
         item label label cmds))
  ;;

  let stay = function
    | Stay t -> t
    | _ -> assert false
  ;;

  let%test_unit "selected object label uses the theme ink and selection surface" =
    let d : Dimensions.t = { width = 100; height = 30 } in
    let bounds, cells = page state d in
    let row = List.find_exn cells ~f:(fun cell -> Poly.equal cell.role Selection) in
    let ansi image =
      let b = Buffer.create 64 in
      Notty.Render.to_buffer b Notty.Cap.ansi (0, 0) (1, 1) (View.Private.notty_image image);
      Buffer.contents b
    in
    List.iter [ "silver-dark"; "silver-light" ] ~f:(fun key ->
      let scheme = Option.value_exn (Appearance.Scheme.of_key key) in
      let appearance = { Appearance.default with scheme } in
      let label = String.chop_prefix_exn row.text ~prefix:selection_marker in
      let actual =
        render state appearance d View.none
        |> View.crop
             ~l:(bounds.x + row.col + View.width (View.text selection_marker))
             ~t:(bounds.y + row.row)
      in
      let expected =
        View.text
          ~attrs:[ Attr.fg (Host_view.Role.foreground appearance Foreground)
                 ; Attr.bg (Host_view.Role.backdrop appearance Selection) ]
          (String.prefix label 1)
      in
      assert (String.equal (ansi actual) (ansi expected)))
  ;;

  let%test_unit "painted labels hit the scrolled selection in either layout" =
    List.iter
      [ 80, 24; 120, 30 ]
      ~f:(fun (width, height) ->
        let d : Dimensions.t = { width; height } in
        let t =
          List.fold [ H.Character 'G'; Focus; Character 'G' ] ~init:state ~f:(fun t key ->
             stay (input ~dimensions:d t key))
        in
        let buffer = Buffer.create (width * height) in
        Notty.Render.to_buffer
          buffer
          Notty.Cap.dumb
          (0, 0)
          (width, height)
          (View.Private.notty_image (render t Appearance.default d View.none));
        let lines = Buffer.contents buffer |> String.split_lines in
        let locate text =
          List.find_mapi_exn lines ~f:(fun y s ->
            String.substr_index s ~pattern:text
            |> Option.map ~f:(fun bytes ->
              View.width (View.text (String.prefix s bytes)), y))
        in
        let check label expected =
          let x, y = locate label in
          assert (Poly.equal (hit t d ~x ~y) expected);
          x, y
        in
        let _, oy = check "Object 39" (Some (Object 39))
        and ax, ay = check "Action 19" (Some (Command 19)) in
        let ox, oh = check "Objects" (Some (Focus_region Objects))
        and _, ah = check "Actions" (Some (Focus_region Commands)) in
        assert (if width = 80 then oy < ah && ay > ah else oh = ah && ox < ax);
        assert ((stay (scroll t d ~x:ox ~y:oy ~direction:`Up)).object_index = 38);
        assert ((stay (scroll t d ~x:ax ~y:ay ~direction:`Up)).command_index = 18);
        let tx, ty = locate "Manage This Project" in
        assert (tx > 0 && ty > 0);
        ignore (check "[Back to inspection]" (Some Back) : int * int);
        ignore (check "[Filter]" (Some Filter) : int * int);
        assert (Option.is_none (hit t d ~x:0 ~y:ty)))
  ;;

  let%test_unit "keyboard paging keeps independent object and action viewports" =
    List.iter [ 80, 16; 120, 16 ] ~f:(fun (width, height) ->
      let d : Dimensions.t = { width; height } in
      let hints = true in
      let apply t keys =
        List.fold keys ~init:t ~f:(fun t key -> stay (input ~hints ~dimensions:d t key))
      in
      let object_rows t =
        snd (page ~hints t d)
        |> List.filter_map ~f:(fun c ->
          match c.target with Some (Object i) -> Some (i, c) | _ -> None)
      in
      let _, _, _, capacity = viewport ~hints state d Objects in
      let t = apply state [ Character '3'; Scroll_down ] in
      let bounds, cells = page ~hints t d in
      let first, row = List.hd_exn (object_rows t) in
      assert (first = 3 && List.length (object_rows t) = capacity);
      assert (t.object_index = 0 && t.command_index = 0 && t.count = 0);
      assert (Poly.equal (hit ~hints t d ~x:(bounds.x + row.col) ~y:(bounds.y + row.row))
                (Some (Object 3)));
      assert (not (List.exists cells ~f:(fun c -> Poly.equal c.role Selection)));
      assert (List.exists cells ~f:(fun c -> String.equal c.text "For: Object 00"));
      let t = apply t [ Focus; Character '2'; Scroll_down ] in
      assert (Poly.equal t.object_top (`Scroll 3) && Poly.equal t.command_top (`Scroll 2)
              && t.command_index = 0);
      (match input ~hints ~dimensions:d t Enter with
       | Invoke c -> assert (String.equal c.id "Action 00")
       | _ -> assert false);
      let t = apply t [ Character '3'; Character 'j'; Character 'k' ] in
      assert (t.command_index = 2 && Poly.equal t.command_top (`Follow 2));
      let t = apply t [ Character '2'; Character 'k' ] in
      assert (t.command_index = 0 && Poly.equal t.command_top (`Follow 0));
      let t = apply t [ Scroll_down; Focus; Character '4'; Character 'j' ] in
      assert (t.object_index = 4 && Poly.equal t.object_top (`Follow 3));
      assert (Poly.equal t.command_top (`Follow 0));
      let t = apply t [ Character '9'; Character '9'; Scroll_down ] in
      assert (t.object_index = 4 && Poly.equal t.object_top (`Scroll (40 - capacity)));
      let t = apply t [ Character '/'; Scroll_up ] in
      assert (Poly.equal t.object_top (`Scroll (40 - capacity)));
      let filtered = apply t [ Text "39" ] in
      assert (filtered.object_index = 0 && Poly.equal filtered.object_top (`Follow 0));
      assert (List.length (objects filtered) = 1))
  ;;

  let%test_unit "hint choice changes idle help but keeps filters and messages" =
    let text hints t =
      snd (page ~hints t { width = 80; height = 24 })
      |> List.map ~f:(fun cell -> cell.text)
      |> String.concat ~sep:"\n"
    in
    List.iter [ true; false ] ~f:(fun hints ->
      let contains t substring = String.is_substring (text hints t) ~substring in
      assert (Bool.equal (contains state "[/ filter]") hints);
      assert (Bool.equal (contains state "Tab switch pane") hints);
      let editing = stay (input state (Character '/')) in
      assert (contains editing "Filter: ▏");
      let committed = finish_filter (stay (input editing (Text "39"))) in
      assert (contains committed "Filter: 39");
      assert (contains { committed with message = "Owner unavailable" } "Owner unavailable"))
  ;;

  let%test_unit "the first Esc after a filtered action returns to inspection" =
    let apply keys t = List.fold keys ~init:t ~f:(fun t key -> stay (input t key)) in
    let editing = apply [ H.Character '/'; Text "39" ] state in
    (match choose editing (Command 7) with
     | Invoke command ->
       let returned = commit editing command in
       assert (returned.command_index = 7 && Poly.equal returned.query (Some "39"));
       assert (Poly.equal (input returned Escape) Close)
     | _ -> assert false);
    let committed = stay (input editing Escape) in
    assert (List.length (objects committed) = 1);
    assert (Poly.equal (input committed Escape) Close);
    let actions = stay (input editing Focus) in
    assert (Poly.equal actions.query (Some "39"));
    match input actions Enter with
    | Invoke command -> assert (Poly.equal (input (commit actions command) Escape) Close)
    | _ -> assert false
  ;;
end
