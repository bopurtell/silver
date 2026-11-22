open! Core
open Bonsai_term
open Bonsai.Let_syntax
open Hardcaml_workbench_protocol

module Location = Terminal_presentation.Editor_location.Location
module Cobalt_location = Cobalt_hosted.Open_location
module Appearance = Terminal_presentation.Appearance
module Config = Silver_editor.Editor_config
module Theme = Silver_editor.Editor_theme

type project =
  { id : Project_id.t
  ; root : string
  }
[@@deriving equal]

type origin =
  { registry : Workspace.Session_id.t
  ; workspace : Workspace.Workspace_id.t
  }

type t =
  { mutable origin : origin option
  ; mutable key : int option
  ; mutable companion_focused : bool
  ; mutable pending : (unit ref * int * Location.t) option
  ; mutable intent : unit ref
  ; mutable prefix : Workspace.Tile_id.t option
  }

let create () =
  { origin = None; key = None; companion_focused = false
  ; pending = None; intent = ref (); prefix = None }
;;

let cancel t =
  t.intent <- ref ();
  t.pending <- None;
  t.prefix <- None
;;

let open_location t ~revision location =
  let token = ref () in
  t.intent <- token;
  t.pending <- Some (token, revision, location)
;;

let request ~(project : project) (location : Location.t) =
  if not (Project_id.equal project.id location.project)
  then Or_error.error_string "Source location belongs to a different project"
  else if Option.is_some location.source_identity
  then Or_error.error_string "Retained source identity cannot be verified against the working copy"
  else (
    match location.line, location.column with
    | None, Some _ -> Or_error.error_string "A source column requires a line"
    | line, column ->
      let position =
        Option.map line ~f:(fun line ->
          { Cobalt_location.line; column = Option.value column ~default:1 })
      in
      Ok { Cobalt_location.project_root = project.root; relative_file = location.relative_path; position })
;;

type mount =
  { key : int
  ; project : project
  ; startup : Cobalt_hosted.startup
  ; config : Config.t
  ; config_warning : Error.t option
  ; scheme : Appearance.Scheme.t Bonsai.Expert.Var.t
  ; commands : Cobalt_hosted.Host_command.t list Bonsai.Expert.Var.t
  ; mutable select_command : string -> unit Effect.t
  ; mutable command_generation : int
  }

type placement =
  { key : int
  ; bounds : Workspace.Geometry.t
  ; focused : bool
  }
[@@deriving equal]

type mounts =
  { registry : (int * mount Int.Map.t) Bonsai.Expert.Var.t
  ; selected : placement option Bonsai.Expert.Var.t
  }

let mounts () =
  { registry = Bonsai.Expert.Var.create (0, Int.Map.empty)
  ; selected = Bonsai.Expert.Var.create None
  }
;;

let binding mounts (owner : t) =
  let _, entries = Bonsai.Expert.Var.get mounts.registry in
  Option.bind owner.key ~f:(Map.find entries)
;;

let editor_config = lazy (Config.load ~getenv:Sys.getenv)

let mount mounts (owner : t) project =
  match binding mounts owner with
  | Some entry when equal_project project entry.project -> Ok entry
  | Some _ -> Or_error.error_string "Editor project identity changed"
  | None ->
    Or_error.map (Cobalt_hosted.open_project project.root) ~f:(fun startup ->
      let key, entries = Bonsai.Expert.Var.get mounts.registry in
      let config, config_warning = Lazy.force editor_config in
      let scheme = Bonsai.Expert.Var.create Appearance.default.scheme in
       let entry =
         { key; project; startup; config; config_warning; scheme
         ; commands = Bonsai.Expert.Var.create []
         ; select_command = (fun _ -> Effect.Ignore)
         ; command_generation = 0
         }
       in
      Bonsai.Expert.Var.set mounts.registry (key + 1, Map.set entries ~key ~data:entry);
      owner.key <- Some key;
      entry)
;;

let release mounts key editor =
  let%bind.Effect () = editor.Cobalt_hosted.shutdown () in
  Effect.of_thunk (fun () ->
    let count, entries = Bonsai.Expert.Var.get mounts.registry in
    Bonsai.Expert.Var.set mounts.registry (count, Map.remove entries key))
;;

let place ?appearance mounts placement =
  (* Appearance follows the selected editor's project and its palette preview.
     Hidden mounts keep their own scheme and allocation until selected again. *)
  (match appearance, placement with
   | Some (appearance : Appearance.t), Some pane ->
     let _, entries = Bonsai.Expert.Var.get mounts.registry in
     Option.iter (Map.find entries pane.key) ~f:(fun entry ->
       if not (Appearance.Scheme.equal (Bonsai.Expert.Var.get entry.scheme) appearance.scheme)
       then Bonsai.Expert.Var.set entry.scheme appearance.scheme)
   | _ -> ());
  if not (Option.equal equal_placement (Bonsai.Expert.Var.get mounts.selected) placement)
  then Bonsai.Expert.Var.set mounts.selected placement
;;

let component mounts (local_ graph) =
  let registry = Bonsai.Expert.Var.value mounts.registry in
  let entries = Bonsai.map registry ~f:snd in
  let selected = Bonsai.Expert.Var.value mounts.selected in
  (* A Cobalt startup handle is static, not a Bonsai value. Build one computation
     per new append-only slot with the static handle read when its branch is first
     activated. Neither switching projects nor hiding an editor deactivates it. *)
  let count = Bonsai.map registry ~f:fst in
  let rec slot key (local_ graph) =
    let present = Bonsai.map count ~f:(fun count -> key < count) in
    match%sub present with
    | false -> Bonsai.return Int.Map.empty
    | true ->
      Bonsai.delay ~f:(fun (local_ graph) ->
        let live = Bonsai.map entries ~f:(fun entries -> Map.mem entries key) in
        let surface =
          match%sub live with
          | false -> Bonsai.return None
          | true ->
            let _, current = Bonsai.Expert.Var.get mounts.registry in
            let entry = Map.find_exn current key in
            let placement =
              Bonsai.map selected ~f:(Option.filter ~f:(fun p -> p.key = key))
              |> Bonsai.cutoff ~equal:(Option.equal equal_placement)
            in
            let visible = Bonsai.map placement ~f:Option.is_some in
            let focused = Bonsai.map selected ~f:(function
              | Some p -> p.key = key && p.focused
              | _ -> false)
            in
            (* Keep the last positive allocation while hidden. Resizing Silver
               in another workspace must not resize or scroll this editor. *)
            let last = ref { Dimensions.width = 80; height = 24 } in
            let dimensions =
              let%arr placement in
              Option.iter placement ~f:(fun p ->
                last := { Dimensions.width = p.bounds.width; height = p.bounds.height });
              !last
            in
            let appearance =
              Bonsai.map (Bonsai.Expert.Var.value entry.scheme) ~f:(Theme.resolve entry.config)
              |> Bonsai.cutoff ~equal:Cobalt_hosted.Theme.equal
            in
            let pane =
              Cobalt_hosted.component ~layout:entry.config.layout ~appearance
                ~host_commands:(Bonsai.Expert.Var.value entry.commands)
                ~on_host_command:(Bonsai.return (fun id -> entry.select_command id))
                entry.startup ~dimensions ~visible ~focused graph
            in
            Bonsai.map pane ~f:Option.some
        in
        let remaining = slot (key + 1) graph in
        let%arr surface and remaining in
        Option.value_map surface ~default:remaining ~f:(fun data ->
          Map.set remaining ~key ~data))
        graph
  in
  slot 0 graph
;;

let shutdown editors exit =
  Map.fold editors ~init:(Effect.return ()) ~f:(fun ~key:_ ~data wait ->
    let%bind.Effect () = wait in
    data.Cobalt_hosted.shutdown ())
  |> Effect.bind ~f:exit
;;

let with_editors ~exit app (local_ graph) =
  let mounts = mounts () in
  let editors = component mounts graph in
  let mounted = ref Int.Map.empty in
  let exiting = ref false in
  let exit () =
    if !exiting then Effect.Ignore else (
      exiting := true;
      shutdown !mounted exit)
  in
  let selected = Bonsai.Expert.Var.value mounts.selected in
  let set_cursor = Effect.set_cursor graph in
  Bonsai.Edge.after_display
    (let%arr editors and selected and set_cursor in
     let cursor =
       Option.bind selected ~f:(fun pane ->
         Option.bind (Map.find editors pane.key) ~f:(fun editor ->
           Option.map editor.Cobalt_hosted.cursor ~f:(fun cursor ->
             { cursor with
               position =
                 { x = cursor.position.x + pane.bounds.x
                 ; y = cursor.position.y + pane.bounds.y
                 }
             })))
     in
     let%bind.Effect () = Effect.of_thunk (fun () -> mounted := editors) in
     set_cursor cursor)
    graph;
  app mounts editors ~exit graph
;;

let with_terminal_mode f =
  let fd = Core_unix.stdin in
  if not (Core_unix.isatty fd)
  then f ()
  else (
    let original = Core_unix.Terminal_io.tcgetattr fd in
    let set settings = Core_unix.Terminal_io.tcsetattr settings fd ~mode:TCSANOW in
    (* Keep physical Enter (CR) distinct from Cobalt's Ctrl-J binding (LF). *)
    set { original with c_icrnl = false; c_inlcr = false; c_igncr = false };
    Async.Monitor.protect f ~finally:(fun () ->
      set original;
      Async.return ()))
;;
