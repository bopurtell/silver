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
  | Name of string
  | Destination of string * string
  | Existing of string
  | Review of Authoring.Preview.t
  | Failure of string list
  | Busy of string

let contents = function
  | Closed -> assert false
  | Menu ->
    ( "Local project"
    , [ "[c] New Project… (Create project here)"; "[o] Open existing project" ]
    , "Esc dismiss" )
  | Name s -> "Project name", [ s ^ "▏" ], "Enter continue   Esc dismiss"
  | Destination (name, s) ->
    ( "Destination"
    , [ "Project: " ^ name; "Blank uses the current directory."; s ^ "▏" ]
    , "Enter preview   Esc dismiss" )
  | Existing s -> "Existing project directory", [ s ^ "▏" ], "Enter open   Esc dismiss"
  | Review p ->
    ( "Create preview"
    , ("First registered chip target (default): " ^ p.operation.name)
      :: Host.starter_preview_lines ~source:Example p
    , "Enter: Apply and open   ↑↓ scroll   Esc cancel" )
  | Failure rows -> "Project error", rows, "↑↓ scroll   Enter retry   Esc dismiss"
  | Busy label -> "Local project", [ label ], "Please wait"
;;

let layout { Dimensions.width; height } rows =
  let width = Int.min width (Int.max 32 (Int.min 100 (width - 4))) in
  let rows = List.concat_map rows ~f:(Style.wrap_cells ~width:(Int.max 1 (width - 4))) in
  let height = Int.min height (Int.max 6 (Int.min (height - 4) (List.length rows + 4))) in
  let geometry =
    Panel.geometry ~framed:true ~width ~height ~horizontal_padding:1 ~vertical_padding:0
  in
  let body_height = Int.max 1 (geometry.content_height - 1) in
  let last = Int.max 0 (List.length rows - body_height) in
  width, height, geometry, body_height, rows, last
;;

let render ~start screen scroll ({ Dimensions.width; height } as dimensions) =
  let appearance = Appearance.default in
  let text role s = View.text ~attrs:(Style.Role.attrs appearance role) s in
  let base =
    Style.box
      ~width
      ~height
      (View.vcat
         [ text Heading "Silver  /  Unbound workspace"
         ; text Muted ("Directory: " ^ start)
         ; text Foreground "No Dune project is open."
         ; text Focus "[p] Create or open project   [q] Quit"
         ])
    |> Style.colored appearance Background
  in
  match screen with
  | Closed -> base
  | _ ->
    let title, rows, footer = contents screen in
    let width, height, geometry, body_height, rows, last = layout dimensions rows in
    let offset =
      match screen with
      | Name _ | Destination _ | Existing _ -> last
      | _ -> Int.min scroll last
    in
    let body =
      List.drop rows offset
      |> Fn.flip List.take body_height
      |> List.map ~f:(text Foreground)
      |> View.vcat
      |> Style.box ~width:geometry.content_width ~height:body_height
    in
    let modal =
      Panel.render
        Appearance.default
        ~attrs:(Style.Role.attrs appearance Border)
        ~title:(text Heading title)
        ~geometry
        ~width
        ~height
        (View.vcat [ body; text Focus footer ])
      |> Style.colored appearance Surface
    in
    View.zcat [ View.center modal ~within:dimensions; base ]
;;

(* No daemon or project state exists in this branch. Only the preview service, scoped to
   the launch directory, survives between form steps. *)
let component ~start ~on_open ~exit ~dimensions (local_ graph) =
  let service = lazy (Service.create ~permitted_roots:[ start ]) in
  let call req = Service.handle (Lazy.force service) req in
  let screen = ref Menu
  and scroll = ref 0
  and pasted = ref false in
  let revision, update = Bonsai.state' 0 graph in
  let view =
    Bonsai.map2 dimensions revision ~f:(fun dims _ -> render ~start !screen !scroll dims)
  in
  let handler =
    Bonsai.map3 update on_open dimensions ~f:(fun update on_open dimensions event ->
      let refresh () = update Int.succ in
      let show next =
        screen := next;
        scroll := 0;
        refresh ()
      in
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
        match Host.decode_event event, !screen with
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
        | Some Escape, Review p ->
          (match call (Cancel { preview_id = p.preview_id }) with
           | Cancelled -> show Closed
           | Failed f -> failure f
           | _ -> fail "Unexpected cancel response")
        | Some Escape, _ -> show Closed
        | Some (Character 'q'), Closed -> exit ()
        | Some (Character 'p'), Closed | Some Enter, Failure _ -> show Menu
        | Some (Character 'c'), Menu -> show (Name "")
        | Some (Character 'o'), Menu -> show (Existing "")
        | Some Enter, Name s when not (String.is_empty (String.strip s)) ->
          show (Destination (String.strip s, ""))
        | Some Enter, Existing s when not (String.is_empty (String.strip s)) ->
          open_root (path s)
        | Some Enter, Destination (name, s) ->
          let target : Authoring.Target.t =
            { destination = path s; project = None; object_id = None }
          in
          work
            "Preparing preview…"
            (fun () -> call (Preview { recipe = Authoring.starter_recipe; name; target }))
            (function
              | Previewed p -> show (Review p)
              | Failed f -> failure f
              | _ -> fail "Unexpected preview response")
        | Some Enter, Review p ->
          work
            "Creating project…"
            (fun () -> call (Apply { preview_id = p.preview_id }))
            (function
              | Applied _ -> open_root p.operation.target.destination
              | Failed f -> failure f
              | _ -> fail "Unexpected apply response")
        | Some Next, (Review _ | Failure _) ->
          let _, rows, _ = contents !screen in
          let _, _, _, _, _, last = layout dimensions rows in
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
