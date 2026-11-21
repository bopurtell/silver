open! Core
open Bonsai_term
module H = Workspace_host

type surface =
  | Workspace
  | Window

let trial () =
  match Sys.getenv "SILVER_PROJECT_BROWSER" with
  | Some "workspace" -> Some Workspace
  | Some "window" -> Some Window
  | Some "off" -> None
  | _ -> Some Workspace
;;

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

let catalog ~ip ~libraries (asic : Hardcaml_workbench_protocol.Asic.Snapshot.t option) =
  item "Project" "Project" [ ip ]
  :: (List.map libraries ~f:(fun (name, dir) ->
        item ("IP library: " ^ name) dir (H.library_authoring_commands dir))
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

type t =
  { surface : surface
  ; lifetime : unit ref
  ; message : string
  ; capture : H.capture
  ; items : item list
  ; region : region
  ; object_index : int
  ; command_index : int
  ; query : string option
  ; count : int
  ; pasting : bool
  }

let create surface capture items =
  { surface
  ; lifetime = ref ()
  ; message = ""
  ; capture
  ; items
  ; region = Objects
  ; object_index = 0
  ; command_index = 0
  ; query = None
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
  | Ok (Hardcaml_workbench_protocol.Authoring.Response.Owner_described desc) ->
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
    }
  | Error msg | Ok (Failed { message = msg; _ }) ->
    { t with message = Artifact_view.safe msg }
  | _ -> { t with message = "Unexpected catalog response" }
;;

let commands t = Option.value_map (selected t) ~default:[] ~f:(fun i -> i.commands)

type result =
  | Stay of t
  | Close
  | Invoke of H.command

type target =
  | Object of int
  | Command of int
  | Back
  | Switch_host

let choose t = function
  | Back -> Close
  | Switch_host ->
    Stay
      { t with
        surface =
          (match t.surface with
           | Workspace -> Window
           | Window -> Workspace)
      }
  | Object i ->
    Stay { t with object_index = i; command_index = 0; region = Objects; count = 0 }
  | Command i ->
    Option.value_map (List.nth (commands t) i) ~default:(Stay t) ~f:(fun c -> Invoke c)
;;

let input t (key : H.input) =
  let move delta =
    let next n len = Int.max 0 (Int.min (len - 1) (n + (delta * Int.max 1 t.count))) in
    match t.region with
    | Objects -> choose t (Object (next t.object_index (List.length (objects t))))
    | Commands ->
      Stay
        { t with
          command_index = next t.command_index (List.length (commands t))
        ; count = 0
        }
  in
  let query q =
    Stay { t with query = Some q; object_index = 0; command_index = 0; count = 0 }
  in
  let append q text =
    if String.length q + String.length text <= 512 then query (q ^ text) else Stay t
  in
  match key, t.query with
  | Paste_start, _ -> Stay { t with pasting = true }
  | Paste_end, _ -> Stay { t with pasting = false }
  | _, _ when t.pasting -> Stay t
  | Escape, Some _ ->
    Stay { t with query = None; object_index = 0; command_index = 0; region = Objects }
  | Escape, None -> Close
  | (Focus | Focus_previous), _ ->
    Stay
      { t with
        region =
          (match t.region with
           | Objects -> Commands
           | Commands -> Objects)
      ; count = 0
      }
  | Enter, _ when Poly.equal t.region Objects ->
    Stay { t with region = Commands; count = 0 }
  | Enter, _ -> choose t (Command t.command_index)
  | Character c, Some q when Poly.equal t.region Objects -> append q (String.of_char c)
  | Text s, Some q when Poly.equal t.region Objects -> append q s
  | Backspace, Some q -> query (Text_edit.apply Backspace q)
  | Delete_word, Some q -> query (Text_edit.delete_word q)
  | Clear_filter, Some _ -> query ""
  | Character '/', _ ->
    Stay { t with query = Some ""; region = Objects; object_index = 0; command_index = 0 }
  | Character ('0' .. '9' as ch), _ ->
    Stay { t with count = Int.min 9999 ((10 * t.count) + Char.to_int ch - 48) }
  | Character 'v', _ -> choose t Switch_host
  | (Character 'j' | Next), _ -> move 1
  | (Character 'k' | Previous), _ -> move (-1)
  | _ -> Stay t
;;

(* Paint and hit-test precisely the same page. The window leaves the left side of
   the *live* inspection exposed; the workspace occupies the full viewport. *)
let page t (d : Dimensions.t) =
  let width, height =
    match t.surface with
    | Workspace -> d.width, d.height
    | Window -> Int.min 42 d.width, Int.min 20 d.height
  in
  let x = d.width - width
  and y = (d.height - height) / 2 in
  let heading =
    match t.surface with
    | Workspace -> "Project workspace"
    | Window -> "Management window"
  in
  let plain s = s, None in
  let list_rows items index capacity f =
    let offset = Int.max 0 (index - capacity + 1) in
    List.take (List.drop items offset) capacity
    |> List.mapi ~f:(fun i item -> f (i + offset) item)
  in
  let region r = if Poly.equal t.region r then "▶ " else "  " in
  let marker i n = if i = n then " › " else "   " in
  let command_rows = commands t in
  let rows =
    [ plain ("▣ " ^ heading)
    ; "[Back to inspection]", Some Back
    ; ( (match t.surface with
         | Workspace -> "[Try window · v]"
         | Window -> "[Try workspace · v]")
      , Some Switch_host )
    ; plain
        (region Objects
         ^ "Objects"
         ^ Option.value_map t.query ~default:" · / filter" ~f:(sprintf " · Filter: %s▏"))
    ]
    @ list_rows
        (objects t)
        t.object_index
        (Int.max 1 (height - 8 - List.length command_rows))
        (fun i item -> marker i t.object_index ^ item.label, Some (Object i))
    @ [ plain
          ("For: "
           ^ Host_view.fit_label
               ~width:(Int.max 0 (width - 5))
               (Option.value_map (selected t) ~default:"(no match)" ~f:(fun i ->
                  i.destination)))
      ; plain (region Commands ^ "Commands")
      ]
    @ List.mapi command_rows ~f:(fun i c ->
      let title =
        String.substr_index c.H.title ~pattern:" · "
        |> Option.value_map ~default:c.title ~f:(String.prefix c.title)
      in
      marker i t.command_index ^ title, Some (Command i))
    @ [ plain
          (if String.is_empty t.message
           then "Tab regions · ↑↓/jk · Enter · Esc back"
           else t.message)
      ]
  in
  (x, y, width, height), rows
;;

let hit t d ~x ~y =
  let (left, top, width, height), rows = page t d in
  let col = x - left
  and row = y - top in
  if col < 0 || col >= width || row < 0 || row >= height
  then None
  else
    Option.bind (List.nth rows row) ~f:(fun (s, target) ->
      if col < View.width (View.text s) then target else None)
;;

let render t appearance d background =
  let (x, y, width, height), rows = page t d in
  let row role text =
    (* Paint the whole row, not just the glyphs. Otherwise the panel's
       contrasting surface color shows through at the end of each label. *)
    let attrs = Host_view.Role.attrs appearance role in
    let attrs =
      match role with
      | Selection -> attrs
      | _ -> attrs @ [ Attr.bg (Host_view.Role.backdrop appearance Foreground) ]
    in
    View.zcat [ View.text ~attrs text; View.rectangle ~attrs ~width ~height:1 () ]
  in
  let panel =
    List.mapi rows ~f:(fun index (s, target) ->
      let role : Host_view.Role.t =
        match target with
        | Some (Object i) when i = t.object_index && Poly.equal t.region Objects -> Selection
        | Some (Command i) when i = t.command_index && Poly.equal t.region Commands ->
          Selection
        | None when index = 0 || String.is_prefix s ~prefix:"▶" -> Heading
        | None -> Muted
        | _ -> Foreground
      in
      row role s)
    |> View.vcat
    |> Palette_view.box ~width ~height
  in
  let panel = Host_view.colored appearance Foreground panel in
  Palette_view.overlay ~background ~panel { x; y; width; height }
;;
