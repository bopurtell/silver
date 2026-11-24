open! Core
open Async
open Bonsai_term
module Discovery = Hardcaml_workbench_setup.Project_discovery
module Authoring = Hardcaml_workbench_protocol.Authoring
module Service = Hardcaml_workbench_backend.Authoring_service
module Host = Terminal_presentation.Workspace_host
module Style = Terminal_presentation.Host_view
module Panel = Terminal_presentation.Panel
module Appearance = Terminal_presentation.Appearance

let resolve ~interactive ~explicit ~discover =
  let explicit_flag = "--project-root" in
  if interactive && discover && Option.is_none explicit
  then (
    let%map.Result result = Discovery.search ~explicit_flag () in
    match result with
    | `Found root -> `Open (Some root.root, Some (Discovery.describe root ~explicit_flag))
    | `Missing (start, _) -> `Unbound start)
  else
    Discovery.resolve
      ~explicit
      ~discover
      ~explicit_flag
      ~discover_flag:"--discover-project"
    |> Result.map ~f:(fun result -> `Open result)
;;

type screen =
  | Closed
  | Menu
  | Share_unbound of screen * Share_wizard.t
  | Name of string
  | Destination of string * string
  | Existing of string
  | Review of Authoring.Preview.t
  | Failure of string list
  | Busy of string

(* The label and its binding travel together through wrapping and clipping. *)
let reopen = "[p] Create or open project", Host.Character 'p'
let quit = "[q] Quit", Host.Character 'q'
let dismiss = "Esc dismiss", Host.Escape
let share = "[s] " ^ Share_wizard.title, Host.Character 's'
let controls_text controls = String.concat ~sep:"   " (List.map controls ~f:fst)
let plain rows = List.map rows ~f:(fun s -> s, None)

let contents ~bound = function
  | Closed | Share_unbound _ -> assert false
  | Menu ->
    ( "Local project"
    , [ "[c] New Project… (Create project here)", Some (Host.Character 'c')
      ; "[o] Open existing project", Some (Host.Character 'o')
      ; "Classic Bluespec starter: run `silver init --bluespec` in an empty directory.", None
      ]
    , (if bound then [ dismiss ] else [ share; dismiss ]) )
  | Name s -> "Project name", plain [ s ^ "▏" ], [ "Enter continue", Host.Enter; dismiss ]
  | Destination (name, s) ->
    ( "Destination"
    , plain
        [ "Project: " ^ name
        ; (if bound then "Blank creates a sibling named " ^ name ^ "."
           else "Blank uses the current directory.")
        ; s ^ "▏"
        ]
    , [ "Enter preview", Host.Enter; dismiss ] )
  | Existing s ->
    "Existing project directory", plain [ s ^ "▏" ], [ "Enter open", Host.Enter; dismiss ]
  | Review p ->
    ( "Create preview"
    , plain
        (("First registered chip target (default): " ^ p.operation.name)
         :: Host.starter_preview_lines ~source:Example p)
    , [ "Enter: Apply and open", Host.Enter
      ; "↑", Previous
      ; "↓", Next
      ; "Esc cancel", Escape
      ] )
  | Failure rows ->
    ( "Project error"
    , plain rows
    , [ "Enter retry", Host.Enter; "↑", Previous; "↓", Next; dismiss ] )
  | Busy label -> "Local project", plain [ label; "Please wait" ], []
;;

let control_lines ~width controls =
  let lines, line, _ =
    List.fold
      controls
      ~init:([], [], 0)
      ~f:(fun (lines, line, used) ((label, _) as item) ->
        let size = View.width (View.text label) in
        match line with
        | [] -> lines, [ item ], size
        | _ when used + 3 + size <= width -> lines, item :: line, used + 3 + size
        | _ -> List.rev line :: lines, [ item ], size)
  in
  if List.is_empty line then [] else List.rev (List.rev line :: lines)
;;

let layout { Dimensions.width; height } rows footer =
  let width = Int.min width (Int.max 32 (Int.min 100 (width - 4))) in
  let content_width = Int.max 1 (width - 4) in
  let footer = control_lines ~width:content_width footer in
  let rows =
    List.concat_map rows ~f:(fun (s, action) ->
      List.map (Style.wrap_cells ~width:content_width s) ~f:(fun row -> row, action))
  in
  let height =
    Int.min
      height
      (Int.max 6 (Int.min (height - 4) (List.length rows + List.length footer + 3)))
  in
  let geometry =
    Panel.geometry ~framed:true ~width ~height ~horizontal_padding:1 ~vertical_padding:0
  in
  let body_height = Int.max 1 (geometry.content_height - List.length footer) in
  let last = Int.max 0 (List.length rows - body_height) in
  width, height, geometry, body_height, rows, last, footer
;;

let rec render ~start ~original screen scroll ({ Dimensions.width; height } as dimensions) =
  let hits = ref [] in
  let add ~x ~y ~clip label action =
    let right = Int.min clip (x + View.width (View.text label)) in
    if y >= 0 && y < height && right > x then hits := (x, right, y, action) :: !hits
  in
  let controls ~x ~y ~clip items =
    ignore
      (List.fold items ~init:x ~f:(fun x (label, action) ->
         add ~x ~y ~clip label action;
         x + View.width (View.text label) + 3)
       : int)
  in
  let appearance = Appearance.default in
  let text role s = View.text ~attrs:(Style.Role.attrs appearance role) s in
  let base =
    Style.box
      ~width
      ~height
      (View.vcat
         (match original with
          | None ->
            [ text Heading "Silver  /  Unbound workspace"
            ; text Muted ("Directory: " ^ start)
            ; text Foreground "No project is open."
            ; text Focus (controls_text [ reopen; share; quit ])
            ]
          | Some root ->
            [ text Heading "Silver  /  Project switch"
            ; text Muted ("Current project: " ^ root)
            ; text Foreground ("Relative paths start at: " ^ start)
            ]))
    |> Style.colored appearance Background
  in
  match screen with
  | Closed ->
    controls ~x:0 ~y:3 ~clip:width [ reopen; share; quit ];
    base, !hits, None
  | Share_unbound (previous, wizard) ->
    let background, _, _ = render ~start ~original previous 0 dimensions in
    Share_wizard.render wizard ~sharing:false appearance dimensions background, [], None
  | _ ->
    let title, rows, footer = contents ~bound:(Option.is_some original) screen in
    let width, height, geometry, body_height, rows, last, footer =
      layout dimensions rows footer
    in
    let left = (dimensions.width - width) / 2 in
    let top = (dimensions.height - height) / 2 in
    let x = left + geometry.border + geometry.horizontal_padding in
    let y = top + geometry.border + geometry.vertical_padding in
    let clip = x + geometry.content_width in
    let offset =
      match screen with
      | Name _ | Destination _ | Existing _ -> last
      | _ -> Int.min scroll last
    in
    let body =
      List.drop rows offset
      |> Fn.flip List.take body_height
      |> List.mapi ~f:(fun i (label, action) ->
        if i < geometry.content_height
        then Option.iter action ~f:(add ~x ~y:(y + i) ~clip label);
        text Foreground label)
      |> View.vcat
      |> Style.box ~width:geometry.content_width ~height:body_height
    in
    let footer =
      List.mapi footer ~f:(fun i items ->
        if body_height + i < geometry.content_height
        then controls ~x ~y:(y + body_height + i) ~clip items;
        text Focus (controls_text items))
    in
    let modal =
      Panel.render
        Appearance.default
        ~attrs:(Style.Role.attrs appearance Border)
        ~title:(text Heading title)
        ~geometry
        ~width
        ~height
        (View.vcat (body :: footer))
      |> Style.colored appearance Surface
    in
    ( View.zcat [ View.center modal ~within:dimensions; base ]
    , !hits
    , Some (left, top, width, height) )
;;

(* Per-invocation state: re-entering the chooser never revives a previous form or
   preview receipt. No project service is started until Open or Apply succeeds. *)
type entry =
  { start : string
  ; original : string option
  ; initial : screen
  ; service : Service.t Lazy.t
  ; screen : screen ref
  ; scroll : int ref
  ; pasted : bool ref
  }

let entry ?original ~start initial =
  { start; original; initial; service = lazy (Service.create ~permitted_roots:[ start ])
  ; screen = ref initial; scroll = ref 0; pasted = ref false }
;;

let component ~no_mouse ~entry ~on_open ~on_cancel ~exit ~dimensions (local_ graph) =
  let revision, update = Bonsai.state' 0 graph in
  let frame =
    Bonsai.map3 entry dimensions revision ~f:(fun entry dims _ ->
      let { start; original; screen; scroll; _ } = entry in
      let view, hits, bounds = render ~start ~original !screen !scroll dims in
      view, (entry, !screen, !scroll, hits, bounds, dims))
  in
  let view = Bonsai.map frame ~f:fst in
  let handler =
    Bonsai.map3
      update
      (Bonsai.both on_open on_cancel)
      (Bonsai.map frame ~f:snd)
      ~f:(fun update (on_open, on_cancel) (entry, shown, offset, hits, bounds, dimensions) event ->
        let { start; original; initial; service; screen; scroll; pasted } = entry in
        let bound = Option.is_some original in
        let call req = Service.handle (Lazy.force service) req in
        let refresh () = update Int.succ in
        let show next =
          screen := next;
          scroll := 0;
          refresh ()
        in
        let cancel () = if bound then on_cancel () else show Closed in
        let path s =
          let s = String.strip s in
          if String.is_empty s || String.equal s "."
          then start
          else if Filename.is_relative s
          then Filename.concat start s
          else s
        in
        let fail msg = show (Failure (String.split_lines msg)) in
        let failure (f : Authoring.Failure.t) =
          show
            (Failure
               ((Sexp.to_string (Authoring.Failure.sexp_of_kind f.kind) ^ ": " ^ f.message)
                :: List.map f.created_files ~f:(fun p -> "Already created: " ^ p)))
        in
        let work label f finish =
          Effect.Many
            [ show (Busy label)
            ; Effect.bind
                (Effect.of_deferred_thunk (fun () ->
                   Monitor.try_with_or_error (fun () -> In_thread.run f)))
                ~f:(function
                  | Error e -> fail (Error.to_string_hum e)
                  | Ok r -> finish r)
            ]
        in
        let open_root root =
          work
            "Opening project…"
            (fun () -> Discovery.explicit_root root)
            (function
              | Error msg -> fail msg
              | Ok root ->
                Effect.bind (on_open root) ~f:(function
                  | Ok () -> Effect.Ignore
                  | Error e -> fail (Error.to_string_hum e)))
        in
        let edit f =
          match !screen with
          | Name s -> show (Name (f s))
          | Destination (n, s) -> show (Destination (n, f s))
          | Existing s -> show (Existing (f s))
          | _ -> Effect.Ignore
        in
        let append s =
          edit (fun value ->
            if String.length value + String.length s <= 4096 then value ^ s else value)
        in
        if Host.is_interrupt event
        then exit ()
        else (
          let input =
            match event with
            | Event.Mouse { mods = []; kind; position = { x; y } }
              when (not no_mouse)
                   && (not !pasted)
                   && phys_equal shown !screen
                   && offset = !scroll ->
              (match kind with
               | Left ->
                 List.find_map hits ~f:(fun (l, r, row, action) ->
                   Option.some_if (y = row && x >= l && x < r) action)
               | Scroll dir
                 when Option.exists bounds ~f:(fun (l, t, w, h) ->
                        x >= l && x < l + w && y >= t && y < t + h) ->
                 Some
                   (match dir with
                    | `Up -> Host.Previous
                    | `Down -> Next)
               | _ -> None)
            | _ -> Host.decode_event event
          in
          match input, !screen with
          | Some Paste_start, _ ->
            pasted := true;
            Effect.Ignore
          | Some Paste_end, _ ->
            pasted := false;
            Effect.Ignore
          | Some (Character c), _ when !pasted -> append (String.of_char c)
          | Some (Text s), _ -> append s
          | _, _ when !pasted -> Effect.Ignore
          | _, Busy _ -> Effect.Ignore
          | Some key, Share_unbound (previous, wizard) ->
            (match Share_wizard.input wizard ~sharing:false key with
             | Stay wizard -> show (Share_unbound (previous, wizard))
             | Dismiss -> show previous
             | Share _ | Stop -> Effect.Ignore)
          | Some (Character 's'), (Menu | Closed) when not bound ->
            show (Share_unbound (!screen, Share_wizard.create None))
          | Some Escape, Review p ->
            (match call (Cancel { preview_id = p.preview_id }) with
             | Cancelled -> cancel ()
             | Failed f -> failure f
             | _ -> fail "Unexpected cancel response")
          | Some Escape, _ -> cancel ()
          | Some (Character 'q'), Closed -> exit ()
          | Some (Character 'p'), Closed | Some Enter, Failure _ -> show initial
          | Some (Character 'c'), Menu -> show (Name "")
          | Some (Character 'o'), Menu -> show (Existing "")
          | Some Enter, Name s when not (String.is_empty (String.strip s)) ->
            show (Destination (String.strip s, ""))
          | Some Enter, Existing s when not (String.is_empty (String.strip s)) ->
            open_root (path s)
          | Some Enter, Destination (name, s) ->
            let destination =
              path (if bound && String.is_empty (String.strip s) then name else s)
            in
            (* Match path components like the authoring service, including repeated
               slashes. The service rejects dot components and symlink traversal. *)
            let parts p =
              String.split ~on:'/' p |> List.filter ~f:(Fn.non String.is_empty)
            in
            if Option.exists original ~f:(fun root ->
                 List.is_prefix (parts destination) ~prefix:(parts root) ~equal:String.equal)
            then fail "Choose a destination outside the current project."
            else (
              let target : Authoring.Target.t =
                { destination; project = None; object_id = None }
              in
              work
                "Preparing preview…"
                (fun () ->
                  call (Preview { recipe = Authoring.starter_recipe; name; target }))
                (function
                  | Previewed p -> show (Review p)
                  | Failed f -> failure f
                  | _ -> fail "Unexpected preview response"))
          | Some Enter, Review p ->
            work
              "Creating project…"
              (fun () -> call (Apply { preview_id = p.preview_id }))
              (function
                | Applied _ -> open_root p.operation.target.destination
                | Failed f -> failure f
                | _ -> fail "Unexpected apply response")
          | Some Next, (Review _ | Failure _) ->
            let _, rows, footer = contents ~bound !screen in
            let _, _, _, _, _, last, _ = layout dimensions rows footer in
            scroll := Int.min last (!scroll + 1);
            refresh ()
          | Some Previous, (Review _ | Failure _) ->
            scroll := Int.max 0 (!scroll - 1);
            refresh ()
          | Some Backspace, _ -> edit Terminal_presentation.Text_edit.drop_character
          | Some Delete_word, _ -> edit Terminal_presentation.Text_edit.delete_word
          | Some (Character c), _ -> append (String.of_char c)
          | _ -> Effect.Ignore))
  in
  ~view, ~handler
;;
