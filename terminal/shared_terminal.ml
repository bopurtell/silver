open! Core
open! Async
open Bonsai_term

module Pool = Cobalt_terminal_pool
module Model = Pool.Model

type phase =
  | Starting
  | Running
  | Exited of string
  | Failed of string

type shell =
  { id : int
  ; number : int
  ; cwd : string
  ; mutable generation : int
  ; mutable phase : phase
  ; mutable snapshot : Model.snapshot option
  ; mutable notice : string option
  ; mutable size : (int * int) option
  }

type project =
  { mutable recent : int
  ; shells : shell Int.Table.t
  }

type paste =
  { shell : shell
  ; generation : int
  ; bytes : Buffer.t
  ; mutable overflow : bool
  }

type placement =
  [ `Bottom
  | `Center
  ]

type geometry =
  { x : int
  ; y : int
  ; dimensions : Dimensions.t
  }

type t =
  { pool : Pool.t
  ; revision : int Bonsai.Expert.Var.t
  ; projects : project String.Table.t
  ; by_id : shell Int.Table.t
  ; mutable selected : shell option
  ; mutable placement : placement
  ; mutable dimensions : Dimensions.t
  ; mutable paste : paste option option
  ; mutable closed : bool
  }

let changed t = Bonsai.Expert.Var.update t.revision ~f:Int.succ
let revision t = Bonsai.Expert.Var.value t.revision
let selected t shell = Option.exists t.selected ~f:(phys_equal shell)

let accept (shell : shell) generation (event : Model.event) =
  if generation <> shell.generation
  then false
  else (
    (match event with
     | Snapshot snapshot ->
       shell.snapshot <- Some snapshot;
       shell.phase
       <- (match snapshot.exited with
           | None -> Running
           | Some status -> Exited status)
     | Failed message ->
       (match shell.phase with
        | Starting -> shell.phase <- Failed message
        | Running | Exited _ | Failed _ -> shell.notice <- Some message));
    true)
;;

let create () =
  let t =
    { pool = Pool.create ()
    ; revision = Bonsai.Expert.Var.create 0
    ; projects = String.Table.create ()
    ; by_id = Int.Table.create ()
    ; selected = None
    ; placement = `Bottom
    ; dimensions = { width = 80; height = 24 }
    ; paste = None
    ; closed = false
    }
  in
  (* A single consumer owns the latest screen for every shell. This loop is
     independent of the visible overlay and of workspace mount lifetimes. *)
  let rec drain () =
    match%bind Pool.next_update t.pool with
    | None -> return ()
    | Some (id, generation, event) ->
      Option.iter (Hashtbl.find t.by_id id) ~f:(fun shell ->
        if accept shell generation event && selected t shell then changed t);
      let%bind () = Scheduler.yield () in
      drain ()
  in
  don't_wait_for (drain ());
  t
;;

let placement t = t.placement

let floating_extent viewport_extent =
  if viewport_extent < 4
  then viewport_extent
  else viewport_extent - Int.max 2 (viewport_extent / 4)
;;

let geometry t ~dimensions:({ width; height } : Dimensions.t) =
  let width = Int.max 0 width in
  let height = Int.max 0 height in
  let tile_width, tile_height =
    match t.placement with
    | `Bottom ->
      (* Keep the workspace strip visible except on small screens. *)
      let top = if height < 10 then 0 else height / 3 in
      width, height - top
    | `Center -> floating_extent width, floating_extent height
  in
  (* Limit the visible grid as well as the PTY so their sizes agree even on unusually
     large terminal emulators. *)
  let tile_width = Int.min 1000 tile_width in
  let max_rows = Int.min 500 (250_000 / Int.max 1 tile_width) in
  let tile_height = Int.min (max_rows + Shared_terminal_view.header_rows) tile_height in
  let x, y =
    match t.placement with
    | `Bottom -> 0, height - tile_height
    | `Center -> (width - tile_width) / 2, (height - tile_height) / 2
  in
  { x; y; dimensions = { width = tile_width; height = tile_height } }
;;

let contains ({ x; y; dimensions = { width; height } } : geometry) ~x:col ~y:row =
  col >= x && col < x + width && row >= y && row < y + height
;;

let pty_size t =
  let ({ dimensions = { width; height }; _ } : geometry) =
    geometry t ~dimensions:t.dimensions
  in
  (* A header-only tile (or an empty viewport) has no drawable grid, but the PTY still
     needs positive dimensions. *)
  let rows = Int.max 1 (height - Shared_terminal_view.header_rows) in
  let cols = Int.max 1 width in
  rows, cols
;;

let submit t (shell : shell) request = Pool.submit t.pool [ shell.id, request ]

let start t (shell : shell) =
  let rows, cols = pty_size t in
  shell.phase <- Starting;
  shell.generation <- shell.generation + 1;
  shell.snapshot <- None;
  shell.notice <- None;
  shell.size <- Some (rows, cols);
  submit t shell (Start { cwd = shell.cwd; rows; cols })
;;

let live (shell : shell) =
  match shell.phase with
  | Starting | Running -> true
  | Exited _ | Failed _ -> false
;;

let resize_selected t (shell : shell) =
  let rows, cols = pty_size t in
  let same_size = Option.exists shell.size ~f:(fun (r, c) -> r = rows && c = cols) in
  if live shell && not same_size
  then (
    shell.size <- Some (rows, cols);
    submit t shell (Resize { rows; cols }))
;;

let resize t ~dimensions =
  t.dimensions <- dimensions;
  Option.iter t.selected ~f:(resize_selected t)
;;

let set_placement t placement =
  if (not t.closed) && not (Poly.equal t.placement placement)
  then (
    t.placement <- placement;
    Option.iter t.selected ~f:(resize_selected t);
    changed t)
;;

let is_visible t = Option.is_some t.selected
let is_pasting t = Option.is_some t.paste

let cancel_paste t =
  (* Still swallow the rest of the bracketed paste if the host hides or switches
     the overlay programmatically before the end marker. *)
  if is_pasting t then t.paste <- Some None
;;

let hide t =
  if is_visible t
  then (
    cancel_paste t;
    t.selected <- None;
    changed t)
;;

let toggle t ~project_root ~number ~dimensions =
  if not (t.closed || Filename.is_relative project_root)
     && Option.for_all number ~f:(fun n -> n > 0)
  then (
    let project =
      Hashtbl.find_or_add t.projects project_root ~default:(fun () ->
        { recent = 1; shells = Int.Table.create () })
    in
    let number = Option.value number ~default:project.recent in
    project.recent <- number;
    match Hashtbl.find project.shells number with
    | Some shell when selected t shell -> hide t
    | shell ->
      cancel_paste t;
      t.dimensions <- dimensions;
      let shell =
         match shell with
         | Some shell ->
           (* Reopening an exited number is a new user intent, not a request to
              focus the retained exit screen. Starting remains live so repeated
              selections cannot enqueue competing Starts during launch. *)
           if live shell then resize_selected t shell else start t shell;
           shell
        | None ->
          (* Cobalt's keyspace is global to one pool; these private IDs namespace
             the user-visible number by project without allocating a range. *)
          let id = Hashtbl.length t.by_id + 1 in
          let shell =
            { id
            ; number
            ; cwd = project_root
            ; generation = 0
            ; phase = Starting
            ; snapshot = None
            ; notice = None
            ; size = None
            }
          in
          Hashtbl.set project.shells ~key:number ~data:shell;
          Hashtbl.set t.by_id ~key:id ~data:shell;
          start t shell;
          shell
      in
      t.selected <- Some shell;
      changed t)
;;

let restart t =
  Option.iter t.selected ~f:(fun shell ->
    if not (live shell)
    then (
      cancel_paste t;
      start t shell;
      changed t))
;;

let restartable t = Option.exists t.selected ~f:(fun shell -> not (live shell))

let key (key : Event.Key.t) mods : Model.key =
  let has modifier = List.mem mods modifier ~equal:Event.Modifier.equal in
  let code : Model.key_code =
    match key with
    | ASCII c -> Char (Uchar.of_char c)
    | Uchar u -> Char u
    | Escape -> Escape
    | Enter -> Char (Uchar.of_char 'j')
    | Tab -> Tab
    | Backspace -> Backspace
    | Insert -> Insert
    | Delete -> Delete
    | Home -> Home
    | End -> End
    | Arrow `Up -> Up
    | Arrow `Down -> Down
    | Arrow `Left -> Left
    | Arrow `Right -> Right
    | Page `Up -> Page_up
    | Page `Down -> Page_down
    | Function n -> Function n
  in
  (* Notty decodes literal LF as [Enter]; physical Enter can arrive as
     Ctrl-M. Preserve both forms, as standalone Cobalt does. *)
  { code
  ; modifiers =
      { alt = has Meta; shift = has Shift; ctrl = has Ctrl || Event.Key.equal key Enter }
  }
;;

let paste_text ({ code; modifiers } : Model.key) =
  match code with
  | Tab when not (modifiers.ctrl || modifiers.alt) -> "\t"
  | Char u when not modifiers.alt ->
    (match Uchar.to_scalar u with
     | (77 | 109) when modifiers.ctrl -> "\r"
     | (74 | 106) when modifiers.ctrl -> "\n"
     | (73 | 105) when modifiers.ctrl -> "\t"
     | c
       when not modifiers.ctrl
            && (c = 9 || c = 10 || c = 13 || (c >= 32 && (c < 127 || c > 159))) ->
       Uchar.Utf8.to_string u
     | _ -> "")
  | _ -> ""
;;

let collect paste text =
  (* Leave room in Cobalt's input budget for bracketed-paste delimiters.
     Drop the entire paste on overflow, not just its suffix. *)
  let limit = (1024 * 1024) - 12 in
  if not paste.overflow
  then
    if String.length text > limit - Buffer.length paste.bytes
    then (
      Buffer.clear paste.bytes;
      paste.overflow <- true)
    else Buffer.add_string paste.bytes text
;;

let input t (event : Event.t) =
  match event, t.paste with
  | Mouse _, _ | Paste `Start, Some _ | Paste `End, None -> ()
  | Paste `Start, None ->
    if is_visible t
    then
      t.paste
      <- Some
           (Option.filter t.selected ~f:live
            |> Option.map ~f:(fun shell ->
              { shell; generation = shell.generation; bytes = Buffer.create 128; overflow = false }))
  | Key_press { key = pressed; mods }, Some paste ->
    Option.iter paste ~f:(fun paste -> collect paste (paste_text (key pressed mods)))
  | Paste `End, Some paste ->
    t.paste <- None;
    Option.iter paste ~f:(fun { shell; generation; bytes; overflow } ->
      if selected t shell && shell.generation = generation && live shell
      then
        if overflow
        then (
          shell.notice <- Some "Paste exceeds 1 MiB";
          changed t)
        else if Buffer.length bytes > 0
        then submit t shell (Paste (Buffer.contents bytes)))
  | Key_press { key = pressed; mods }, None ->
    Option.iter t.selected ~f:(fun shell ->
      if live shell then submit t shell (Key (key pressed mods)))
;;

let render t ~dimensions =
  Option.map t.selected ~f:(fun shell ->
    let ({ dimensions; _ } : geometry) = geometry t ~dimensions in
    let status =
      match shell.phase, shell.notice with
      | Starting, _ -> "Starting…"
      | Running, None -> "Running"
      | Running, Some notice -> "Warning: " ^ notice
      | Exited status, notice ->
         let status = sprintf "%s (reopen or F12 restart)" (String.capitalize status) in
        Option.value_map notice ~default:status ~f:(fun notice -> status ^ " · " ^ notice)
       | Failed error, _ -> "Failed (reopen or F12 restart): " ^ error
    in
    Shared_terminal_view.render
      ~number:shell.number
      ~cwd:shell.cwd
      ~status
      ~snapshot:shell.snapshot
      ~dimensions)
;;

let shutdown t =
  if not t.closed
  then (
    t.closed <- true;
    hide t;
    t.paste <- None;
    Hashtbl.clear t.projects;
    Hashtbl.clear t.by_id);
  Pool.shutdown t.pool
;;
