open! Core
open Hardcaml_workbench_protocol
open Bonsai_term
module H = Workspace_host
module W = Workspace
module T = Tile_presentation
module E = Evidence_style
module P = Hardcaml_workbench_workspaces

module Role = struct
  type t =
    | Background
    | Foreground
    | Surface
    | Muted
    | Border
    | Focus
    | Selection
    | Running
    | Success
    | Warning
    | Failure
    | Metric
    | Active_tab
    | Inactive_tab
    | Matched
    | Heading

  let rgb r g b = Attr.Color.rgb ~r ~g ~b

  let color n =
    let r, g, b = Theme_catalog.channels n in
    rgb r g b
  ;;

  let backdrop (appearance : Appearance.t) role =
    let p = Appearance.Scheme.palette appearance.scheme in
    color
      (match role with
       | Selection | Active_tab -> p.selection
       | Surface | Matched -> p.surface
       | Foreground ->
         (match appearance.preset with
          | Studio | Structured_studio -> p.card
          | _ -> p.background)
       | _ -> p.background)
  ;;

  let foreground (appearance : Appearance.t) role =
    let p = Appearance.Scheme.palette appearance.scheme in
    let accent =
      match appearance.color with
      | Restrained -> p.foreground
      | Selective -> p.selective
      | Vivid -> p.accent
    in
    color
      (match role with
       | Muted | Inactive_tab -> p.muted
       | Border ->
         (match appearance.color with
          | Vivid -> p.border
          | _ -> p.muted)
       | Focus | Selection | Active_tab | Running -> accent
       | Metric | Matched ->
         (match appearance.color with
          | Vivid -> p.metric
          | _ -> p.foreground)
       | Success -> p.success
       | Warning -> p.warning
       | Failure -> p.failure
       | Heading -> p.heading
       | _ -> p.foreground)
  ;;

  let attrs (appearance : Appearance.t) role =
    let fg = foreground appearance role in
    let bg = backdrop appearance role in
    [ Attr.fg fg; Attr.bg bg ]
    @
    match role with
    | Matched -> [ Attr.underline; Attr.bold ]
    | Focus | Selection | Metric | Active_tab | Heading -> [ Attr.bold ]
    | _ -> []
  ;;
end

(** Clip the actual terminal image, not UTF-8 bytes. Notty/Bonsai measure display cells,
    including wide and combining characters, before clipping. *)
let box ~width ~height view =
  let width = Int.max 0 width
  and height = Int.max 0 height in
  let view =
    View.crop
      ~r:(Int.max 0 (View.width view - width))
      ~b:(Int.max 0 (View.height view - height))
      view
  in
  View.zcat [ view; View.rectangle ~width ~height () ]
;;

let colored appearance role view =
  let bg = Role.backdrop appearance role in
  View.with_colors ~fill_backdrop:true view ~fg:(Role.foreground appearance Foreground) ~bg
;;

let lines ?(appearance = Appearance.default) ?(role = Role.Foreground) ~width ~height rows
  =
  List.take rows (Int.max 0 height)
  |> List.map ~f:(View.text ~attrs:(Role.attrs appearance role))
  |> View.vcat
  |> box ~width ~height
  |> colored appearance role
;;

let framed = Panel.framed

let studio (appearance : Appearance.t) =
  match appearance.preset with
  | Studio | Structured_studio -> true
  | _ -> false
;;

let frame_tile ?(enabled = true) appearance ~focused ~width ~height content =
  let geometry =
    Panel.geometry
      ~framed:(enabled && framed appearance ~width ~height)
      ~width
      ~height
      ~horizontal_padding:0
      ~vertical_padding:0
  in
  Panel.render
    appearance
    ~attrs:(Role.attrs appearance (if focused then Focus else Border))
    ~title:View.none
    ~geometry
    ~width
    ~height
    content
;;

type data =
  { project : Project.t option
  ; jobs : Job.t list
  ; runs : (Run_ref.t * string) list
  ; log_lines : Job_id.t -> string list
  ; run_lines : Run_ref.t -> string -> string list
  ; run_context : Run_ref.t -> string list
  ; summary : Run_ref.t -> Asic.Summary.t option
  ; status : string
  ; environment : string
  ; asic_lines : string list
  ; asic : Asic.Snapshot.t option
  }

let run_label (run : Run_ref.t) = Backend_id.to_string run.backend ^ "/" ^ run.id

let display_run (run : Run_ref.t) =
  Backend_id.to_string run.backend ^ "/" ^ Overview_tiles.short_id run.id
;;

let cell_width text = View.width (View.text text)

let fit_label ~width text =
  let width = Int.max 0 width in
  if cell_width text <= width
  then text
  else if width < 5
  then E.text (E.clip ~width (E.plain text))
  else (
    let rec scalars offset acc =
      if offset >= String.length text
      then acc
      else (
        let decoded = Stdlib.String.get_utf_8_uchar text offset in
        let length = Stdlib.Uchar.utf_decode_length decoded in
        scalars (offset + length) (String.sub text ~pos:offset ~len:length :: acc))
    in
    let tail_width = (width - 1) / 2 in
    let _, tail =
      List.fold (scalars 0 []) ~init:(0, "") ~f:(fun (used, tail) scalar ->
        let size = cell_width scalar in
        if used + size > tail_width then tail_width, tail else used + size, scalar ^ tail)
    in
    E.text (E.clip ~width:(width - cell_width tail - 1) (E.plain text)) ^ "~" ^ tail)
;;

let run_selector_row
  ?(string_compression = true)
  ?(population = [])
  ~width
  ~status_width
  ~cursor
  ~active
  run
  status
  =
  let marker = (if cursor then ">" else " ") ^ if active then "*" else " " in
  let status = E.text (E.clip ~width:status_width (E.plain status)) in
  let label_width = Int.max 0 (width - 3 - status_width - 1) in
  let token =
    Presentation.identifiers
      ~width:label_width
      ~compress:string_compression
      (run.Run_ref.id :: population)
      run.id
  in
  let identity = Backend_id.to_string run.Run_ref.backend ^ "/" ^ token in
  let identity = if cell_width identity > label_width then token else identity in
  let identity =
    match run.label with
    | Some label when (not (String.equal label run.id)) && not (String.is_empty label) ->
      let room = label_width - cell_width identity - 3 in
      if room > 0 then fit_label ~width:room label ^ " · " ^ identity else identity
    | _ -> identity
  in
  let label = fit_label ~width:label_width identity in
  marker
  ^ " "
  ^ label
  ^ String.make (Int.max 0 (label_width - cell_width label)) ' '
  ^ " "
  ^ status
;;

(** Lifecycle vocabulary only: an acceptance verdict or words inside an ID/report do not
    describe the execution lifecycle. Unknown provider values stay neutral. *)
let run_status_role = function
  | "completed" -> Role.Success
  | "failed" -> Failure
  | "running" | "starting" | "observing" -> Running
  | "pending" | "queued" | "cancelled" | "interrupted" | "skipped" -> Warning
  | _ -> Foreground
;;

(** Only lifecycle fields enter this mapping, never arbitrary report text. *)
let run_indicator : string -> Indicator.t = function
  | "running" | "starting" | "observing" -> Running
  | "pending" | "queued" -> Pending
  | "completed" -> Completed
  | "failed" -> Failed
  | "cancelled" | "interrupted" -> Cancelled
  | "skipped" -> Skipped
  | _ -> Unknown
;;

let indicator_view ?indicator_frames appearance role kind =
  let glyph = Indicator.view ?frames:indicator_frames appearance.Appearance.icons kind in
  if Appearance.Icons.equal appearance.icons None_
  then View.none
  else
    View.hcat [ box ~width:1 ~height:1 glyph; View.text " " ]
    |> View.with_colors' ~fg:(Role.foreground appearance role)
;;

let indicator_label icons kind label =
  let glyph = Indicator.text icons kind in
  (if String.is_empty glyph then "" else glyph ^ " ") ^ label
;;

let freshness_indicator : Asic.Summary.Freshness.t -> Indicator.t = function
  | Validated -> Completed
  | Cached_unverified -> Cached
  | Missing_source -> Unavailable
  | Refresh_failed _ -> Stale
;;

(* Only a typed, active evidence read for this exact scope is activity. A cache lookup,
   retained error, or execution lifecycle must never start an evidence spinner. *)
let evidence_reading data ~views ~runs =
  match Evidence_activity.summarize ~views ~runs data.asic with
  | Reading _ -> true
  | Idle | Cache_lookup _ | Not_updated _ -> false
;;

let freshness_row ?(reading = false) icons freshness row =
  let glyph =
    Indicator.text icons (if reading then Running else freshness_indicator freshness)
  in
  if String.is_empty glyph
  then row
  else { E.text = glyph ^ " "; role = E.freshness_role freshness } :: row
;;

let inspection_indicator ~reading (view : Inspection_view.t) : Indicator.t =
  if reading
  then Running
  else if Option.is_some (Option.first_some view.error view.pending_error)
  then Stale
  else (
    match view.index with
    | None -> Unavailable
    | Some index -> if index.cached_unverified then Cached else Completed)
;;

let run_has_producer data run =
  Option.exists data.asic ~f:(fun snapshot ->
    List.exists snapshot.Asic.Snapshot.runs ~f:(fun execution ->
      Run_ref.equal execution.run run
      && List.mem
           [ "queued"; "pending"; "starting"; "running"; "observing" ]
           execution.status
           ~equal:String.equal)
    && List.exists snapshot.operations ~f:(fun operation ->
      String.equal operation.kind "run"
      && (Plain_rpc.active operation || String.equal operation.state "reserving")
      && Option.exists operation.run ~f:(Run_ref.equal run)))
;;

(* Absence of an owned producer says nothing about external execution. Only explicit
   observation loss for this exact run qualifies retained, unresolved stage evidence. *)
let stopped_observation data run =
  Option.bind data.asic ~f:(fun snapshot ->
    let operations =
      List.filter snapshot.Asic.Snapshot.operations ~f:(fun operation ->
        List.mem [ "observe"; "run" ] operation.kind ~equal:String.equal
        && Option.exists operation.run ~f:(Run_ref.equal run))
    in
    let replacement =
      List.exists operations ~f:(fun operation ->
        Plain_rpc.active operation || String.equal operation.state "reserving")
    in
    Option.bind
      (List.find snapshot.runs ~f:(fun execution -> Run_ref.equal execution.run run))
      ~f:(fun execution ->
        let unresolved =
          List.is_empty execution.stages
          || List.exists execution.stages ~f:(fun stage ->
            match stage.Asic.Stage.status with
            | Pending | Running | Unknown _ -> true
            | Completed | Failed | Skipped | Cancelled | Not_requested | Unsupported ->
              false)
        in
        if replacement || not unresolved
        then None
        else (
          let explicit_error =
            Option.filter execution.error ~f:(fun error ->
              let error = String.lowercase error in
              List.exists
                [ "observation unavailable"; "observation stopped" ]
                ~f:(fun phrase -> String.is_substring error ~substring:phrase))
          in
          Option.first_some
            explicit_error
            (List.find_map operations ~f:(fun operation ->
               if List.mem [ "failed"; "cancelled" ] operation.state ~equal:String.equal
               then
                 Some
                   (Option.value
                      operation.error
                      ~default:(operation.kind ^ " " ^ operation.state))
               else None)))))
;;

let observation_qualifier = "Observation stopped; stage state unconfirmed"

let run_selector_view
  ?(string_compression = true)
  ?(population = [])
  ?indicator_frames
  ?time
  ?time_width
  appearance
  ~width
  ~status_width
  ~cursor
  ~active
  run
  status
  =
  let status_role = run_status_role status in
  let icon =
    indicator_view ?indicator_frames appearance status_role (run_indicator status)
  in
  let time = Option.value time ~default:"" in
  let time_width = Option.value time_width ~default:(cell_width time) in
  let time =
    if time_width > 0 && time_width + status_width + View.width icon + 10 <= width
    then " | " ^ String.make (Int.max 0 (time_width - cell_width time)) ' ' ^ time
    else ""
  in
  let text_width = Int.max 0 (width - View.width icon - cell_width time) in
  let row =
    run_selector_row
      ~string_compression
      ~population
      ~width:text_width
      ~status_width
      ~cursor
      ~active
      run
      status
  in
  let identity_width = Int.max 0 (text_width - status_width) in
  let identity = E.text (E.clip ~width:identity_width (E.plain row)) in
  let status = E.text (E.clip ~width:status_width (E.plain status)) in
  let status =
    status
    ^
    if String.is_empty time
    then ""
    else String.make (status_width - cell_width status) ' '
  in
  let attrs role =
    Role.attrs appearance role
    @ if cursor then [ Attr.bg (Role.backdrop appearance Selection) ] else []
  in
  View.hcat
    [ View.text ~attrs:(attrs (if cursor then Selection else Foreground)) identity
    ; icon
      |> View.with_colors'
           ?bg:(if cursor then Some (Role.backdrop appearance Selection) else None)
    ; View.text ~attrs:(attrs status_role) status
    ; View.text ~attrs:(attrs Muted) time
    ]
  |> box ~width ~height:1
;;

let%test_unit "single-line selectors reserve distinct tokens after final width fitting" =
  let plain_text view =
    let buffer = Buffer.create 100 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let ids =
    [ "same0000000000000000tail"; "same0000000000000001tail"; "same…tail"; "#1" ]
  in
  List.iter [ true; false ] ~f:(fun string_compression ->
    List.iter [ 16; 24; 40; 100 ] ~f:(fun width ->
      let rendered =
        List.map ids ~f:(fun id ->
          let run =
            { Asic_snapshot_fixture.run_a with
              id
            ; label =
                Some "A human provider label whose shared prefix must not hide identity"
            }
          in
          run_selector_view
            ~string_compression
            ~population:ids
            Appearance.default
            ~width
            ~status_width:6
            ~cursor:false
            ~active:false
            run
            "failed"
          |> plain_text)
      in
      assert (not (List.contains_dup rendered ~compare:String.compare))))
;;

let request_scope (execution : Asic.Run.t) =
  match execution.selection with
  | None -> "Request scope: unknown (selection unavailable)"
  | Some selection -> "Request endpoint: " ^ selection.endpoint
;;

let request_context snapshot run =
  Option.bind snapshot ~f:(fun (snapshot : Asic.Snapshot.t) ->
    List.find snapshot.runs ~f:(fun execution -> Run_ref.equal execution.run run))
  |> Option.value_map
       ~default:[ "Request scope: unknown (execution unavailable)" ]
       ~f:(fun execution -> [ request_scope execution ])
;;

let stage_lines (execution : Asic.Run.t) kind =
  let scope = request_scope execution in
  match kind with
  | "placement" | "cts" | "routing" | "checks" | "finalization" | "timing" ->
    [ "No terminal result imported; inspect exact finalization reference"
    ; scope
    ; "Stage completion / verification not inferred from cached synthesis metrics"
    ]
  | _ -> [ "Unsupported evidence kind: " ^ kind; scope ]
;;

let finalization_lines (f : Asic.Finalization.t) =
  [ "Finalization: " ^ f.key
  ; sprintf "State: %s · owned=%b" f.state f.owned
  ; "Phase: " ^ Option.value f.phase ~default:"unreported"
  ; "Reported operation: " ^ Option.value f.operation_status ~default:"unreported"
  ; "Acceptance: "
    ^ Option.value
        f.acceptance
        ~default:
          (if f.acceptance_requested then "requested / unreported" else "not requested")
  ]
  @ Option.to_list (Option.map f.error ~f:(fun e -> "ERROR: " ^ e))
  @ [ "Run: " ^ run_label f.run; "Palette: Reconnect finalization (read-only) " ^ f.key ]
;;

let run_lines snapshot run kind =
  match (snapshot : Asic.Snapshot.t option) with
  | None -> [ "ASIC provider not loaded" ]
  | Some asic ->
    if String.equal kind "finalization-status"
    then
      List.filter asic.finalizations ~f:(fun f -> Run_ref.equal f.run run)
      |> List.concat_map ~f:finalization_lines
    else (
      match List.find asic.runs ~f:(fun r -> Run_ref.equal r.run run) with
      | None -> [ "Saved run unavailable; no replacement selected" ]
      | Some execution ->
        (match List.find asic.summaries ~f:(fun s -> Run_ref.equal s.run run) with
         | None ->
           (if String.equal kind "synthesis" then [] else stage_lines execution kind)
           @ [ "Loading summary for " ^ run_label run
             ; "Observed execution: " ^ execution.status
             ]
           @ Option.to_list execution.error
         | Some summary
           when Terminal_result_view.supports kind && Option.is_some summary.terminal ->
           Terminal_result_view.lines
             (Option.value_exn summary.terminal)
             ~kind
             ~detail:false
           @ [ "Freshness: "
               ^ Sexp.to_string_hum (Asic.Summary.Freshness.sexp_of_t summary.freshness)
             ; "Observed execution: " ^ execution.status
             ; request_scope execution
             ]
           @ Option.to_list execution.error
         | Some summary ->
           let metrics =
             if String.equal kind "timing"
             then
               if List.is_empty summary.timing
               then stage_lines execution kind
               else
                 List.map summary.timing ~f:(fun (name, value, unit_) ->
                   sprintf "%s: %g %s" name value unit_)
             else if String.equal kind "synthesis"
             then
               [ "Cell count: "
                 ^ Option.value_map
                     summary.cell_count
                     ~default:"unavailable"
                     ~f:Int.to_string
               ]
             else if String.equal kind "checks"
             then stage_lines execution kind @ Synthesis_view.checks_lines summary
             else stage_lines execution kind
           in
           let breakdown =
             if not (String.equal kind "synthesis")
             then []
             else
               [ ("Cells: "
                  ^
                  if List.is_empty summary.cells
                  then "breakdown unavailable"
                  else
                    List.map summary.cells ~f:(fun (name, count) ->
                      sprintf "%s=%d" name count)
                    |> String.concat ~sep:", ")
               ]
           in
           metrics
           @ [ "Freshness: "
               ^ Sexp.to_string_hum (Asic.Summary.Freshness.sexp_of_t summary.freshness)
             ]
           @ breakdown
           @ [ "Evidence: "
               ^ Filename.basename summary.execution_file
               ^ " #"
               ^ String.prefix summary.source_digest 12
             ; "Run completion: "
               ^ summary.completion
               ^ " | acceptance: "
               ^ summary.acceptance
             ; "Observed execution: " ^ execution.status
             ; "Producer: provider checkpoint (inspect synthesis evidence)"
             ; "Source: "
               ^ Filename.basename summary.execution_file
               ^ " (inspect for full path)"
             ]
           @ Option.to_list execution.error
           @
           if (not (String.equal kind "synthesis")) || List.is_empty summary.cells
           then []
           else
             "CELL BREAKDOWN"
             :: List.map summary.cells ~f:(fun (name, count) ->
               sprintf "  %s: %d" name count)))
;;

let wrap_cells ~width text =
  let width = Int.max 1 width in
  let rec loop start offset cells output =
    if offset >= String.length text
    then List.rev (String.sub text ~pos:start ~len:(offset - start) :: output)
    else (
      let decoded = Stdlib.String.get_utf_8_uchar text offset in
      let length = Stdlib.Uchar.utf_decode_length decoded in
      let cell_width =
        View.uchar_tty_width (Stdlib.Uchar.utf_decode_uchar decoded) |> Int.max 0
      in
      if cells + cell_width > width && offset > start
      then
        loop offset offset 0 (String.sub text ~pos:start ~len:(offset - start) :: output)
      else loop start (offset + length) (cells + cell_width) output)
  in
  loop 0 0 0 []
;;

let artifact_inspector host tile =
  Option.bind (H.local host tile.W.Tile.id).artifacts ~f:(fun view ->
    Option.bind host.H.registry ~f:(fun registry ->
      W.resolve_tile registry tile.id
      |> Result.ok
      |> Option.bind ~f:(fun reference ->
        Artifact_view.reconcile_scope view ~scope:reference.run)))
;;

(* Previews are project-scoped plans for NEW runs, not evidence belonging to the observed
   run. Only advertise a matching selection beside a checklist action. *)
let checklist_intent_selection host data run intent =
  Stage_action.resolve_intent
    ~intent
    ~remembered:host.H.remembered_selection
    ~observed:
      (Option.bind data.asic ~f:(fun snapshot ->
         List.find snapshot.runs ~f:(fun execution -> Run_ref.equal execution.run run)
         |> Option.bind ~f:(fun execution -> execution.selection)))
    ~snapshot:data.asic
;;

let checklist_preview host data tile =
  Option.bind host.H.registry ~f:(fun registry ->
    W.resolve_tile registry tile.W.Tile.id
    |> Result.ok
    |> Option.bind ~f:(fun reference -> reference.run)
    |> Option.bind ~f:(fun run ->
      let items = Overview_tiles.checklist_items ~asic:data.asic ~run in
      Option.bind
        (H.checklist_cursor (H.local host tile.id) ~run ~items)
        ~f:(fun item ->
          match item with
          | Catalog_endpoint _ | Overview_tiles.Elaboration_preparation -> None
          | _ ->
            let intent =
              match item with
              | Overview_tiles.Elaboration_preparation ->
                Stage_action.Fresh_endpoint "__preparation_never_launch"
              | Overview_tiles.Timing_analysis _ -> Stage_action.Fresh_endpoint "timing"
              | Catalog_endpoint endpoint -> Stage_action.Fresh_endpoint endpoint
              | Physical_stage stage -> Stage_action.Physical_stage stage
            in
            (match
               ( checklist_intent_selection host data run intent
               , Option.bind data.asic ~f:(fun asic -> asic.preview) )
             with
             | Ok selection, Some preview
               when Asic.Selection.equal selection preview.selection
                    && Option.is_none host.stage_preparation
                    && Planned_run.launchable host.planned_run preview -> Some preview
             | _ -> None))))
;;

let checklist_hints host data tile =
  if not (H.policy host tile).hints
  then []
  else (
    let timing =
      Option.exists (H.tile_run host tile) ~f:(fun run ->
        match
          H.checklist_cursor
            (H.local host tile.id)
            ~run
            ~items:(Overview_tiles.checklist_items ~asic:data.asic ~run)
        with
        | Some (Timing_analysis _) -> true
        | _ -> false)
    in
    let elaboration =
      Option.exists (H.tile_run host tile) ~f:(fun run ->
        H.checklist_cursor
          (H.local host tile.id)
          ~run
          ~items:(Overview_tiles.checklist_items ~asic:data.asic ~run)
        |> Option.exists ~f:(function
          | Elaboration_preparation -> true
          | _ -> false))
    in
    if Option.exists
         (Planned_run.fresh_intent host.planned_run)
         ~f:(Planned_run.fresh_launchable host.planned_run)
    then
      [ "Space c c: Launch"
      ; "or Launch and view"
      ; "Fresh inputs; launch runs Elaboration first"
      ; "r stage NEW inputs"
      ]
    else if elaboration
    then [ "r EDA-less project preparation"; "Enter read-only history/logs" ]
    else if timing && Option.is_none (checklist_preview host data tile)
    then
      [ "Enter exact historical timing evidence"
      ; "r prepare NEW timing run (current catalog)"
      ]
    else (
      match checklist_preview host data tile with
      | None -> [ "R launch NEW run | r stage"; "j/k browse | Enter inspect" ]
      | Some preview ->
        [ "Space c c: Launch"
        ; "or Launch and view"
        ; "r prepare NEW run"
        ; "j/k browse | Enter inspect"
        ; "Matching plan: " ^ preview.selection.endpoint
        ]))
;;

let utility_rows ?(now = Time_ns.now ()) host data tile =
  let policy = H.policy host tile in
  Option.bind host.H.registry ~f:(fun registry ->
    let selected_run =
      W.resolve_tile registry tile.W.Tile.id
      |> Result.ok
      |> Option.bind ~f:(fun reference -> reference.run)
    in
    match tile.kind with
    | "preparation" ->
      let local = H.local host tile.id in
      Some
        (Preparation_view.rows
           ~snapshot:host.preparation
           ~jobs:data.jobs
           ~project:(Option.map data.project ~f:(fun p -> p.Project.id))
           ~rtl_scope:host.preparation_rtl_scope
           ~cursor:local.cursor
           ~detail:local.utility_detail
           ~log_lines:data.log_lines)
    | "timing" when (H.local host tile.id).utility_detail ->
      Some
        (Option.value_map selected_run ~default:[] ~f:(fun run ->
           let stage =
             Overview_tiles.observed_stages ~asic:data.asic ~run
             |> List.find ~f:(fun s -> String.equal s.Asic.Stage.id "timing")
             |> Option.map ~f:(Overview_tiles.asic_stage_row ~now ~run ~selected:false)
           in
           Option.to_list stage
           @ [ Overview_tiles.analysis_row
                 ~decimal_places:policy.decimal_places
                 ~run
                 ~selected:false
                 (data.summary run)
             ]))
    | "live-status" when H.compact_summary host tile ->
      Some
        [ Overview_tiles.row
            ~role:(Overview_tiles.connection_role data.status)
            "Connection"
            data.status
        ; Overview_tiles.row
            "Project"
            (Option.value_map data.project ~default:"none" ~f:(fun p -> p.Project.name))
        ; Overview_tiles.row "Scope" "Project tests"
        ]
    | "live-status" ->
      Some
        (Overview_tiles.status_rows
           ~string_compression:(H.policy host tile).string_compression
           ~launch_target:
             (match (W.workspace registry tile.workspace).preset with
              | Some "overview" -> Launch_preferences.chip_target data.asic
              | _ -> None)
           ~snapshot:registry
           ~active_workspace:host.active
           ~project:data.project
           ~selected_run
           ~connection:data.status
         @ [ Evidence_activity.session_row ?selected_run host data.asic ])
    | "workspace-tabs" ->
      Some
        (Overview_tiles.navigation_rows ~snapshot:registry ~active_workspace:host.active
         |> List.filter ~f:(fun row ->
           Option.exists row.Overview_tiles.workspace ~f:(fun id ->
             List.exists (H.workspace_choices host tile.id) ~f:(fun w ->
               W.Workspace_id.equal id w.id)))
         |> List.map ~f:(fun row ->
           let browsing =
             Option.equal
               W.Workspace_id.equal
               row.workspace
               (Option.map (H.workspace_cursor host tile.id) ~f:(fun w -> w.id))
           in
           { row with
             value =
               (if row.active then "active" else if browsing then "Enter to open" else "")
           ; role = (if browsing then Active else row.role)
           }))
    | "stage-checklist" ->
      let local = H.local host tile.id in
      let observed =
        Overview_tiles.selectable_checklist ~asic:data.asic ~remembered:host.remembered_selection
          ~run:selected_run
      in
      let selected =
        H.checklist_cursor_for local ~run:selected_run ~items:observed
      in
      let stages =
        match selected_run, observed with
        | Some run, (_ :: _ as stages) ->
          (if local.utility_detail then Option.to_list selected else stages)
          |> List.map ~f:(fun item ->
            let row =
              Overview_tiles.checklist_row
                ~now
                ~run
                ~selected:
                  (Option.exists selected ~f:(fun s ->
                     String.equal
                       (Overview_tiles.checklist_id s)
                       (Overview_tiles.checklist_id item)))
                item
            in
            let row = match item with
            | Elaboration_preparation ->
              let workflow = Overview_tiles.workflow_for_run ~asic:data.asic ~run in
              let linked =
                Overview_tiles.elaboration_row ~now ~selected:row.active workflow
              in
              { linked with
                details =
                  linked.details
                  @ Option.value_map workflow ~default:[] ~f:(fun w ->
                    List.concat_map
                      (Option.to_list w.build_job @ Option.to_list w.emission_job)
                      ~f:(fun j -> data.log_lines j.Job.id))
              }
            | Physical_stage s when String.equal s.id "timing" ->
              { row with
                details =
                  row.details @ Overview_tiles.analysis_details ~run (data.summary run)
              }
            | _ -> row
            in
            { row with cursor_id = Some (Overview_tiles.checklist_id item) })
        | None, (_ :: _ as items) ->
          let catalog_rows =
            List.filter_map items ~f:(function
              | Overview_tiles.Catalog_endpoint endpoint as item ->
                Some (Overview_tiles.catalog_row ~selected:(Option.exists selected ~f:(fun s ->
                  String.equal (Overview_tiles.checklist_id s) (Overview_tiles.checklist_id item))) endpoint)
              | _ -> None)
          in
          (match Planned_run.workflow host.planned_run with
           | None -> []
           | Some w -> Overview_tiles.elaboration_row ~now ~selected:false (Some w)
                       :: Overview_tiles.workflow_endpoint_rows w)
          @ catalog_rows
        | _ ->
          Overview_tiles.elaboration_row
            ~now
            ~selected:false
            (match selected_run with
             | Some run -> Overview_tiles.workflow_for_run ~asic:data.asic ~run
             | None -> Planned_run.workflow host.planned_run)
          :: (match selected_run, Planned_run.workflow host.planned_run with
              | None, Some w -> Overview_tiles.workflow_endpoint_rows w
              | _ -> Overview_tiles.stage_rows ~selected_run ~asic:data.asic ~observation:None ())
      in
      let facts =
        Option.bind selected_run ~f:data.summary
        |> Option.value_map ~default:[] ~f:(fun summary ->
          Overview_tiles.summary_rows ~freshness:policy.freshness summary)
      in
      let facts =
        facts
        @ Option.value_map
            (Option.bind selected_run ~f:(fun run -> Overview_tiles.execution ~asic:data.asic ~run))
            ~default:[]
            ~f:(fun execution ->
              Option.value_map execution.error ~default:[] ~f:(fun error ->
                [ Overview_tiles.row
                    ~role:Warning
                    ~details:(String.split_lines error)
                    "Observation"
                    (Presentation.failure_summary error ^ " (details: d)") ]))
      in
      let interaction =
        if (not local.utility_detail) || not policy.hints
        then []
        else
          [ Overview_tiles.row
              ~role:Muted
              "Interaction"
              (match selected with
               | Some Elaboration_preparation ->
                 "Esc overview; r stages fresh Elaboration inputs; R launches; Enter \
                  linked evidence"
               | Some (Timing_analysis _) ->
                 "Esc overview; Enter exact historical evidence; r prepares NEW timing \
                  run if current catalog supports it"
               | _ -> "Esc overview; r prepares a NEW run through advertised endpoint")
          ]
          @ (match selected with
             | Some item ->
               [ (match Stage_launch_commands.fresh_selection ~asic:data.asic
                          ~remembered:host.remembered_selection item with
                  | Error reason -> Overview_tiles.row ~role:Warning "New run" reason
                  | Ok selection ->
                    Overview_tiles.row
                      ~role:Muted
                      "New run inputs"
                      (Launch_preferences.chip_label selection.chip_target
                       ^ " · "
                       ^ selection.flow
                       ^ "/"
                       ^ selection.profile
                       ^ " → "
                       ^ selection.endpoint
                       ^ " | assignments: "
                       ^ String.concat ~sep:"; " selection.assignments))
               ]
             | _ -> [])
          @ Option.value_map host.stage_preparation ~default:[] ~f:(fun reason ->
            [ Overview_tiles.row ~role:Warning "Preparation" reason ])
          @ (checklist_preview host data tile
             |> Option.value_map ~default:[] ~f:(fun preview ->
               [ Overview_tiles.row
                   ~role:Running
                   "Matching project preview"
                   (preview.plan_identity ^ " — Space c c: Launch / Launch and view")
               ]))
      in
      Some
        ((if policy.run_reference
          then
            [ Overview_tiles.row
                ~role:Muted
                "Run"
                (Option.value_map selected_run ~default:"none selected" ~f:run_label)
            ]
          else [])
         @ (if local.utility_detail
            then
              Option.bind selected_run ~f:(stopped_observation data)
              |> Option.value_map ~default:[] ~f:(fun error ->
                [ Overview_tiles.row
                    ~role:Warning
                    ~details:(String.split_lines error)
                    "Observation error"
                    (Presentation.failure_summary error) ])
            else [])
         @ (if H.compact_summary host tile && not local.utility_detail
            then Overview_tiles.checklist_rows ~compact:true ~stages ~aggregate:facts ()
            else stages @ facts)
         @ interaction)
    | _ -> None)
;;

let utility_attrs appearance : Overview_tiles.Role.t -> Attr.t list = function
  | Heading -> Role.attrs appearance Heading
  | Foreground -> Role.attrs appearance Foreground
  | Muted -> Role.attrs appearance Muted
  | Active -> Role.attrs appearance Selection
  | Running -> Role.attrs appearance Running
  | Success -> Role.attrs appearance Success
  | Warning -> Role.attrs appearance Warning
  | Failure -> Role.attrs appearance Failure
  (* Linked state shares the scheme's success green; the keyword is always text. *)
  | Linked -> Role.attrs appearance Success @ [ Attr.bold ]
;;

let inspection_explorer host tile =
  Option.bind (H.local host tile.W.Tile.id).inspection ~f:(fun view ->
    Option.bind host.H.registry ~f:(fun registry ->
      W.resolve_tile registry tile.id
      |> Result.ok
      |> Option.bind ~f:(fun reference ->
        Inspection_view.reconcile_scope view ~scope:reference.run)))
;;

let evidence_attrs appearance : E.Role.t -> Attr.t list = function
  | Plain -> Role.attrs appearance Foreground
  | Muted -> Role.attrs appearance Muted
  | Validated -> Role.attrs appearance Success
  | Passed -> Role.attrs appearance Success
  | Failed -> Role.attrs appearance Failure
  | Pending | Stale -> Role.attrs appearance Warning
  | Running -> Role.attrs appearance Running
;;

let tile_run host tile =
  if Testing_workspace.is_pane tile.W.Tile.kind
     || P.Waveforms.is_pane tile.kind
     || String.equal tile.kind "hierarchy"
  then None
  else
    H.tile_run host tile
;;

let resource_page host data tile ~width ~height =
  match H.resource_owner host tile with
  | None ->
    [ None, E.plain "Add a resources tile to this workspace to select a resource." ]
  | Some owner ->
    let local = H.local host owner.id in
    let view =
      Resources_view.reconcile local.resources ~run:(tile_run host owner)
        ~filter:local.filter data.asic
    in
    if String.equal tile.kind "resource-summary"
    then
      Resources_view.summary view |> E.page ~width ~height ~offset:0
      |> List.map ~f:(fun row -> None, row)
    else (
      let render =
        if String.equal tile.kind "resource-detail"
        then Resources_view.detail_page_with_targets ~hints:(H.policy host tile).hints
        else if Option.is_some (H.resource_reader host tile)
        then Resources_view.list_page_with_targets ~hints:(H.policy host tile).hints
        else Resources_view.page_with_targets
      in
      render view ~asic:data.asic ~filter:local.filter ~width ~height)
;;

(* Chrome is removed at typed construction locations, before wrapping/paging. Never search
   provider text: full evidence, raw reports and fallback payloads retain every source row
   even when their text resembles chrome. *)
let terminal_content host data tile ~run =
  let local = H.local host tile.W.Tile.id
  and policy = H.policy host tile in
  let summary = data.summary run in
  let exact_terminal =
    Option.exists summary ~f:(fun s ->
      Run_ref.equal s.Asic.Summary.run run && Option.is_some s.terminal)
  in
  let content =
    if (not exact_terminal)
       && List.mem [ "placement"; "routing" ] tile.kind ~equal:String.equal
    then
      (* Physical stage observations do not require a finalization result. Enter leaves
         the compact view, but must not replace those facts with the terminal-result
         reader's unrelated finalization placeholder. Keep the exact stage/run/source
         details available in this expanded view too. *)
      Overview_summary.rows
        ~decimal_places:policy.decimal_places
        ~kind:tile.kind
        ~run
        ~summary
        ~stages:(Overview_tiles.observed_stages ~asic:data.asic ~run)
        ()
      |> fun rows ->
      let facts =
        List.filter_map rows ~f:(fun row ->
          (* The non-detail host adds its own stage Time row. *)
          if (not local.terminal_result.detail)
             && String.equal row.Overview_tiles.label "Time"
          then None
          else Some (row.label ^ ": " ^ row.value))
      in
      let details =
        if local.terminal_result.detail
        then
          List.concat_map rows ~f:(fun row -> row.Overview_tiles.details)
          |> List.stable_dedup ~compare:String.compare
        else []
      in
      List.map (facts @ data.run_context run @ details) ~f:E.plain
    else
      Terminal_result_view.semantic_rows
        ~fallback:(data.run_lines run tile.kind)
        ~request_context:(data.run_context run)
        { local.terminal_result with offset = 0 }
        ~run
        ~summary
        ~kind:tile.kind
        ~width:Int.max_value
        ~height:Int.max_value
  in
  let hint_index =
    Option.bind summary ~f:(fun s ->
      Option.map s.Asic.Summary.terminal ~f:(fun terminal ->
        2
        + List.length (data.run_context run)
        + List.length
            (Terminal_result_view.semantic_lines terminal ~kind:tile.kind ~detail:false)
        - 1))
  in
  let content =
    if not exact_terminal
    then content
    else
      List.filteri content ~f:(fun i _ ->
        i <> 0 (* run reference belongs to host chrome *)
        && (policy.freshness || i <> 1)
        && (policy.hints || not (Option.equal Int.equal (Some i) hint_index)))
  in
  let content =
    if exact_terminal && policy.freshness
    then
      List.mapi content ~f:(fun i row ->
        if i = 0
        then
          freshness_row
            ~reading:(evidence_reading data ~views:[] ~runs:[ run ])
            host.H.appearance.icons
            (Option.value_exn summary).freshness
            row
        else row)
    else content
  in
  (if String.equal tile.kind "finalization"
   then List.map (data.run_lines run "finalization-status") ~f:E.plain
   else [])
  @ content
;;

let synthesis_metrics_content host data tile ~run =
  let local = H.local host tile.W.Tile.id
  and policy = H.policy host tile in
  let summary = data.summary run in
  let state =
    Synthesis_view.State.scroll local.synthesis ~delta:Int.min_value ~max_offset:0
  in
  let rows =
    Synthesis_view.semantic_rows
      state
      ~summary
      ~filter:local.filter
      ~width:Int.max_value
      ~height:Int.max_value
  in
  let freshness_index =
    Option.map summary ~f:(fun s -> 2 + Int.max 1 (List.length s.Asic.Summary.metrics))
  in
  List.filter_mapi rows ~f:(fun i row ->
    if (not policy.freshness) && Option.equal Int.equal (Some i) freshness_index
    then None
    else if i = 0 && not policy.hints
    then Some (E.plain "Synthesis metrics")
    else
      Some
        (if Option.equal Int.equal (Some i) freshness_index
         then
           freshness_row
             ~reading:(evidence_reading data ~views:[] ~runs:[ run ])
             host.H.appearance.icons
             (Option.value_exn summary).freshness
             row
         else row))
;;

let metrics_scope data run =
  Option.map (data.summary run) ~f:(fun s -> run, s.Asic.Summary.source_digest)
;;

let metrics_offset local data run =
  if Option.equal
       (fun (r, d) (s, e) -> Run_ref.equal r s && String.equal d e)
       local.H.metrics_scope
       (metrics_scope data run)
  then local.scroll
  else 0
;;

let compact_summary_enabled host tile =
  let local = H.local host tile.W.Tile.id in
  H.compact_summary host tile
  && Overview_summary.supports tile.kind
  && Option.is_none local.inspection
  && Option.is_none local.artifacts
  && (not local.terminal_result.detail)
  && (not local.utility_detail)
  && ((not (String.equal tile.kind "synthesis"))
      || Synthesis_view.Mode.equal (Synthesis_view.State.mode local.synthesis) Summary)
;;

let compact_rows ?(now = Time_ns.now ()) host data tile =
  if not (compact_summary_enabled host tile)
  then None
  else
    Option.map (tile_run host tile) ~f:(fun run ->
      Overview_summary.rows
        ~now
        ~decimal_places:(H.policy host tile).decimal_places
        ~finalizations:
          (Option.value_map data.asic ~default:[] ~f:(fun s ->
             s.Asic.Snapshot.finalizations))
        ~compact:(H.compact_summary host tile)
        ~freshness:(H.policy host tile).freshness
        ~kind:tile.W.Tile.kind
        ~run
        ~summary:(data.summary run)
        ~stages:(Overview_tiles.observed_stages ~asic:data.asic ~run)
        ())
;;

let cells_source_height ~hints height = height + Bool.to_int (not hints && height >= 5)

let semantic_rows host data tile ~width ~height =
  let local = H.local host tile.W.Tile.id
  and policy = H.policy host tile in
  if Option.is_some local.inspection || Option.is_some local.artifacts
  then None
  else
    Option.bind (tile_run host tile) ~f:(fun run ->
      if String.equal tile.kind "synthesis"
      then (
        let mode = Synthesis_view.State.mode local.synthesis in
        let rows =
          match mode with
          | Metrics ->
            E.page
              ~width
              ~height
              ~offset:(metrics_offset local data run)
              (synthesis_metrics_content host data tile ~run)
          | Summary | Cells ->
            let base_height =
              height
              +
              if (not policy.freshness) && Synthesis_view.Mode.equal mode Summary
              then 1
              else 0
            in
            let source_height =
              if Synthesis_view.Mode.equal mode Cells
              then cells_source_height ~hints:policy.hints height
              else base_height + Bool.to_int ((not policy.hints) && base_height >= 8)
            in
            let rows =
              Synthesis_view.semantic_rows
                local.synthesis
                ~summary:(data.summary run)
                ~filter:local.filter
                ~width
                ~height:source_height
            in
            let count = List.length rows in
            List.filteri rows ~f:(fun i _ ->
              (policy.freshness
               || not
                    (Synthesis_view.Mode.equal mode Summary
                     && i = 1
                     && Option.is_some (data.summary run)))
              && (policy.hints
                  || not
                       (Option.is_some (data.summary run)
                        && i = count - 1
                        && ((Synthesis_view.Mode.equal mode Summary && source_height >= 8)
                            || (Synthesis_view.Mode.equal mode Cells && source_height >= 5)
                           ))))
            |> List.mapi ~f:(fun i row ->
              if policy.freshness && Synthesis_view.Mode.equal mode Summary && i = 1
              then
                Option.value_map (data.summary run) ~default:row ~f:(fun s ->
                  freshness_row
                    ~reading:(evidence_reading data ~views:[] ~runs:[ run ])
                    host.H.appearance.icons
                    s.freshness
                    row)
                |> E.clip ~width
              else row)
            |> Fn.flip List.take height
          | Details | Evidence ->
            Synthesis_view.semantic_rows
              local.synthesis
              ~summary:(data.summary run)
              ~filter:local.filter
              ~width
              ~height
        in
        Some rows)
      else if Terminal_result_view.supports tile.kind
      then (
        let state =
          Terminal_result_view.State.reconcile
            local.terminal_result
            ~run
            ~summary:(data.summary run)
        in
        Some
          (E.page
             ~width
             ~height
             ~offset:state.offset
             (terminal_content host data tile ~run)))
      else None)
;;

(* A shallow plan panel must show state and endpoint before verbose explanatory metadata.
   Summary facts each occupy one display-cell-clipped line; Enter retains the complete
   wrapped typed model, including exact identity and JSON. *)
let planned_asic_source_rows host tile =
  let detail = (H.local host tile.W.Tile.id).utility_detail in
  let model = Planned_run.model host.H.planned_run in
  let rows = Planned_run.rows model ~detail in
  match host.H.stage_preparation with
  | Some reason ->
    [ { Planned_run.role = Warning; text = reason }
    ; { Planned_run.role = Muted; text = "Launch disabled; press r to retry preparation" }
    ]
  | None ->
    if detail
    then rows
    else (
      let selection =
        Option.value_map model.selection ~default:[] ~f:(fun selection ->
          [ { Planned_run.role = Fact
            ; text = "endpoint: " ^ selection.Asic.Selection.endpoint
            }
          ; { role = Fact
            ; text = "flow: " ^ selection.flow ^ " / profile: " ^ selection.profile
            }
          ; { role = Fact
            ; text =
                ("assignments: "
                 ^
                 if List.is_empty selection.assignments
                 then "(none)"
                 else String.concat ~sep:"; " selection.assignments)
            }
          ])
      in
      let state =
        String.lowercase (Sexp.to_string (Planned_run.sexp_of_status model.status))
      in
      let launch =
        String.lowercase
          (Sexp.to_string (Planned_run.sexp_of_launch_status model.launch.state))
      in
      let headline =
        List.map (List.take rows 1) ~f:(fun row ->
          { row with
            Planned_run.text =
              state
              ^ (if Option.is_some (Planned_run.fresh_intent host.planned_run)
                    || Option.is_some (Planned_run.workflow host.planned_run)
                 then ": fresh input intent / "
                 else ": provider preview / ")
              ^ (if Option.is_none model.preview
                 then "separate launch: "
                 else if Planned_run.equal_status model.status Ready
                 then "last launch: "
                 else "retained preview launch: ")
              ^ launch
          })
      in
      headline
      @ List.take selection 1
      @ (if Planned_run.equal_status model.status Failed
         then [ { Planned_run.role = Error; text = model.message } ]
         else [])
      @ [ { Planned_run.role = Fact
          ; text = Planned_run.launch_label model ^ ": " ^ model.launch.message
          }
        ]
      @ Option.value_map model.launch.run_id ~default:[] ~f:(fun id ->
        [ { Planned_run.role = Fact; text = "exact allocated run: " ^ id } ])
      @ Option.value_map model.launch.key ~default:[] ~f:(fun key ->
        [ { Planned_run.role = Fact; text = "submission key: " ^ key } ])
      @ List.drop selection 1)
;;

let planned_source_rows host tile =
  let fresh_intent = Planned_run.fresh_intent host.H.planned_run in
  let workflow = Planned_run.workflow host.planned_run in
  if Option.is_some fresh_intent || Option.is_some workflow
  then (
    let model = Planned_run.model host.planned_run in
    let row role text = { Planned_run.role; text } in
    let intent =
      Option.first_some
        fresh_intent
        (Option.map workflow ~f:(fun w -> w.Asic.Fresh.Workflow.intent))
    in
    let detail = (H.local host tile.W.Tile.id).utility_detail in
    [ row
        (if Planned_run.equal_status model.status Ready then Success else Warning)
        (String.lowercase (Sexp.to_string (Planned_run.sexp_of_status model.status))
         ^ ": "
         ^ model.message)
    ; row
        (if Planned_run.equal_launch_status model.launch.state Launch_failed
         then Error
         else Fact)
        ("Workflow: " ^ model.launch.message)
    ]
    @ Option.value_map host.stage_preparation ~default:[] ~f:(fun reason ->
      [ row Warning reason ])
    @ Option.value_map intent ~default:[] ~f:(fun i ->
      [ row
          Fact
          ("endpoint: "
           ^ if i.elaboration_only then "elaboration" else i.selection.endpoint)
      ; row Fact ("flow: " ^ i.selection.flow ^ " / profile: " ^ i.selection.profile)
      ; row Fact ("assignments: " ^ String.concat ~sep:"; " i.selection.assignments)
      ; row
          Muted
          "Fresh launch: source build → bundle emission → physical prefix \
           (Elaboration-only stops after emission)"
      ]
      @
      if detail
      then
        [ row Fact ("Input intent: " ^ i.id)
        ; row Fact ("Captured scope: " ^ i.scope)
        ; row
            Fact
            ("Expected plan identity: "
             ^ Option.value i.expected_plan_identity ~default:"none (current source)")
        ]
      else [])
    @ Option.value_map model.launch.run_id ~default:[] ~f:(fun id ->
      [ row Fact ("exact allocated run: " ^ id) ])
    @ Option.value_map workflow ~default:[] ~f:(fun w ->
      [ row Fact ("Workflow ID: " ^ w.id); row Fact ("submission key: " ^ w.key) ]
      @ (if Planned_run.workflow_active w
         then
           [ row
               Muted
               "x cancel workflow; palette Cancel fresh workflow (build, emission and \
                physical execution)"
           ]
         else [])
      @
      if detail
      then
        Overview_tiles.inspection_lines
           [ Overview_tiles.elaboration_row ~now:(Time_ns.now ()) ~selected:false (Some w)
           ]
        |> List.map ~f:(row Fact)
      else []))
  else if host.H.planned_preparation
  then
    Preparation_view.staged_plan_rows
      ~snapshot:host.preparation
      ~reason:host.stage_preparation
      ~detail:(H.local host tile.W.Tile.id).utility_detail
  else planned_asic_source_rows host tile
;;

let plan_indicator : Planned_run.status -> Indicator.t = function
  | Empty -> Not_requested
  | Pending -> Running
  | Failed -> Failed
  | Stale -> Stale
  | Ready -> Ready
;;

let producer_indicator : Planned_run.launch_status -> Indicator.t = function
  | Submitting | Allocated | Running -> Running
  | Completed -> Completed
  | Launch_failed -> Failed
  | Cancelled -> Cancelled
  | Detached -> Unknown
  | Unavailable -> Unavailable
;;

let planned_role : Planned_run.role -> Role.t = function
  | Fact -> Foreground
  | Muted -> Muted
  | Warning -> Warning
  | Error -> Failure
  | Success -> Success
;;

let formatted_plan_history ?indicator_frames host tile ~width =
  let model = Planned_run.model host.H.planned_run in
  let detail = (H.local host tile.W.Tile.id).utility_detail in
  planned_source_rows host tile
  |> List.concat_mapi ~f:(fun i row ->
    let kind =
      if Option.is_some (Planned_run.fresh_intent host.planned_run)
         || Option.is_some (Planned_run.workflow host.planned_run)
      then
        if i = 0
        then Some (plan_indicator model.status)
        else if i = 1
        then Some (producer_indicator model.launch.state)
        else None
      else if host.planned_preparation
      then
        if i = 0
        then
          Some
            (match
               Preparation_view.staged_state
                 ~snapshot:host.preparation
                 ~reason:host.stage_preparation
             with
             | `Ready -> Indicator.Ready
             | `Stale _ | `Consumed _ -> Stale
             | `Unavailable _ -> Unavailable)
        else None
      else if Option.is_some host.stage_preparation
      then None
      else if i = 0
      then Some (plan_indicator model.status)
      else if i
              =
              if detail
              then 1
              else if Planned_run.equal_status model.status Failed
              then 3
              else 2
      then Some (producer_indicator model.launch.state)
      else None
    in
    let icon_role =
      match kind with
      | Some Running -> Role.Running
      | Some Completed | Some Ready -> Success
      | Some Failed -> Failure
      | Some Stale | Some Cancelled -> Warning
      | _ -> Muted
    in
    let icon =
      Option.value_map
        kind
        ~default:View.none
        ~f:(indicator_view ?indicator_frames host.appearance icon_role)
    in
    let text_width = Int.max 0 (width - View.width icon) in
    let text = Artifact_view.safe row.text in
    let texts =
      if detail
      then wrap_cells ~width:text_width text
      else [ E.text (E.clip ~width:text_width (E.plain text)) ]
    in
    List.mapi texts ~f:(fun j text ->
      ( { row with text }
      , if j = 0 then icon else View.rectangle ~width:(View.width icon) ~height:1 () )))
;;

let planned_target_rows host tile ~width =
  let detail = (H.local host tile.W.Tile.id).utility_detail in
  let snapshot = Planned_run.snapshot host.planned_run in
  match Launch_preferences.chip_target snapshot with
  | None -> []
  | Some target ->
    let selection =
      Preparation_view.selection ~remembered:host.remembered_selection ~asic:snapshot
    in
    let input f = Result.ok selection |> Option.value_map ~default:"unavailable" ~f in
    (* Reserve at least half a narrow summary for the value; detail wraps full labels. *)
    let budget = Int.min (cell_width "Launch chip") (Int.max 1 ((width - 2) / 2)) in
    let target_rows =
      [ true, "Launch chip", target.chip
      ; true, "Variant", target.variant
      ; false, "Flow", input (fun s -> s.flow)
      ; false, "Profile", input (fun s -> s.profile)
      ; false, "Endpoint", input (fun s -> s.endpoint)
      ]
      |> List.concat_map ~f:(fun (pickable, label, value) ->
        let label =
          if detail then label else Overview_tiles.fit_cells ~width:budget label
        in
        let padding = String.make (Int.max 0 (budget - cell_width label)) ' ' in
        let text = label ^ ": " ^ padding ^ Artifact_view.safe value in
        (if detail
         then wrap_cells ~width text
         else [ E.text (E.clip ~width (E.plain text)) ])
        |> List.map ~f:(fun text -> pickable, { Planned_run.role = Fact; text }))
    in
    let target_rows = target_rows @
      Option.to_list (Option.bind snapshot ~f:Launch_preferences.missing_target
                      |> Option.map ~f:(fun reason ->
                        false, { Planned_run.role = Warning; text = Artifact_view.safe reason })) in
    if H.has_target_picker host tile
    then (
      let targets, fields = List.split_while target_rows ~f:fst in
      let hint = "t: switch target · click chip/variant" in
      let text = E.text (E.clip ~width (E.plain hint)) in
      targets @ [ false, { Planned_run.role = Muted; text } ] @ fields)
    else target_rows
;;

let planned_formatted_rows ?indicator_frames host tile ~width =
  List.map (planned_target_rows host tile ~width) ~f:(fun (_, row) -> row, View.none)
  @ formatted_plan_history ?indicator_frames host tile ~width
;;

let planned_view_rows ?indicator_frames host tile ~width =
  planned_formatted_rows ?indicator_frames host tile ~width
  |> List.map ~f:(fun (row, icon) ->
    View.hcat
      [ icon
      ; View.text
          ~attrs:(Role.attrs host.H.appearance (planned_role row.Planned_run.role))
          row.text
      ]
    |> box ~width ~height:1)
;;

(* Use the rendered wrapping (including indicator space) for scroll bounds too. *)
let planned_rows host tile ~width =
  planned_formatted_rows host tile ~width |> List.map ~f:fst
;;

let job_indicator : Job.State.t -> Indicator.t = function
  | Queued -> Pending
  | Starting | Running -> Running
  | Complete -> Completed
  | Failed -> Failed
  | Cancelled -> Cancelled
;;

let indicator_role : Indicator.t -> Role.t = function
  | Running -> Running
  | Completed -> Success
  | Failed -> Failure
  | Pending | Cancelled | Skipped | Stale -> Warning
  | Ready | Linked -> Success
  | Cached
  | Independent
  | Expanded
  | Collapsed
  | Leaf
  | Top
  | Unavailable
  | Not_requested
  | Unknown
  | Pin
  | Artifact
  | Log
  | Seed
  | Report
  | Trace
  | Info -> Muted
;;

let simulation_annotations ?(now = Time_ns.now ()) ?identifier_width host data tile =
  match Testing_workspace.pane tile.W.Tile.kind with
  | Some pane ->
    (match pane with
     | Catalog ->
       [ Simulation_view.row ~hint:true "d discover | n/p suite | j/k case | x toggle"
       ; Simulation_view.row ~hint:true "a all | / filter | Enter launch | u accept"
       ]
     | Artifacts ->
       let view = H.simulation host tile.id in
       List.map
         (Option.to_list view.error @ Option.to_list view.notice)
         ~f:Simulation_view.row
     | _ -> [])
    @ Testing_workspace.rows
        ~now
        ~string_compression:(H.policy host tile).string_compression
        ?identifier_width
        (H.testing_state host tile.id)
        pane
        ~log_lines:data.log_lines
  | None ->
    Simulation_view.annotated_rows
      ~now
      ~string_compression:(H.policy host tile).string_compression
      (H.simulation host tile.id)
      ~log_lines:data.log_lines
;;

let annotated_physical_rows ?indicator_frames host ~width annotations =
  annotations
  |> List.concat_map
       ~f:
         (fun
           { Simulation_view.text; indicator = kind; value_start; selected; spans; target; _ } ->
         let role = Option.value_map kind ~default:Role.Foreground ~f:indicator_role in
         let icon =
           Option.value_map
             kind
             ~default:View.none
             ~f:(indicator_view ?indicator_frames host.H.appearance role)
         in
         let used = ref 0 in
         wrap_cells ~width:(width - View.width icon) text
         |> List.mapi ~f:(fun i text ->
           let length = cell_width text in
           let offset = !used in
           let boundaries =
             0
             :: length
             :: (Option.to_list value_start
                 @ List.concat_map spans ~f:(fun s -> [ s.start; s.start + s.length ])
                 |> List.map ~f:(fun n -> Int.clamp_exn (n - offset) ~min:0 ~max:length))
             |> List.dedup_and_sort ~compare:Int.compare
           in
           used := offset + length;
           let painted =
             List.zip_exn (List.drop_last_exn boundaries) (List.tl_exn boundaries)
             |> List.map ~f:(fun (start, stop) ->
               let position = offset + start in
               let tone =
                 List.find spans ~f:(fun s ->
                   s.start <= position && position < s.start + s.length)
               in
               let role =
                 match tone with
                 | Some { tone = Success; _ } -> Role.Success
                 | Some { tone = Warning; _ } -> Warning
                 | Some { tone = Failure; _ } -> Failure
                 | Some { tone = Running; _ } -> Running
                 | Some { tone = Muted; _ } -> Muted
                 | None ->
                   if Option.value_map value_start ~default:false ~f:(fun n ->
                        position >= n)
                   then role
                   else Foreground
               in
               View.text ~attrs:(Role.attrs host.appearance role) text
               |> View.crop ~l:start
               |> box ~width:(stop - start) ~height:1)
             |> View.hcat
           in
           let view =
             View.hcat
               [ (if i = 0
                  then icon
                  else View.rectangle ~width:(View.width icon) ~height:1 ())
               ; painted
               ]
             |> box ~width ~height:1
           in
           selected && i = 0, (target, view)))
;;

let annotated_view_rows ?indicator_frames host ~width annotations =
  annotated_physical_rows ?indicator_frames host ~width annotations
  |> List.map ~f:(fun (selected, (_, view)) -> selected, view)
;;

let simulation_physical_rows ?indicator_frames ?now host data tile ~width =
  simulation_annotations ?now ~identifier_width:(Int.max 1 (width - 8)) host data tile
  |> List.filter ~f:(fun row ->
    (not row.Simulation_view.hint) || (H.policy host tile).hints)
  |> annotated_physical_rows ?indicator_frames host ~width
;;

let simulation_view_rows_with_selection ?indicator_frames ?now host data tile ~width =
  simulation_physical_rows ?indicator_frames ?now host data tile ~width
  |> List.map ~f:(fun (selected, (_, view)) -> selected, view)
;;

let execution_annotations host data (tile : W.Tile.t) =
  let row = Simulation_view.row in
  let local = H.local host tile.id in
  let simulation_snapshots =
    Option.value_map host.registry ~default:[] ~f:(fun registry ->
      List.filter_map registry.tiles ~f:(fun candidate ->
        if W.Workspace_id.equal candidate.workspace tile.workspace
           && H.simulation_kind candidate.kind
        then (H.simulation host candidate.id).snapshot
        else None))
  in
  let job_label (job : Job.t) =
    let simulation =
      let detail_matches (snapshot : Simulation.Snapshot.t) =
        Option.exists snapshot.detail ~f:(fun detail -> Job_id.equal detail.job job.id)
      in
      Option.first_some
        (List.find simulation_snapshots ~f:detail_matches)
        (List.find simulation_snapshots ~f:(fun snapshot ->
           List.exists snapshot.attempts ~f:(fun summary ->
             Job_id.equal summary.job job.id)))
    in
    Presentation.execution_job_label ?simulation job
  in
  let project_tests = String.equal tile.kind "project-tests" in
  let jobs =
    List.filter data.jobs ~f:(fun job ->
      (not project_tests)
      || (String.equal job.kind.namespace "dune" && String.equal job.kind.name "test"))
  in
  let selected job =
    Option.equal String.equal local.cursor (Some (Job_id.to_string job.Job.id))
  in
  let identity =
    Presentation.identifiers
      ~compress:(H.policy host tile).string_compression
      (List.map jobs ~f:(fun job -> Job_id.to_string job.Job.id))
  in
  (if H.compact_summary host tile
   then [ row "Process results only" ]
   else
     List.map
       [ (if project_tests
          then "Project tests (not ASIC-run scoped)"
          else "Project execution attempts")
       ; "Environment: " ^ data.environment
       ; "Case details / progress: unavailable (generic command runner)"
       ]
       ~f:row)
  @ (if (H.policy host tile).hints then [ row ~hint:true "b build | t test" ] else [])
  @ Option.value_map (List.find jobs ~f:selected) ~default:[] ~f:(fun job ->
    List.map
      (("Kind: " ^ Job.Kind.to_string job.kind) :: Presentation.job_outcome_lines job)
      ~f:row
    @
    if project_tests
    then List.map ("ATTEMPT OUTPUT" :: List.take (data.log_lines job.id) 4) ~f:row
    else [])
  @ List.map jobs ~f:(fun job ->
    let prefix =
      (if selected job then ">" else " ") ^ identity (Job_id.to_string job.id) ^ "  "
    in
    let status = Job.State.to_string job.state in
    let tone : Simulation_view.tone =
      match job.state with
      | Complete -> Success
      | Failed -> Failure
      | Starting | Running -> Running
      | Queued | Cancelled -> Warning
    in
    row
      ~selected:(selected job)
      ~target:(Job job.id)
      ~indicator:(job_indicator job.state)
      ~spans:[ Simulation_view.span ~start:(cell_width prefix) tone status ]
      (prefix ^ status ^ "  " ^ job_label job))
;;

let simulation_view_rows ?indicator_frames ?now host data tile ~width =
  simulation_view_rows_with_selection ?indicator_frames ?now host data tile ~width
  |> List.map ~f:snd
;;

let simulation_cursor_pane kind =
  match Testing_workspace.pane kind with
  | Some (Catalog | Attempts | Cases | Artifacts) -> true
  | Some (Detail | Logs) | None -> false
;;

(** Display-cell wrapping precedes viewport selection. Only typed cursor metadata
    participates; provider text and checkbox membership cannot move the viewport. *)
let ensure_visible ~start ~height ~length ~selected =
  let maximum = Int.max 0 (length - Int.max 1 height) in
  let start = Int.clamp_exn start ~min:0 ~max:maximum in
  match selected with
  | Some cursor when height > 0 ->
    Int.clamp_exn
      (if cursor < start
       then cursor
       else if cursor >= start + height
       then cursor - height + 1
       else start)
      ~min:0
      ~max:maximum
  | _ -> start
;;

let%test_unit "cursor viewport keeps its origin until the cursor crosses a boundary" =
  let follow start cursor =
    ensure_visible ~start ~height:6 ~length:100 ~selected:(Some cursor)
  in
  assert (follow 20 20 = 20);
  assert (follow 20 25 = 20);
  assert (follow 20 19 = 19);
  assert (follow 20 26 = 21);
  assert (ensure_visible ~start:200 ~height:6 ~length:100 ~selected:None = 94);
  assert (ensure_visible ~start:0 ~height:0 ~length:0 ~selected:None = 0)
;;

let simulation_viewport_start host tile ~height rows =
  let local = H.local host tile.W.Tile.id in
  let selected =
    if simulation_cursor_pane tile.kind && local.follow
    then List.findi rows ~f:(fun _ (selected, _) -> selected) |> Option.map ~f:fst
    else None
  in
  ensure_visible ~start:local.scroll ~height ~length:(List.length rows) ~selected
;;

let run_candidates data ~filter =
  let substring = String.lowercase filter in
  List.filter data.runs ~f:(fun (run, status) ->
    String.is_substring (String.lowercase (run_label run ^ " " ^ status)) ~substring)
;;

let run_cursor host tile =
  Option.first_some
    (H.local host tile.W.Tile.id).cursor
    (Option.map (tile_run host tile) ~f:run_label)
;;

let run_page host tile ~height candidates =
  let local = H.local host tile.W.Tile.id in
  let selected = run_cursor host tile in
  let index =
    List.findi candidates ~f:(fun _ (run, _) ->
      Option.equal String.equal selected (Some (run_label run)))
    |> Option.value_map ~default:0 ~f:fst
  in
  let available = Int.min height (H.policy host tile).run_selector_rows in
  let start =
    Int.clamp_exn
      local.scroll
      ~min:(Int.max 0 (index - Int.max 1 available + 1))
      ~max:index
  in
  selected, start, List.take (List.drop candidates start) (Int.max 0 available)
;;

let local_menu_run host data tile =
  if not (String.equal tile.W.Tile.kind "run-selector")
  then None
  else
    let candidates = run_candidates data ~filter:(H.local host tile.id).filter in
    Option.bind (run_cursor host tile) ~f:(fun cursor ->
      List.find_map candidates ~f:(fun (run, _) ->
        Option.some_if (String.equal (run_label run) cursor) run))
;;

let menu_button appearance label =
  View.text ~attrs:(Role.attrs appearance Surface @ [ Attr.bold ]) (" " ^ label ^ " ▾ ")
;;

let project_prefix appearance ~width =
  let button = menu_button appearance "Project" in
  if width >= View.width button + 5
  then View.hcat [ button; View.text ~attrs:(Role.attrs appearance Border) "│" ]
  else View.none
;;

let browse_index values ~cursor ~delta =
  let index =
    Option.bind cursor ~f:(fun cursor ->
      List.findi values ~f:(fun _ value -> String.equal cursor value) |> Option.map ~f:fst)
    |> Option.value ~default:(if delta > 0 then -1 else 1)
  in
  Int.max 0 (Int.min (List.length values - 1) (index + delta))
;;

let rows host data tile ~width ~height =
  let local = H.local host tile.W.Tile.id in
  let scope =
    match host.H.registry with
    | None -> None
    | Some s -> W.resolve_tile s tile.id |> Result.ok |> Option.bind ~f:(fun r -> r.run)
  in
  let run_rows () =
    let candidates = run_candidates data ~filter:local.filter in
    let selected, _, page = run_page host tile ~height candidates in
    let status_width =
      Int.min
        (Int.max 0 (width / 3))
        (List.fold candidates ~init:0 ~f:(fun n (_, status) ->
           Int.max n (cell_width status)))
    in
    page
    |> List.map ~f:(fun (run, label) ->
      run_selector_row
        ~string_compression:(H.policy host tile).string_compression
        ~population:(List.map data.runs ~f:(fun (r, _) -> r.id))
        ~width
        ~status_width
        ~cursor:(Option.equal String.equal selected (Some (run_label run)))
        ~active:(Option.equal Run_ref.equal scope (Some run))
        run
        label)
  in
  let jobs =
    if String.equal tile.kind "project-tests"
    then
      List.filter data.jobs ~f:(fun job ->
        String.equal job.kind.namespace "dune" && String.equal job.kind.name "test")
    else data.jobs
  in
  let selected =
    Option.bind local.cursor ~f:(fun id ->
      List.find jobs ~f:(fun job -> String.equal (Job_id.to_string job.id) id))
  in
  let rows =
    match inspection_explorer host tile, artifact_inspector host tile with
    | Some view, _ ->
      Inspection_view.rows view ~width ~height
      |> List.mapi ~f:(fun i row ->
        if i = 0
        then
          indicator_label
            host.appearance.icons
            (inspection_indicator
               ~reading:(evidence_reading data ~views:[ view ] ~runs:[])
               view)
            row
        else row)
    | None, Some view -> Artifact_view.rows view ~width ~height
    | None, None ->
      (match tile.kind with
       | "hierarchy" ->
         [ local.hierarchy_status; "Tested top / DUT: unknown" ]
         @ Option.value_map local.hierarchy ~default:[] ~f:(fun view ->
           Hierarchy_view.rows ~icons:host.appearance.icons view ~height)
       | "planned-run" ->
         planned_rows host tile ~width |> List.map ~f:(fun row -> row.Planned_run.text)
       | "workloads" ->
         Workloads_view.rows
           local.workloads
           ~asic:data.asic
           ~filter:local.filter
           ~width
           ~height
         |> List.map ~f:E.text
       | "resources" | "resource-detail" | "resource-summary" ->
         resource_page host data tile ~width ~height |> List.map ~f:(fun (_, r) -> E.text r)
       | "run-selector" -> run_rows ()
       | kind when P.Waveforms.is_pane kind ->
         (match H.waveform_pin host tile.workspace with
          | None ->
            [ "No retained VCD selected" ]
            @
            if (H.policy host tile).hints
            then
              [ "In Testing, select a VCD and press W"; "Space c c: searchable commands" ]
            else []
          | Some pin
            when P.Waveforms.equal_pane (Option.value_exn (P.Waveforms.pane kind)) Session
            ->
            [ Artifact_view.safe pin.project_key
              ^ " · "
              ^ Artifact_view.safe pin.artifact.label
            ; "Attempt "
              ^ Artifact_view.safe pin.artifact.attempt_id
              ^ " · "
              ^ Artifact_view.safe
                  (Option.value pin.artifact.case_id ~default:"attempt artifact")
            ]
          | Some pin ->
            [ "Pinned VCD: " ^ Artifact_view.safe pin.artifact.label
            ; "Attempt: " ^ Artifact_view.safe pin.artifact.attempt_id
            ; "Retained waveform data unavailable; reload exact pinned artifact"
            ])
       | kind when Option.is_some (Timing_workspace.pane kind) ->
         (match Timing_workspace.pane kind, H.timing host tile with
          | Some pane, Some view ->
            Timing_workspace.rows
              ~presentation:(H.policy host tile)
              ~pane
              ~scroll:local.scroll
              ~width
              ~height
              view
          | _ ->
            [ "No matching Timing investigation"
            ; "Use Inspect timing paths for this exact run"
            ])
       | kind when H.simulation_kind kind ->
         simulation_annotations host data tile
         |> List.filter ~f:(fun row ->
           (not row.Simulation_view.hint) || (H.policy host tile).hints)
         |> List.map ~f:(fun row -> row.Simulation_view.text)
         |> List.concat_map ~f:(wrap_cells ~width)
       | "execution" | "project-tests" ->
         execution_annotations host data tile
         |> List.map ~f:(fun row -> row.Simulation_view.text)
       | "logs" ->
         [ "Project job output: "
           ^ Option.value local.cursor ~default:"select attempt with j/k"
         ; (if local.follow then "FOLLOW" else "PAUSED — palette: Resume log follow")
         ]
         @ Option.value_map selected ~default:[ "No attempt selected" ] ~f:(fun job ->
           data.log_lines job.id)
       | "project" ->
         Option.value_map data.project ~default:[ "No project open" ] ~f:(fun project ->
           [ project.name
           ; Project_root.to_absolute_path project.root
           ; "Environment: " ^ data.environment
           ])
       | "navigation" ->
         [ "Space c c: searchable commands"
         ; "Tab / Shift-Tab: next / previous tile"
         ; "1-9: workspaces; j/k browse; Enter select"
         ; "[ / ]: scroll; palette: resume log follow"
         ; "Timing/checks/physical/finalization: Enter/e evidence; Esc overview"
         ; "Palette: add/hide/restore/move/resize/zoom; unlink/relink; pin/follow"
         ; data.status
         ]
       | "asic" -> List.concat_map data.asic_lines ~f:(wrap_cells ~width)
       | "synthesis" ->
         (match scope with
          | None -> [ "No run selected — use a run selector" ]
          | Some run ->
            ignore (run : Run_ref.t);
            semantic_rows host data tile ~width ~height
            |> Option.value ~default:[]
            |> List.map ~f:E.text)
       | kind when Terminal_result_view.supports kind ->
         (match scope with
          | None -> [ "No run selected — use a run selector" ]
          | Some run ->
            ignore (run : Run_ref.t);
            semantic_rows host data tile ~width ~height
            |> Option.value ~default:[]
            |> List.map ~f:E.text)
       | kind ->
         (match scope with
          | None -> [ "No run selected — use a run selector" ]
          | Some run -> ("Run: " ^ run_label run) :: data.run_lines run kind))
  in
  if Option.is_some local.artifacts
     || Option.is_some local.inspection
     || String.equal tile.kind "synthesis"
     || Resources_view.is_kind tile.kind
     || String.equal tile.kind "resource-detail"
     || Terminal_result_view.supports tile.kind
     || Option.is_some (Timing_workspace.pane tile.kind)
     || (String.equal tile.kind "logs" && local.follow)
  then rows
  else if String.equal tile.kind "run-selector"
  then rows
  else if H.simulation_kind tile.kind
  then List.drop rows (Int.min local.scroll (Int.max 0 (List.length rows - height)))
  else List.drop rows local.scroll
;;

let observation_banner host data tile ~width =
  if String.equal tile.W.Tile.kind "stage-checklist"
  then
    Option.bind (tile_run host tile) ~f:(stopped_observation data)
    |> Option.value_map ~default:[] ~f:(fun _ -> wrap_cells ~width observation_qualifier)
  else []
;;

let checklist_page host data tile ~height rows =
  let hints = checklist_hints host data tile in
  let evidence_height = Int.min 3 (Int.max 1 (height - 1)) in
  let hint_height = Int.min (List.length hints) (Int.max 0 (height - evidence_height)) in
  let available = Int.max 0 (height - hint_height) in
  let selected =
    List.findi rows ~f:(fun _ r -> r.Overview_tiles.active)
    |> Option.value_map ~default:0 ~f:fst
  in
  let start =
    Int.clamp_exn
      (H.local host tile.id).scroll
      ~min:(Int.max 0 (selected - Int.max 1 available + 1))
      ~max:selected
  in
  hints, hint_height, available, List.drop rows start
;;

let workspace_page host tile ~width ~height rows =
  let chips =
    List.mapi rows ~f:(fun i row ->
      let i =
        Option.bind host.H.registry ~f:(fun registry ->
          List.findi registry.workspaces ~f:(fun _ w ->
            Option.equal W.Workspace_id.equal row.Overview_tiles.workspace (Some w.id)))
        |> Option.value_map ~default:i ~f:fst
      in
      let role =
        if row.active
        then Role.Active_tab
        else if Overview_tiles.Role.equal row.role Active
        then Selection
        else Inactive_tab
      in
      ( View.text
          ~attrs:(Role.attrs host.appearance role)
          (sprintf
             " %s%d %s%s "
             (if row.active then "[" else " ")
             (i + 1)
             row.label
             (if row.active then "]" else " "))
      , row.workspace ))
  in
  if List.sum (module Int) chips ~f:(fun (view, _) -> View.width view) <= width
  then `Strip chips
  else if height = 1
  then (
    (* A one-line workspace strip never turns into a one-entry vertical list.
       Keep the browsed tab visible while retaining as many neighbours as fit. *)
    let cursor = Option.map (H.workspace_cursor host tile.W.Tile.id) ~f:(fun w -> w.id) in
    let selected =
      List.findi chips ~f:(fun _ (_, id) -> Option.equal W.Workspace_id.equal id cursor)
      |> Option.value_map ~default:0 ~f:fst
    in
    let rec trim remaining count used =
      match remaining with
      | (view, _) :: rest when count > 0 && used > width ->
        trim rest (count - 1) (used - View.width view)
      | _ -> remaining
    in
    let used =
      List.take chips (selected + 1)
      |> List.sum (module Int) ~f:(fun (v, _) -> View.width v)
    in
    `Strip (trim chips selected used))
  else (
    let selected =
      Option.map (H.workspace_cursor host tile.W.Tile.id) ~f:(fun w -> w.id)
    in
    let index =
      List.findi rows ~f:(fun _ row ->
        Option.equal W.Workspace_id.equal row.Overview_tiles.workspace selected)
      |> Option.value_map ~default:0 ~f:fst
    in
    `Rows
      (List.drop rows (Int.max 0 (index - height + 2))
       |> Fn.flip List.take (Int.max 1 (height - 1))))
;;

let inspection_physical_rows ~width rows =
  List.concat_map rows ~f:(fun entry ->
    Overview_tiles.inspection_lines [ entry ]
    |> List.concat_mapi ~f:(fun i line ->
      List.map (wrap_cells ~width line) ~f:(fun text ->
        text, if i = 0 then entry.cursor_id else None)))
;;

let workspace_tab_at host data tile ~width ~height ~column ~row =
  let local = H.local host tile.W.Tile.id in
  if not (String.equal tile.kind "workspace-tabs")
     || local.utility_detail || Option.is_some local.artifacts || Option.is_some local.inspection
     || column < 0 || column >= width || row < 0 || row >= height
  then None
  else
    Option.bind (utility_rows host data tile) ~f:(fun rows ->
      let offset = View.width (project_prefix host.appearance ~width) in
      let column = column - offset in
      if column < 0
      then None
      else (
        match workspace_page host tile ~width:(width - offset) ~height rows with
        | `Strip chips -> if row = 0 then Overview_tiles.chip_at chips ~column else None
        | `Rows page -> List.nth page row |> Option.bind ~f:(fun r -> r.workspace)))
;;

let mixed_checklist host data tile =
  Option.exists (tile_run host tile) ~f:(fun run ->
    List.exists (Overview_tiles.checklist_items ~asic:data.asic ~run) ~f:(function
      | Timing_analysis _ | Elaboration_preparation -> true
      | Catalog_endpoint _ | Physical_stage _ -> false))
;;

let stage_strip_model ?now host tile ~run ~width stages =
  let selected_id =
    H.stage_cursor (H.local host tile.W.Tile.id) ~run ~stages
    |> Option.map ~f:(fun stage -> stage.Asic.Stage.id)
  in
  Overview_tiles.Stage_strip.model
    ?now
    ~appearance:host.appearance
    ~width
    ~run
    ~selected_id
    stages
;;

let stage_strip_hints host data tile ~height =
  let hints = checklist_hints host data tile in
  hints, Int.min (List.length hints) (Int.max 0 (height - 2))
;;

let select_more_body_row host data tile ~width ~height ~column ~row =
  let local = H.local host tile.W.Tile.id in
  if column < 0
     || column >= width
     || row < 0
     || row >= height
     || Option.is_some local.artifacts
     || Option.is_some local.inspection
  then host
  else (
    let use opt f = Option.value_map opt ~default:host ~f in
    let at xs i = if i < 0 then None else List.nth xs i in
    match tile.kind with
    | "synthesis"
      when Synthesis_view.Mode.equal (Synthesis_view.State.mode local.synthesis) Cells ->
      use (tile_run host tile) (fun run ->
        let height = cells_source_height ~hints:(H.policy host tile).hints height in
        use
          (Synthesis_view.select_cell_row
             local.synthesis
             ~summary:(data.summary run)
             ~filter:local.filter
             ~width
             ~height
             ~row)
          (fun synthesis -> H.set_local host tile.id { local with synthesis }))
    | "preparation" | "stage-checklist" ->
      use (utility_rows host data tile) (fun rows ->
        match tile.kind with
        | "preparation" ->
          let id =
            if local.utility_detail
            then
              at (List.drop (inspection_physical_rows ~width rows) local.scroll) row
              |> Option.bind ~f:snd
            else
              at (List.drop rows local.scroll) row
              |> Option.bind ~f:(fun r -> r.cursor_id)
          in
          use id (fun id ->
            H.set_local host tile.id { local with cursor = Some id; scroll = 0 })
        | "stage-checklist" when not local.utility_detail ->
          let banner = List.length (observation_banner host data tile ~width) in
          let height = Int.max 0 (height - banner)
          and row = row - banner in
          let run = tile_run host tile in
          let target =
            match H.horizontal_stages host tile, run with
            | true, Some run ->
              let appearance = host.H.appearance
              and attrs = utility_attrs host.appearance in
              let chips =
                if mixed_checklist host data tile
                then
                  Overview_tiles.checklist_strip_lines
                    ~appearance
                    ~attrs
                    ~width
                    ~height
                    rows
                else (
                  let stages = Overview_tiles.observed_stages ~asic:data.asic ~run in
                  let model = stage_strip_model host tile ~run ~width stages in
                  let _, hints = stage_strip_hints host data tile ~height in
                  Overview_tiles.Stage_strip.chip_lines
                    ~appearance
                    ~attrs
                    ~width
                    ~height:(height - hints)
                    model)
              in
              at chips row |> Option.bind ~f:(Overview_tiles.chip_at ~column)
            | _ ->
              let _, hints, _, page = checklist_page host data tile ~height rows in
              at page (row - hints) |> Option.bind ~f:(fun r -> r.cursor_id)
          in
          use target (fun id ->
            H.set_local
              host
              tile.id
              { local with cursor = Some id; stage_run = tile_run host tile; scroll = 0 })
        | _ -> host)
    | _ -> host)
;;

let panel_geometry host tile ~width ~height =
  let policy = H.policy host tile in
  let appearance = host.H.appearance in
  Panel.geometry
    ~framed:(policy.frame && framed appearance ~width ~height)
    ~width
    ~height
    ~horizontal_padding:policy.padding
    ~vertical_padding:0
;;

let timing_paths_page (view : Timing_workspace.t) ~height =
  let visible = Inspection_view.visible view in
  let position =
    List.findi visible ~f:(fun _ row ->
      Option.equal String.equal view.selected (Some row.Asic_inspection.Row.id))
    |> Option.value_map ~default:0 ~f:fst
  in
  let heading_rows = Int.min 4 (Int.max 0 (height - 1)) in
  let capacity = Int.max 1 (height - heading_rows) in
  visible, heading_rows, List.take (List.drop visible (position / capacity * capacity)) capacity
;;

(** Physical rows carry their original target through wrapping. Plain annotations
    (hints, logs, outcome detail) never borrow an adjacent target. *)
let select_body_row ?(column = 0) host data tile ~width ~height ~row =
  let local = H.local host tile.W.Tile.id in
  if width <= 0
     || row < 0
     || row >= height
     || Option.is_some local.artifacts
     || Option.is_some local.inspection
  then host
  else if H.has_target_picker host tile
  then (
    match List.nth (planned_target_rows host tile ~width) (local.scroll + row) with
    | Some (true, _) -> H.open_target_picker host tile
    | _ -> host)
  else if String.equal tile.kind "workloads"
  then (
    match List.nth (Workloads_view.page_with_targets local.workloads ~asic:data.asic ~filter:local.filter ~width ~height) row with
    | Some (Some path, _) when not (Option.equal String.equal local.workloads.selected (Some path)) ->
      H.set_local host tile.id { local with workloads = Workloads_view.browse_result local.workloads (Some path) }
    | _ -> host)
  else if H.resource_pane tile.kind
  then (
    match H.resource_owner host tile with
    | None -> host
    | Some owner ->
      let local = H.local host owner.id in
      let view = Resources_view.reconcile local.resources ~run:(tile_run host owner) ~filter:local.filter data.asic in
      let page = resource_page host data tile ~width ~height in
      (match List.nth page row with
       | Some (Some (`Resource id), _) when not (Option.equal String.equal view.selected (Some id)) ->
         H.set_local host owner.id { local with resources = Resources_view.browse_resource { view with mode = Table } (Some id) }
       | Some (Some (`Source id), _) when not (Option.equal String.equal view.artifact (Some id)) ->
         H.set_local host owner.id { local with resources = Resources_view.browse_source view (Some id) }
       | _ -> host))
  else if String.equal tile.kind "timing-paths"
  then (
    match H.timing host tile with
    | None -> host
    | Some view ->
      let _, header, page = timing_paths_page view ~height in
      (match List.nth page (row - header) with
       | Some path when not (Option.equal String.equal view.selected (Some path.id)) ->
         H.set_timing
           host
           tile
           { view with
             selected = Some path.id
           ; requested = None
           ; detail = None
           ; info = false
           ; scroll = 0
           ; operation_key = None
           ; error = None
           ; pending_error = None
           }
       | _ -> host))
  else if String.equal tile.kind "run-selector"
  then (
    let _, start, page =
      run_page host tile ~height (run_candidates data ~filter:local.filter)
    in
    match List.nth page row with
    | None -> host
    | Some (run, _) ->
      H.set_local
        host
        tile.id
        { local with cursor = Some (run_label run); scroll = start })
  else (
    let target =
      let at rows offset =
        List.nth (List.drop rows offset) row
        |> Option.bind ~f:(fun (_, (target, _)) -> target)
      in
      if simulation_cursor_pane tile.kind
      then (
        let rows = simulation_physical_rows host data tile ~width in
        at rows (simulation_viewport_start host tile ~height rows))
      else if List.mem [ "execution"; "project-tests" ] tile.kind ~equal:String.equal
      then
        at
          (annotated_physical_rows host ~width (execution_annotations host data tile))
          local.scroll
      else None
    in
    match target with
    | None -> select_more_body_row host data tile ~width ~height ~column ~row
    | Some (Job id) ->
      H.set_local
        host
        tile.id
        { local with cursor = Some (Job_id.to_string id); scroll = 0 }
    | Some (Catalog_suite id) -> H.select_testing_suite host tile.id id
    | Some target ->
      let host =
        H.update_testing host tile.id (fun state ->
          match target with
          | Simulation_view.Attempt id ->
            if Option.equal String.equal (Testing_workspace.view state).attempt (Some id)
            then state
            else (
              let state = Testing_workspace.select_attempt state id in
              Testing_workspace.set_view
                state
                { (Testing_workspace.view state) with busy = false })
          | Case id -> Testing_workspace.select_case state id
          | Artifact id -> Testing_workspace.select_artifact state id
          | Catalog_case id ->
            Testing_workspace.update_catalog state (fun c ->
              Simulation_catalog.select_case c id)
          | Catalog_suite _ | Job _ -> state)
      in
      H.set_local host tile.id { (H.local host tile.id) with follow = true })
;;

let body_bounds host tile (g : Panel.geometry) =
  let policy = H.policy host tile in
  let header =
    Bool.to_int
      (g.border = 0 && (T.show_title policy || T.show_badge policy (H.binding_kind tile)))
    + Bool.to_int policy.run_reference
  in
  { W.Geometry.x = g.border + g.horizontal_padding
  ; y = g.border + g.vertical_padding + header
  ; width = g.content_width
  ; height = Int.max 0 (g.content_height - header)
  }
;;

let body_geometry host tile ~width ~height =
  let g = panel_geometry host tile ~width ~height in
  let body = body_bounds host tile g in
  g.inner_width, g.inner_height, g.horizontal_padding, body.width, body.height
;;

let timing_status_role (row : Asic_inspection.Row.t) =
  match String.lowercase row.status with
  | "violated" | "fail" | "failed" -> Role.Failure
  | "met" | "ok" | "pass" | "passed" -> Success
  | "pending" | "unknown" | "unavailable" -> Warning
  | _ -> Foreground
;;

(* C owns prefix content and width budgeting. Apply the same final sanitation/wrapping as
   [Timing_workspace.rows], carrying only its explicit roles across wrapped lines. *)
let timing_line_role : Timing_workspace.line_role -> Role.t = function
  | Selected -> Selection
  | Metric -> Metric
  | Metadata -> Muted
  | Pending -> Warning
  | Failure -> Failure
  | Success -> Success
  | Source -> Focus
;;

let timing_semantic_prefix ?(presentation = T.defaults) ~pane ~width view =
  Timing_workspace.semantic_prefix ~presentation ~pane ~width view
  |> List.concat_map ~f:(fun (role, line) ->
    Artifact_view.wrap ~width (Artifact_view.safe line)
    |> List.map ~f:(fun line -> timing_line_role role, line))
;;

(* Use typed fields and selection, never keywords found in producer report text. Paths
   retains C's four-row viewport budget; tiny panes give selection priority. *)
let timing_body
  ?(presentation = T.defaults)
  ?indicator_frames
  ?(reading = false)
  appearance
  ~pane
  ~scroll
  ~width
  ~height
  (view : Timing_workspace.t)
  =
  let source = Timing_workspace.rows ~presentation ~pane ~scroll ~width ~height view in
  let text role value =
    View.text ~attrs:(Role.attrs appearance role) (Artifact_view.safe value)
  in
  match pane with
  | Timing_workspace.Paths ->
    let visible, heading_rows, page = timing_paths_page view ~height in
    let all = Option.value ~default:"ALL" in
    let sort =
      match view.sort with
      | Numeric_ascending -> "value ↑"
      | Numeric_descending -> "value ↓"
      | Name -> "name"
    in
    let count =
      sprintf
        "%d paths · %s%s"
        (List.length visible)
        sort
        (if view.near then " · ≤1ns" else "")
    in
    let observation, observation_role =
      match view.index with
      | None -> "Explicit Inspect / refresh required", Role.Warning
      | Some i ->
        ( ((if i.cached_unverified then "Cached unverified" else "Verified observation")
           ^ if i.truncated then " · TRUNCATED" else "")
        , if i.cached_unverified || i.truncated then Role.Warning else Muted )
    in
    let header =
      [ text
          (if view.pasting then Warning else Focus)
          (if view.editing || view.pasting
           then (if view.pasting then "Paste filter: " else "/ ") ^ view.filter ^ "|"
           else "Filter: " ^ if String.is_empty view.filter then "ALL" else view.filter)
      ; text
          (if Option.is_some view.filter_notice then Warning else Muted)
          (Option.value
             view.filter_notice
             ~default:
               (sprintf
                  "Corner %s · Group %s · Producer %s"
                  (all view.corner)
                  (all view.group)
                  (all view.producer)))
      ; View.hcat
          [ text Metric (count ^ " · ")
          ; indicator_view
              ?indicator_frames
              appearance
              observation_role
              (inspection_indicator ~reading view)
          ; text observation_role observation
          ]
      ; text Muted "Path / endpoint                         Value · reported status"
      ]
    in
    let header = List.take header heading_rows in
    let path row =
      let selected =
        Option.equal String.equal view.selected (Some row.Asic_inspection.Row.id)
      in
      let numeric =
        Option.value_map row.value ~default:"—" ~f:(fun value ->
          Presentation.decimal ~places:presentation.decimal_places value)
        ^ Option.value_map row.unit_ ~default:"" ~f:(fun unit_ -> " " ^ unit_)
      in
      let suffix = numeric ^ " · " ^ row.status in
      let suffix_width = Int.min (Int.max 0 (width / 2)) (cell_width suffix) in
      let name_width = Int.max 0 (width - suffix_width - 3) in
      let endpoint key = List.Assoc.find row.fields key ~equal:String.equal in
      let label =
        match endpoint "startpoint", endpoint "endpoint" with
        | Some start, Some finish -> start ^ " → " ^ finish ^ " · " ^ row.name
        | _, Some finish -> row.name ^ " · endpoint=" ^ finish
        | Some start, _ -> row.name ^ " · startpoint=" ^ start
        | _ -> row.name
      in
      let name = fit_label ~width:name_width (Artifact_view.safe label) in
      View.hcat
        [ text (if selected then Selection else Muted) (if selected then "> " else "  ")
        ; text
            (if selected then Selection else Foreground)
            (name ^ String.make (Int.max 0 (name_width - cell_width name)) ' ' ^ " ")
        ; text (timing_status_role row) (fit_label ~width:suffix_width suffix)
        ]
    in
    let body =
      if List.is_empty page
      then [ text Warning (Timing_workspace.empty_paths_message view) ]
      else List.map page ~f:path
    in
    let error = Option.first_some view.error view.pending_error in
    let header =
      match error, header with
      | Some error, _ :: rest -> text Failure error :: rest
      | _ -> header
    in
    View.vcat (header @ body) |> box ~width ~height |> colored appearance Foreground
  | Detail | Context ->
    (* Scroll offsets are those of C's actual wrapped output. Only the canonical semantic
       prefix receives role styling; provider payload is always neutral. *)
    let full =
      Timing_workspace.rows
        ~presentation
        ~pane
        ~scroll:0
        ~width
        ~height:Int.max_value
        view
    in
    let start = Int.min scroll (Int.max 0 (List.length full - height)) in
    let prefix =
      timing_semantic_prefix ~presentation ~pane ~width view |> Array.of_list
    in
    List.mapi source ~f:(fun i line ->
      let offset = start + i in
      if offset < Array.length prefix && String.equal (snd prefix.(offset)) line
      then (
        let role = fst prefix.(offset) in
        match role, String.lsplit2 line ~on:':' with
        | Focus, Some (label, value) ->
          View.hcat [ text Muted (label ^ ":"); text Focus value ]
        | _ -> text role line)
      else text Foreground line)
    |> View.vcat
    |> box ~width ~height
    |> colored appearance Foreground
;;

(** The transport owner supplies waveform bodies to avoid a Host_view/Waveform_view
    dependency cycle. The host retains frame, title, clipping and palette ownership. *)
let tile_view
  ?(now = Time_ns.now ())
  ?indicator_frames
  ?render_pane
  ?horizontal_stages
  host
  data
  tile
  ~width
  ~height
  =
  let appearance = host.H.appearance in
  let local = H.local host tile.W.Tile.id in
  let indicator_frames =
    if List.mem [ "stage-checklist"; "synthesis" ] tile.kind ~equal:String.equal
       && not (Option.exists (tile_run host tile) ~f:(run_has_producer data))
    then None
    else indicator_frames
  in
  let policy = H.policy host tile in
  let show_title = T.show_title policy in
  let show_badge = T.show_badge policy (H.binding_kind tile) in
  let focused =
    Option.value_map host.H.focus ~default:false ~f:(W.Tile_id.equal tile.id)
  in
  let binding =
    if String.equal tile.kind "workloads"
    then "explicit workload evidence"
    else if String.equal tile.kind "resource-detail" then "linked resource"
    else if Resources_view.is_kind tile.kind && Option.is_some local.resources.explicit
    then "explicit resource source"
    else if Testing_workspace.is_pane tile.kind
            || P.Waveforms.is_pane tile.kind
            || String.equal tile.kind "hierarchy"
    then "project"
    else (
      match tile.binding with
      | Pin_run run ->
        let glyph = Indicator.text appearance.icons Pin in
        (if String.is_empty glyph then "" else glyph ^ " ") ^ "PIN " ^ run_label run
      | Follow -> if H.project_scoped_kind tile.kind then "project" else "follow")
  in
  let _, _, _, body_width, body_height = body_geometry host tile ~width ~height in
  let observation_banner = observation_banner host data tile ~width:body_width in
  let full_body_height = body_height in
  let banner_height = Int.min body_height (List.length observation_banner) in
  let body_height = Int.max 0 (body_height - banner_height) in
  let geometry = panel_geometry host tile ~width ~height in
  let compact = compact_rows ~now host data tile in
  let semantic =
    if Option.is_some compact
    then None
    else semantic_rows host data tile ~width:body_width ~height:body_height
  in
  let semantic =
    if Option.is_none compact
       && Overview_summary.supports tile.kind
       && (not local.utility_detail)
       && Option.is_none local.inspection
       && Option.is_none local.artifacts
       && (not local.terminal_result.detail)
       && ((not (String.equal tile.kind "synthesis"))
           || Synthesis_view.Mode.equal
                (Synthesis_view.State.mode local.synthesis)
                Summary)
    then
      Option.value_map (tile_run host tile) ~default:semantic ~f:(fun run ->
        let time =
          Overview_summary.rows
            ~now
            ~decimal_places:policy.decimal_places
            ~kind:tile.kind
            ~run
            ~summary:(data.summary run)
            ~stages:(Overview_tiles.observed_stages ~asic:data.asic ~run)
            ~finalizations:
              (Option.value_map data.asic ~default:[] ~f:(fun s ->
                 s.Asic.Snapshot.finalizations))
            ()
          |> List.find_exn ~f:(fun row -> String.equal row.Overview_tiles.label "Time")
        in
        Some
          (E.plain ("Time: " ^ time.value)
           :: Option.value_or_thunk semantic ~default:(fun () ->
             List.map
               (rows host data tile ~width:body_width ~height:body_height)
               ~f:E.plain)))
    else semantic
  in
  let rows =
    match compact, semantic with
    | Some rows, _ ->
      List.map rows ~f:(fun row -> row.Overview_tiles.label ^ ": " ^ row.value)
    | None, Some rows -> List.map rows ~f:E.text
    | None, None -> rows host data tile ~width:body_width ~height:body_height
  in
  let rows =
    if String.equal tile.kind "logs" && local.follow
    then
      List.take rows 2
      @ (List.drop rows 2
         |> List.rev
         |> Fn.flip List.take (Int.max 0 (body_height - 2))
         |> List.rev)
    else rows
  in
  let header =
    if show_title || show_badge
    then (
      let title =
        if Terminal_result_view.supports tile.kind && local.terminal_result.detail
        then tile.kind ^ "/evidence"
        else if not (String.equal tile.kind "synthesis")
        then (
          match tile.kind with
          | "live-status" -> "session"
          | "workspace-tabs" -> "workspaces"
          | "stage-checklist" -> "stage checklist"
          | "timing-paths" -> "timing · paths"
          | "timing-detail" -> "timing · selected path"
          | "timing-context" -> "timing · provenance"
          | kind when P.Waveforms.is_pane kind ->
            P.Waveforms.title (Option.value_exn (P.Waveforms.pane kind))
          | "run-selector" ->
            let total = List.length (run_candidates data ~filter:local.filter) in
            sprintf
              "runs %d/%d (cap %d)"
              (Int.min total (Int.min body_height policy.run_selector_rows))
              total
              policy.run_selector_rows
          | kind -> kind)
        else (
          match Synthesis_view.State.mode local.synthesis with
          | Summary -> "synthesis"
          | Cells -> "synthesis/cells"
          | Details -> "synthesis/detail"
          | Metrics -> "synthesis/metrics"
          | Evidence -> "synthesis/evidence")
      in
      (* Host-generated titles stay lowercase; binding badges retain exact run IDs. Focus
         belongs to border styling, never a decorative title prefix. *)
      let title =
        if not show_title
        then ""
        else if studio appearance
        then "[ " ^ title ^ " ]"
        else title
      in
      let room =
        if geometry.border > 0 then Int.max 0 (geometry.inner_width - 2) else body_width
      in
      let badge =
        if not show_badge then "" else if show_title then "[" ^ binding ^ "]" else binding
      in
      let badge = fit_label ~width:room badge in
      let title =
        fit_label
          ~width:
            (Int.max 0 (room - cell_width badge - if String.is_empty badge then 0 else 1))
          title
      in
      let heading =
        title
        ^ (if String.is_empty title || String.is_empty badge then "" else " ")
        ^ badge
      in
      let filter =
        if String.is_empty local.filter then "" else " filter=" ^ local.filter
      in
      let heading =
        heading
        ^ E.text (E.clip ~width:(Int.max 0 (room - cell_width heading)) (E.plain filter))
      in
      [ View.text ~attrs:(Role.attrs appearance Heading) heading ])
    else []
  in
  let border_title = if geometry.border > 0 then View.vcat header else View.none in
  let header =
    (if geometry.border > 0 then [] else header)
    @
    if policy.run_reference
    then
      [ lines
          ~appearance
          ~role:Muted
          ~width:body_width
          ~height:1
          [ "Run: "
            ^ Option.value_map
                (tile_run host tile)
                ~default:"none selected"
                ~f:(fun run ->
                  Backend_id.to_string run.backend
                  ^ "/"
                  ^ Presentation.identifier ~compress:policy.string_compression run.id)
          ]
      ]
    else []
  in
  let body =
    List.take rows body_height
    |> List.map ~f:(fun row ->
      let role = if focused && not show_title then Role.Focus else Role.Foreground in
      lines ~appearance ~role ~width:body_width ~height:1 [ row ])
    |> View.vcat
    |> box ~width:body_width ~height:body_height
  in
  let body =
    match compact with
    | Some rows ->
      Overview_tiles.render
        ?indicator_frames
        ~indicator_fg:(Role.foreground appearance Running)
        ~selected_bg:(Role.backdrop appearance Selection)
        ~appearance
        ~attrs:(utility_attrs appearance)
        ~width:body_width
        ~height:body_height
        rows
    | None ->
      (match utility_rows ~now host data tile with
       | None ->
         (match semantic with
          | None
            when String.equal tile.kind "run-selector"
                 && Option.is_none local.inspection
                 && Option.is_none local.artifacts ->
            let candidates = run_candidates data ~filter:local.filter in
            let status_width =
              Int.min
                (Int.min (body_width / 3) (Int.max 0 (body_width - 9)))
                (List.fold candidates ~init:0 ~f:(fun n (_, status) ->
                   Int.max n (cell_width status)))
            in
            let time run =
              Execution_time_view.list_value
                ~now
                (Option.bind (Overview_tiles.execution ~asic:data.asic ~run) ~f:(fun r ->
                   r.execution_timing))
            in
            let time_width =
              List.fold candidates ~init:0 ~f:(fun n (run, _) ->
                Int.max n (cell_width (time run)))
            in
            let selected, _, page = run_page host tile ~height:body_height candidates in
            page
            |> List.map ~f:(fun (run, status) ->
              run_selector_view
                ~string_compression:policy.string_compression
                ~population:(List.map data.runs ~f:(fun (r, _) -> r.id))
                ~time:(time run)
                ~time_width
                ?indicator_frames:
                  (if run_has_producer data run then indicator_frames else None)
                appearance
                ~width:body_width
                ~status_width
                ~cursor:(Option.equal String.equal selected (Some (run_label run)))
                ~active:(Option.equal Run_ref.equal (tile_run host tile) (Some run))
                run
                status)
            |> View.vcat
            |> box ~width:body_width ~height:body_height
          | None -> body
          | Some rows ->
            E.render ~attrs:(evidence_attrs appearance) rows
            |> box ~width:body_width ~height:body_height
            |> colored appearance Foreground)
       | Some rows when local.utility_detail ->
         let rows =
           if String.equal tile.kind "live-status"
           then
             List.map rows ~f:(fun row ->
               { row with
                 Overview_tiles.details =
                   List.map
                     row.Overview_tiles.details
                     ~f:
                       (Presentation.identity_metadata_line
                          ~compress:policy.string_compression)
               })
           else rows
         in
         inspection_physical_rows ~width:body_width rows
         |> List.map ~f:fst
         |> Fn.flip List.drop local.scroll
         |> lines ~appearance ~width:body_width ~height:body_height
       | Some rows
         when String.equal tile.kind "stage-checklist"
              && Option.value horizontal_stages ~default:(H.horizontal_stages host tile)
              && mixed_checklist host data tile ->
         Overview_tiles.render_checklist_strip
           ?indicator_frames
           ~indicator_fg:(Role.foreground appearance Running)
           ~selected_bg:(Role.backdrop appearance Selection)
           ~appearance
           ~attrs:(utility_attrs appearance)
           ~width:body_width
           ~height:body_height
           rows
         |> box ~width:body_width ~height:body_height
       | Some rows
         when String.equal tile.kind "stage-checklist"
              && Option.value horizontal_stages ~default:(H.horizontal_stages host tile)
              && Option.is_some (tile_run host tile) ->
         let run = Option.value_exn (tile_run host tile) in
         let stages = Overview_tiles.observed_stages ~asic:data.asic ~run in
         if List.is_empty stages
         then
           Overview_tiles.render
             ?indicator_frames
             ~indicator_fg:(Role.foreground appearance Running)
             ~selected_bg:(Role.backdrop appearance Selection)
             ~appearance
             ~attrs:(utility_attrs appearance)
             ~width:body_width
             ~height:body_height
             rows
         else (
           let model = stage_strip_model ~now host tile ~run ~width:body_width stages in
           let model =
             match model.selected with
             | None -> model
             | Some item ->
               let selected = model.selected_line in
               let overhead =
                 cell_width (Overview_tiles.marker appearance selected)
                 + (if selected.active then 2 else 0)
                 + (match appearance.density with
                   | Comfortable when body_width >= 30 -> 1
                   | _ -> 0)
                 + cell_width ("Selected: " ^ ": " ^ selected.value)
                 + Option.value_map selected.time ~default:0 ~f:(fun time ->
                   3 + cell_width time)
               in
               { model with
                 selected_line =
                   { selected with
                     label =
                       "Selected: "
                       ^ fit_label
                           ~width:(Int.max 0 (body_width - overhead))
                           item.stage.id
                   }
               }
           in
           let hints, hint_height = stage_strip_hints host data tile ~height:body_height in
           let strip =
             Overview_tiles.Stage_strip.render
               ?indicator_frames
               ~indicator_fg:(Role.foreground appearance Running)
               ~selected_bg:(Role.backdrop appearance Selection)
               ~appearance
               ~attrs:(utility_attrs appearance)
               ~width:body_width
               ~height:(body_height - hint_height)
               model
           in
           View.vcat
             [ strip
             ; lines ~appearance ~role:Muted ~width:body_width ~height:hint_height hints
             ]
           |> box ~width:body_width ~height:body_height)
       | Some rows when String.equal tile.kind "stage-checklist" ->
         let hints, hint_height, available, page =
           checklist_page host data tile ~height:body_height rows
         in
         View.vcat
           [ lines ~appearance ~role:Muted ~width:body_width ~height:hint_height hints
           ; Overview_tiles.render
               ?indicator_frames
               ~indicator_fg:(Role.foreground appearance Running)
               ~selected_bg:(Role.backdrop appearance Selection)
               ~appearance
               ~attrs:(utility_attrs appearance)
               ~width:body_width
               ~height:available
               ~candidate_rows:rows
               page
           ]
         |> box ~width:body_width ~height:body_height
       | Some rows when String.equal tile.kind "workspace-tabs" ->
         let prefix = project_prefix appearance ~width:body_width in
         let width = body_width - View.width prefix in
         let navigation =
           match workspace_page host tile ~width ~height:body_height rows with
           | `Strip chips -> View.hcat (List.map chips ~f:fst)
           | `Rows page ->
             Overview_tiles.render
               ?indicator_frames
               ~indicator_fg:(Role.foreground appearance Running)
               ~selected_bg:(Role.backdrop appearance Selection)
               ~appearance
               ~attrs:(utility_attrs appearance)
               ~width
               ~height:(Int.max 1 (body_height - 1))
               page
         in
         View.vcat
           [ View.hcat [ prefix; navigation ]
           ; (if not policy.hints
              then View.none
              else
                lines
                  ~appearance
                  ~role:Muted
                  ~width:body_width
                  ~height:1
                  [ "j/k browse | Enter open | 1-9 jump" ])
           ]
         |> box ~width:body_width ~height:body_height
       | Some rows ->
         Overview_tiles.render
           ?indicator_frames
           ~indicator_fg:(Role.foreground appearance Running)
           ~selected_bg:(Role.backdrop appearance Selection)
           ~appearance
           ~attrs:(utility_attrs appearance)
           ~width:body_width
           ~height:body_height
           (List.drop rows local.scroll))
  in
  let body =
    if String.equal tile.kind "workloads"
    then
      Workloads_view.rows
        local.workloads
        ~asic:data.asic
        ~filter:local.filter
        ~width:body_width
        ~height:body_height
      |> E.render ~attrs:(evidence_attrs appearance)
    else if Resources_view.is_kind tile.kind || String.equal tile.kind "resource-detail"
    then (
      let rows = resource_page host data tile ~width:body_width ~height:body_height |> List.map ~f:snd in
      E.render ~attrs:(evidence_attrs appearance) rows)
    else if String.equal tile.kind "planned-run"
    then
      planned_view_rows ?indicator_frames host tile ~width:body_width
      |> Fn.flip List.drop local.scroll
      |> Fn.flip List.take body_height
      |> View.vcat
      |> box ~width:body_width ~height:body_height
      |> colored appearance Foreground
    else if Option.is_some local.inspection || Option.is_some local.artifacts
    then body
    else if H.simulation_kind tile.kind
    then (
      let views =
        simulation_view_rows_with_selection
          ~now
          ?indicator_frames
          host
          data
          tile
          ~width:body_width
      in
      List.drop views (simulation_viewport_start host tile ~height:body_height views)
      |> Fn.flip List.take body_height
      |> List.map ~f:snd
      |> View.vcat
      |> box ~width:body_width ~height:body_height)
    else if List.mem [ "execution"; "project-tests" ] tile.kind ~equal:String.equal
    then
      execution_annotations host data tile
      |> annotated_view_rows ?indicator_frames host ~width:body_width
      |> Fn.flip List.drop local.scroll
      |> Fn.flip List.take body_height
      |> List.map ~f:snd
      |> View.vcat
      |> box ~width:body_width ~height:body_height
    else (
      match Timing_workspace.pane tile.kind, H.timing host tile with
      | Some pane, Some view ->
        timing_body
          ~presentation:policy
          ?indicator_frames
          ~reading:(evidence_reading data ~views:[ view ] ~runs:[])
          appearance
          ~pane
          ~scroll:local.scroll
          ~width:body_width
          ~height:body_height
          view
      | _ -> body)
  in
  let body =
    Option.bind render_pane ~f:(fun render ->
      render tile ~width:body_width ~height:body_height)
    |> Option.value ~default:body
    |> box ~width:body_width ~height:body_height
  in
  let body =
    View.vcat
      [ lines
          ~appearance
          ~role:Warning
          ~width:body_width
          ~height:banner_height
          observation_banner
      ; body
      ]
    |> box ~width:body_width ~height:full_body_height
  in
  let content = View.vcat (header @ [ body ]) in
  Panel.render
    appearance
    ~attrs:(Role.attrs appearance (if focused then Focus else Border))
    ~title:border_title
    ~geometry
    ~width
    ~height
    content
  |> colored appearance Foreground
  |> box ~width ~height
;;

module Fit_layout = struct
  type t = P.Layout.t =
    | Grid of W.Geometry.t list
    | Compact

  let compute ~width ~height ~count =
    if count <= 0
    then Grid []
    else (
      match P.Layout.grid ~gutter:1 ~width ~height count with
      | None -> Compact
      | Some cells ->
        Grid
          (List.sort cells ~compare:(fun (a, _) (b, _) -> Int.compare a b)
           |> List.map ~f:snd))
  ;;
end

let show_global_header host =
  let tiles = H.tiles host in
  host.H.chrome
  && (not (List.exists tiles ~f:(fun tile -> P.Waveforms.is_pane tile.kind)))
  && not
       (List.exists (H.tiles host) ~f:(fun tile ->
          String.equal tile.W.Tile.kind "live-status"))
;;

(** Waveform tiles use their focused hint policy in any composition. Notices and
    active-input status remain visible. *)
let show_footer_hints host =
  match H.focused host with
  | Some tile when P.Waveforms.is_pane tile.kind -> (H.policy host tile).hints
  | _ -> true
;;

(** The bottom row exists only while it has something to say. Hidden main-window hints
    give their row back to the tiles; notices and active-input status still claim it, and
    the existing global chrome toggle continues to suppress the footer entirely. *)
let footer_row host =
  host.H.paste
  || host.editing_filter
  || (host.chrome && (host.main_hints || not (String.is_empty host.notice)))
;;

(** The same outer and inner geometry is used by rendering and page navigation. *)
let tile_layout host ({ Dimensions.width; height } : Dimensions.t) =
  let width = Int.max 1 width
  and height = Int.max 1 height in
  let available =
    Int.max
      1
      (height
       - (if show_global_header host then 1 else 0)
       - if footer_row host then 1 else 0)
  in
  let tiles = H.tiles host in
  let zoomed =
    Option.value_map (H.active host) ~default:false ~f:(fun w ->
      Option.is_some w.zoomed_tile)
  in
  let definition = Option.bind (H.active host) ~f:(H.render_definition host) in
  let layout_mode = H.effective_layout_mode host in
  let fit =
    match definition with
    | Some definition ->
      let kinds = H.layout_keys host tiles in
      let tree = P.Layout.resolve definition.layout kinds in
      let spare =
        Option.value_map tree ~default:0 ~f:(fun tree ->
          Int.max 0 (available - snd (P.Layout.min_size tree)))
      in
      let selector_count =
        Int.max
          1
          (List.count tiles ~f:(fun tile -> String.equal tile.W.Tile.kind "run-selector"))
      in
      let rec minimum i = function
        | P.Layout.Cell (index, _, height, _) -> if i = index then height else 0
        | Narrow tree -> minimum i tree
        | Weighted_columns children ->
          List.fold children ~init:0 ~f:(fun height (_, tree) ->
            Int.max height (minimum i tree))
        | Stack children | Columns children ->
          List.fold children ~init:0 ~f:(fun height tree ->
            Int.max height (minimum i tree))
      in
      (match
         P.Layout.compute
           ~min_height_for_index:(fun i ->
             Option.bind (List.nth tiles i) ~f:(fun tile ->
               if not (String.equal tile.W.Tile.kind "run-selector")
               then None
               else (
                 let policy = H.policy host tile in
                 let frame =
                   policy.frame && framed host.appearance ~width ~height:available
                 in
                 let requested =
                   Int.min available policy.run_selector_rows
                   + (if frame
                      then 2
                      else if T.show_title policy
                              || T.show_badge policy (H.binding_kind tile)
                      then 1
                      else 0)
                   + if policy.run_reference then 1 else 0
                 in
                 let budget =
                   Option.value_map tree ~default:available ~f:(fun tree ->
                     minimum i tree + (spare / selector_count))
                 in
                 Some (Int.min requested budget))))
           definition
           ~width
           ~height:available
           ~kinds
       with
       | Grid cells -> Fit_layout.Grid cells
       | Compact -> Fit_layout.Compact)
    | None -> Fit_layout.compute ~width ~height:available ~count:(List.length tiles)
  in
  let compact =
    (not zoomed)
    &&
    match layout_mode, fit with
    | H.Fit, Fit_layout.Compact -> true
    | _ -> false
  in
  let focused () =
    let tile =
      Option.filter (H.focused host) ~f:(fun tile ->
        List.exists tiles ~f:(fun t -> W.Tile_id.equal t.id tile.id))
      |> fun focused -> Option.first_some focused (List.hd tiles)
    in
    Option.to_list tile
    |> List.map ~f:(fun tile ->
      tile, { W.Geometry.x = 0; y = 0; width; height = available })
  in
  let layout =
    if compact && width >= 24 && available >= 8
    then (
      (* Keep the workspace navigation strip reachable above a focused pane on a
         short terminal. The strip is still the existing tile, not a new tab stop. *)
      let nav =
        List.find tiles ~f:(fun t ->
          String.equal t.kind "workspace-tabs"
          && (body_bounds host t (panel_geometry host t ~width ~height:1)).height = 1)
      in
      match nav, focused () with
      | Some nav, [ tile, g ] when not (W.Tile_id.equal tile.id nav.id) ->
        [ nav, { g with height = 1 }; tile, { g with y = 1; height = available - 1 } ]
      | _ -> focused ())
    else if zoomed || compact
    then focused ()
    else (
      match layout_mode, fit with
      | H.Fit, Fit_layout.Grid cells -> List.zip_exn tiles cells
      | H.Fit, Fit_layout.Compact -> focused ()
      | H.Preferred, _ ->
        let rec pack pending x y row_height acc =
          match pending with
          | [] -> List.rev acc, y + row_height
          | tile :: rest ->
            let g = tile.W.Tile.requested_geometry in
            let tw = Int.min width (Int.max 8 g.width) in
            let th = Int.min available (Int.max 3 g.height) in
            let gap = if x = 0 then 0 else 1 in
            if x + gap + tw > width && x > 0
            then pack pending 0 (y + row_height) 0 acc
            else
              pack
                rest
                (x + gap + tw)
                y
                (Int.max row_height th)
                ((tile, { W.Geometry.x = x + gap; y; width = tw; height = th }) :: acc)
        in
        let packed, total_height = pack tiles 0 0 0 [] in
        if total_height > available && Option.is_some (H.focused host)
        then focused ()
        else packed)
  in
  available, compact, layout
;;

(** Hit-test the workspace layer at a zero-based terminal cell. A frame,
    padding or heading hit still identifies the tile, but only body cells
    have a body-relative (column,row). The caller owns overlay routing. *)
let pointer_geometry host (dimensions : Dimensions.t) ~x ~y =
  let top = Bool.to_int (show_global_header host) in
  if x < 0 || x >= dimensions.width || y < top || y >= dimensions.height
  then None
  else (
    let available, _, layout = tile_layout host dimensions in
    let y = y - top in
    if y >= available
    then None
    else
      List.find_map layout ~f:(fun (tile, (g : W.Geometry.t)) ->
        let col = x - g.x
        and row = y - g.y in
        if col < 0 || row < 0 || col >= g.width || row >= g.height
        then None
        else (
          let p = panel_geometry host tile ~width:g.width ~height:g.height in
          let body = body_bounds host tile p in
          let bx = col - body.x
          and by = row - body.y in
          let body_cell =
            Option.some_if
              (bx >= 0 && by >= 0 && bx < body.width && by < body.height)
              (bx, by)
          in
          Some (tile, body, body_cell))))
;;

let pointer_hit host dimensions ~x ~y =
  Option.map (pointer_geometry host dimensions ~x ~y) ~f:(fun (tile, _, cell) ->
    tile, cell)
;;

let menu_trigger_at host _data dimensions ~x ~y =
  match pointer_geometry host dimensions ~x ~y with
  | Some (tile, body, Some (column, row)) ->
    let local = H.local host tile.id in
    if Option.is_some local.artifacts || Option.is_some local.inspection
    then None
    else (
      match tile.kind with
      | "workspace-tabs" when row = 0 && not local.utility_detail ->
        let prefix = project_prefix host.appearance ~width:body.width in
        Option.some_if (column < View.width prefix - 1) `Project
      | _ -> None)
  | _ -> None
;;

let run_context_at host data dimensions ~x ~y =
  match pointer_geometry host dimensions ~x ~y with
  | Some (tile, body, Some (_, row)) when String.equal tile.kind "run-selector" ->
    let local = H.local host tile.id in
    if Option.is_some local.artifacts || Option.is_some local.inspection
    then None
    else (
      let _, _, page =
        run_page host tile ~height:body.height (run_candidates data ~filter:local.filter)
      in
      List.nth page row |> Option.map ~f:(fun (run, _) -> tile, run))
  | _ -> None
;;

let%test_unit "pointer follows packed tiles, borders and compact resize" =
  let s = W.initial ~session_id:(W.Session_id.of_string "mouse-geometry") in
  let workspace = List.hd_exn s.workspaces in
  let make id width =
    { (List.hd_exn s.tiles) with
      W.Tile.id = W.Tile_id.of_string id
    ; workspace = workspace.id
    ; kind = "logs"
    ; hidden = false
    ; requested_geometry = { x = 50; y = 50; width; height = 6 }
    }
  in
  let left = make "first" 12
  and right = make "second" 15 in
  let host = H.receive H.empty { s with tiles = [ left; right ] } in
  let host =
    { host with
      layout_mode = Preferred
    ; appearance = { host.appearance with preset = Instrument }
    ; focus = Some right.id
    }
  in
  let host =
    H.set_local
      host
      right.id
      { (H.local host right.id) with
        presentation =
          { T.inherit_ with
            frame = Some true
          ; padding = Some 1
          ; run_reference = Some true
          ; header = Some true
          ; title = Some true
          }
      }
  in
  let dimensions = { Dimensions.width = 40; height = 10 } in
  let cell x y = pointer_hit host dimensions ~x ~y in
  List.iter [ 0, 0; 12, 3; 28, 2; 4, 7; 0, 9; -1, 2; 40, 0 ] ~f:(fun (x, y) ->
    assert (Option.is_none (cell x y)));
  List.iter [ 13, 1; 27, 1; 13, 6; 27, 6; 14, 3; 15, 2 ] ~f:(fun (x, y) ->
    let tile, body = Option.value_exn (cell x y) in
    assert (W.Tile_id.equal tile.id right.id && Option.is_none body));
  assert ([%equal: (int * int) option] (snd (Option.value_exn (cell 15 3))) (Some (0, 0)));
  let host = { host with layout_mode = Fit; chrome = false } in
  let dimensions = { Dimensions.width = 9; height = 4 } in
  List.iter [ 0, 0; 8, 3 ] ~f:(fun (x, y) ->
    let tile, _ = Option.value_exn (pointer_hit host dimensions ~x ~y) in
    assert (W.Tile_id.equal tile.id right.id));
  assert (Option.is_none (pointer_hit host dimensions ~x:13 ~y:1));
  (* At three columns the renderer drops both the frame and the padding.
     The title re-enters the content above the run reference. *)
  let dimensions = { Dimensions.width = 3; height = 3 } in
  let body y = snd (Option.value_exn (pointer_hit host dimensions ~x:0 ~y)) in
  assert (Option.is_none (body 0) && Option.is_none (body 1));
  assert ([%equal: (int * int) option] (body 2) (Some (0, 0)))
;;

let reconcile_simulation_viewports host data dimensions =
  let _, _, layout = tile_layout host dimensions in
  List.fold layout ~init:host ~f:(fun host (tile, g) ->
    if not (simulation_cursor_pane tile.W.Tile.kind)
    then host
    else (
      let _, _, _, width, height =
        body_geometry host tile ~width:g.W.Geometry.width ~height:g.height
      in
      let rows = simulation_view_rows_with_selection host data tile ~width in
      let local = H.local host tile.id in
      let scroll = simulation_viewport_start host tile ~height rows in
      if scroll = local.scroll
      then host
      else H.set_local host tile.id { local with scroll }))
;;

let scroll_run_focused host data dimensions ~delta =
  let _, _, layout = tile_layout host dimensions in
  match H.focused host, host.H.registry with
  | Some tile, Some registry ->
    (match
       ( List.find layout ~f:(fun (visible, _) -> W.Tile_id.equal visible.id tile.id)
       , W.resolve_tile registry tile.id
         |> Result.ok
         |> Option.bind ~f:(fun reference -> reference.run) )
     with
     | Some (_, g), _ when H.simulation_kind tile.kind ->
       let _, _, _, width, height =
         body_geometry host tile ~width:g.width ~height:g.height
       in
       let local = H.local host tile.id in
       let full = simulation_view_rows_with_selection host data tile ~width in
       let maximum = Int.max 0 (List.length full - height) in
       let scroll = simulation_viewport_start host tile ~height full in
       let scroll =
         if delta >= 0
         then scroll + Int.min delta (maximum - scroll)
         else
           scroll
           - Int.min scroll (if delta = Int.min_value then Int.max_value else -delta)
       in
       H.set_local
         host
         tile.id
         { local with
           scroll
         ; follow = (if simulation_cursor_pane tile.kind then false else local.follow)
         }
     | Some (_, g), Some run ->
       let _, _, _, width, height =
         body_geometry host tile ~width:g.width ~height:g.height
       in
       let local = H.local host tile.id in
       let local =
         if String.equal tile.kind "synthesis"
            && Synthesis_view.Mode.equal
                 (Synthesis_view.State.mode local.synthesis)
                 Metrics
         then (
           let count =
             synthesis_metrics_content host data tile ~run
             |> List.concat_map ~f:(E.wrap ~width)
             |> List.length
           in
           let maximum = Int.max 0 (count - height) in
           let current = metrics_offset local data run in
           let scroll =
             Int64.(
               max
                 zero
                 (min (of_int maximum) (of_int (Int.min current maximum) + of_int delta)))
             |> Int64.to_int_exn
           in
           { local with scroll; metrics_scope = metrics_scope data run })
         else if String.equal tile.kind "synthesis"
         then
           { local with
             synthesis =
               Synthesis_view.scroll
                 local.synthesis
                 ~summary:(data.summary run)
                 ~filter:local.filter
                 ~width
                 ~height
                 ~delta
           }
         else if Terminal_result_view.supports tile.kind
         then (
           let count =
             terminal_content host data tile ~run
             |> List.concat_map ~f:(E.wrap ~width)
             |> List.length
           in
           { local with
             terminal_result =
               Terminal_result_view.State.scroll
                 (Terminal_result_view.State.reconcile
                    local.terminal_result
                    ~run
                    ~summary:(data.summary run))
                 ~delta
                 ~max_offset:(Int.max 0 (count - height))
           })
         else local
       in
       H.set_local host tile.id local
     | _ -> host)
  | _ -> host
;;

let scroll_focused host data dimensions ~delta =
  match H.focused host with
  | Some tile
    when List.mem
           [ "preparation"; "live-status"; "stage-checklist" ]
           tile.kind
           ~equal:String.equal
         || (String.equal tile.kind "timing" && (H.local host tile.id).utility_detail) ->
    let _, _, layout = tile_layout host dimensions in
    (match
       ( List.find layout ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.id)
       , utility_rows host data tile )
     with
     | Some (_, g), Some rows ->
       let _, _, _, width, height =
         body_geometry host tile ~width:g.width ~height:g.height
       in
       let local = H.local host tile.id in
       let count =
         if local.utility_detail
         then
           Overview_tiles.inspection_lines rows
           |> List.concat_map ~f:(wrap_cells ~width)
           |> List.length
         else List.length rows
       in
       let bound = Int.max 0 (count - height) in
       let current = Int.min local.scroll bound in
       let scroll =
         Int64.(max zero (min (of_int bound) (of_int current + of_int delta)))
         |> Int64.to_int_exn
       in
       H.set_local host tile.id { local with scroll }
     | _ -> host)
  | _ -> scroll_run_focused host data dimensions ~delta
;;

(** Fit uses responsive tracks; Preferred preserves saved shelf dimensions. *)
let inspection_viewport (dimensions : Dimensions.t) =
  Int.max 1 dimensions.width, Int.max 1 dimensions.height
;;

(* WB-054 breadcrumbs: [workspace › view › run (stage)], built only from the active
   workspace, the focused tile, its resolved run and its open inspector. A segment that
   has no typed fact (e.g. no run) is omitted rather than guessed. *)
let breadcrumb_view host (tile : W.Tile.t) =
  let pane = function
    | Timing_workspace.Paths -> "timing paths"
    | Detail -> "path detail"
    | Context -> "path provenance"
  in
  match H.open_inspector host with
  | Some (_, Explorer view) -> "inspect " ^ view.domain, Some view.stage
  | Some (_, Artifact_browser _) -> "reports/artifacts", None
  | Some (_, Timing_detail (p, view)) -> pane p, Some view.stage
  | None ->
    (match Timing_workspace.pane tile.kind, H.timing host tile with
     | Some p, Some view -> pane p, Some view.stage
     | Some p, None -> pane p, None
     | None, _ ->
       ( (match tile.kind with
          | "live-status" -> "session"
          | "workspace-tabs" -> "workspaces"
          | kind -> String.tr kind ~target:'-' ~replacement:' ')
       , None ))
;;

(** Candidates from most to least complete. The workspace name and the full run identity
    stay available in the global header, the session tile and the inspector heading, so a
    shorter candidate drops whole segments and never clips one. *)
let breadcrumbs host =
  match H.active host, H.focused host with
  | Some workspace, Some tile ->
    let sep =
      match host.H.appearance.icons with
      | Unicode -> " › "
      | Ascii | None_ -> " > "
    in
    let view, stage = breadcrumb_view host tile in
    let run =
      Option.map (tile_run host tile) ~f:(fun run ->
        display_run run ^ Option.value_map stage ~default:"" ~f:(sprintf " (%s)"))
    in
    let join segments = String.concat ~sep (List.filter_opt segments) in
    [ join [ Some workspace.name; Some view; run ]; join [ Some view; run ] ]
  | _ -> []
;;

(** A footer row keeps its leading text and gains the widest breadcrumb that fits after a
    two-cell gap, right-aligned. Without room the row is unchanged: no extra chrome. *)
let with_breadcrumb host ~width text =
  let used = cell_width text in
  match
    List.find (breadcrumbs host) ~f:(fun crumb -> used + 2 + cell_width crumb <= width)
  with
  | None -> text
  | Some crumb -> text ^ String.make (width - used - cell_width crumb) ' ' ^ crumb
;;

(* Full-area inspectors have no workspace footer. Reuse spare heading cells so the
   breadcrumb never covers evidence or consumes a content row. *)
let inspector_breadcrumb host ~width rows =
  match rows with
  | heading :: rest
    when host.H.chrome
         && host.main_hints
         && show_footer_hints host
         && String.is_empty host.notice -> with_breadcrumb host ~width heading :: rest
  | _ -> rows
;;

(** Main-window hints name only controls that work on the focused view. Timing panes own
    their keys (q does not exit there), and an open reader names its explicit close. *)
let main_hint_text host =
  let timing =
    Option.bind (H.focused host) ~f:(fun tile ->
      Option.bind (H.timing_pane host tile) ~f:(fun pane ->
        Option.map (H.timing host tile) ~f:(fun view -> pane, view)))
  in
  match timing with
  | Some ((Timing_workspace.Detail | Context), view) when Inspection_view.detail_mode view
    ->
    "Space c c commands | Tab/Shift-Tab focus | j/k scroll | Esc or Space c x close \
     detail | Ctrl-C exit"
  | Some ((Timing_workspace.Detail | Context), _) ->
    "Space c c commands | Tab/Shift-Tab focus | j/k scroll | Ctrl-C exit"
  | Some (Paths, _) ->
    "Space c c commands | Tab/Shift-Tab focus | j/k select | Enter detail | / filter | \
     Ctrl-C exit"
  | None
    when Option.exists (H.focused host) ~f:(fun tile -> String.equal tile.kind "timing")
    -> "Space c c | Tab focus | Enter paths | d details | r refresh | Esc back | q exit"
  | None ->
    "Space c c commands | Tab/Shift-Tab focus | j/k browse | Enter inspect | F8 details | \
     q exit"
;;

let render_workspace
  ?(now = Time_ns.now ())
  ?indicator_frames
  ?render_pane
  host
  data
  ({ Dimensions.width; height } as dimensions)
  =
  let appearance = host.H.appearance in
  let width = Int.max 1 width
  and height = Int.max 1 height in
  let header =
    if not (show_global_header host)
    then []
    else
      [ lines
          ~appearance
          ~role:Active_tab
          ~width
          ~height:1
          [ (match host.registry, H.active host with
             | Some s, Some w ->
               let c = W.context s w.context in
               sprintf
                 "%s | run %s | %s: %s | %s | %s"
                 w.name
                 (Option.value_map c.selected_run ~default:"none" ~f:display_run)
                 (if W.Context_id.equal c.id s.main_context
                  then indicator_label appearance.icons Linked "Linked"
                  else indicator_label appearance.icons Independent "Independent")
                 c.name
                 (Option.value_map data.project ~default:"Workbench" ~f:(fun p -> p.name))
                 data.status
             | _ -> "Workbench | " ^ host.notice)
          ]
      ]
  in
  let available, compact, layout = tile_layout host dimensions in
  let content =
    if Option.is_none host.registry
    then lines ~appearance ~width ~height:available [ "Loading workspace..." ]
    else if List.is_empty layout
    then
      lines
        ~appearance
        ~width
        ~height:available
        [ "No visible tiles in this workspace."
        ; "Space c c: Add a tile, or Apply default layout"
        ]
    else
      List.map layout ~f:(fun (tile, (g : W.Geometry.t)) ->
        tile_view
          ~now
          ?indicator_frames
          ?render_pane
          host
          data
          tile
          ~width:g.width
          ~height:g.height
        |> View.pad ~l:g.x ~t:g.y)
      |> View.zcat
  in
  let footer =
    if host.paste
    then
      [ lines
          ~appearance
          ~role:Warning
          ~width
          ~height:1
          [ (if H.finalization_form host
             then
               "FINALIZATION PASTE | printable path captured; Enter after paste imports \
                | Ctrl-C exits"
             else "PASTE CAPTURE | content ignored until end marker | Ctrl-C exits client")
          ]
      ]
    else if host.editing_filter
    then (
      let filter =
        Option.value_map (H.filter_owner host) ~default:"" ~f:(fun id -> (H.local host id).filter)
      in
      [ lines
          ~appearance
          ~role:Focus
          ~width
          ~height:1
          [ "FILTER INPUT | Enter/Esc finish | Ctrl-BS/Ctrl-W word | Ctrl-U clear | \
             query: "
            ^ filter
          ]
      ])
    else if not host.chrome
    then []
    else if String.is_empty host.notice
            && ((not host.main_hints) || ((not compact) && not (show_footer_hints host)))
    then []
    else
      [ lines
          ~appearance
          ~role:Muted
          ~width
          ~height:1
          [ (if not (String.is_empty host.notice)
             then host.notice
             else if compact
             then
               if show_footer_hints host
               then
                 with_breadcrumb
                   host
                   ~width
                   "Compact: focused tile only | Tab: next tile | enlarge terminal for \
                    grid"
               else with_breadcrumb host ~width "Compact: focused tile only"
             else with_breadcrumb host ~width (main_hint_text host))
          ]
      ]
  in
  let frame =
    View.vcat (header @ [ box ~width ~height:available content ] @ footer)
    |> box ~width ~height
    |> colored appearance Background
  in
  match Option.bind (H.focused host) ~f:(artifact_inspector host) with
  | None -> frame
  | Some view ->
    lines
      ~appearance
      ~role:Surface
      ~width
      ~height
      (Artifact_view.rows view ~width ~height |> inspector_breadcrumb host ~width)
    |> colored appearance Surface
    |> box ~width:dimensions.width ~height:dimensions.height
;;

let palette_controls host (p : H.palette) =
  let current = H.current host p.capture in
  let nonblank = not (String.is_empty (String.strip p.query)) in
  let input label (event : H.input) = label, `Input event in
  let submit label valid =
    (if current && valid then [ input label H.Enter ] else []) @ [ input "Cancel" H.Escape ]
  in
  match p.argument with
  | None when List.exists p.commands ~f:(fun c ->
      String.is_prefix c.id ~prefix:"flow.choice."
      || (match c.action with Edit_run _ -> true | _ -> false)) ->
    [ input "Cancel" Escape ]
  | None -> []
  | Some (Theme_picker _) ->
    submit "Apply" (Option.is_some (List.nth (H.matches p) p.index))
  | Some (Starter_name _) -> submit "Preview" nonblank
  | Some (Flow_field _) -> submit "Next" nonblank
  | Some (Starter_wait _) -> [ input "Dismiss" Escape ]
  | Some (Starter_preview (_, starter)) ->
    (if current then [ input "Apply" (H.Character 'a') ] else [])
    @ [ input "Cancel" Escape ]
    @ (match starter with
       | Chip _ when current -> [ input "Toggle registration" (Character 'r') ]
       | _ -> [])
  | Some (Starter_result (_, select)) ->
    [ input "Done" Enter ]
    @ (if current && Option.is_some select then [ input "Select target" (Character 's') ] else [])
  | Some (Chip_directory | Module_directory) -> submit "Next" (nonblank && not (Filename.is_absolute p.query))
  | Some (Chip_mapping _) -> submit "Next" (String.equal p.query "ui_in:uo_out:comb8")
  | Some Design_executable -> submit "Import" nonblank
  | Some (Workload_bundle _ | Workload_path | Resource_path _ | Finalization_attempt _) ->
    submit "Read" nonblank
  | Some (Acceptance _) -> submit "Submit" nonblank
  | Some (Simulation_selection (_, _, _, form)) ->
    (match Simulation_view.Form.accept form p.query with
     | Ok (`Launch _) -> submit "Launch" true
     | Ok (`Next _) -> submit "Next" true
     | Error _ -> submit "Next" false)
  | Some (Preparation_inputs (flow, profile) | Plan_endpoint (flow, profile)) ->
    submit "Accept" (Result.is_ok (Launch_preferences.Prompt.selection p.query ~flow ~profile))
  | Some (Run_endpoint (flow, profile)) ->
    submit "Launch" (Result.is_ok (Launch_preferences.Prompt.selection p.query ~flow ~profile))
;;

let palette_page host dimensions =
  match host.H.palette with
  | None -> None
  | Some p ->
    let appearance = H.effective_appearance host in
    let theme = H.theme_picker p in
    let bounds =
      Palette_view.bounds ~width:dimensions.Dimensions.width ~height:dimensions.height
    in
    let geometry =
      Panel.geometry
        ~framed:(bounds.height >= 6 && bounds.width >= 6)
        ~width:bounds.width
        ~height:bounds.height
        ~horizontal_padding:(if bounds.width >= 8 then 1 else 0)
        ~vertical_padding:0
    in
    let width = geometry.content_width in
    let height = geometry.content_height in
    let controls =
      Palette_view.buttons ~width ~attrs:(Role.attrs appearance Focus) (palette_controls host p)
      |> Fn.flip List.take (Int.max 0 (height - 1))
    in
    let available = height - List.length controls in
    (* Hidden palette hints return both the hint row and its separator to the result list;
       a notice (e.g. an unavailable reason) still claims the row. *)
    let footer_height =
      if available >= 3 && (host.palette_hints || not (String.is_empty host.notice))
      then 1
      else 0
    in
    let footer_gap = if footer_height > 0 && available >= 5 then 1 else 0 in
    let heading_height = if geometry.border = 0 && available >= 4 then 1 else 0 in
    let prompt_rows =
      Int.max 1 (Int.min 3 (available - footer_height - footer_gap - heading_height))
    in
    let text ?(role = Role.Surface) text =
      lines ~appearance ~role ~width ~height:1 [ text ]
    in
    let heading =
      match p.argument with
      | Some (H.Theme_picker _) -> "Choose theme"
      | Some (H.Plan_endpoint _) ->
        "PLAN ENDPOINT — "
        ^ Launch_preferences.chip_label p.capture.chip_target
        ^ "; Enter stages inputs; Esc closes"
      | Some (H.Run_endpoint (flow, profile)) ->
        "Run " ^ flow ^ "/" ^ profile ^ " · enter endpoint · Enter launches"
      | Some (H.Preparation_inputs _) ->
        "PREPARATION INPUTS — "
        ^ Launch_preferences.chip_label p.capture.chip_target
        ^ "; Enter selects; no launch"
      | Some (H.Resource_path bundle) ->
        (if bundle then "IMPORT EMITTED BUNDLE" else "IMPORT RETAINED RESOURCE EVIDENCE")
        ^ " — exact absolute directory; Enter reads; no run allocation"
      | Some H.Workload_path ->
        "IMPORT WORKLOAD RESULT — exact absolute result.json; Enter reads; no execution"
      | Some H.Design_executable -> "IMPORT EXISTING ASIC DESIGN — existing project executable"
      | Some (H.Starter_name Asic_starter) -> "ADD ASIC STARTER — enter starter name"
      | Some (H.Flow_field field) -> Flow_authoring.field_prompt field
      | Some (H.Starter_name (Flow_entry draft)) ->
        Flow_authoring.kind draft ^ " — enter new ID"
      | Some (H.Starter_preview (_, Flow_entry draft)) ->
        Flow_authoring.kind draft ^ " preview · Enter applies · Esc cancels"
      | Some (H.Starter_name (Chip _)) -> "NEW CHIP TARGET — enter target name"
      | Some H.Chip_directory -> "FROM IP LIBRARY — enter project-relative library directory"
      | Some (H.Chip_mapping _) -> "FROM IP LIBRARY — enter explicit pin mapping"
      | Some (H.Starter_name (Empty_ip | Sample_ip)) -> "NEW IP LIBRARY — enter library name"
      | Some H.Module_directory -> "NEW MODULE — enter project-relative library directory"
      | Some (H.Starter_name (Module_in _)) -> "NEW MODULE — enter module name"
      | Some (H.Starter_wait _) -> "Waiting for authoring service · Esc dismisses"
      | Some (H.Starter_preview (_, Chip _)) ->
        "CHIP TARGET PREVIEW · r toggles registration · Enter applies · Esc cancels · ↑/↓ scroll"
      | Some (H.Starter_preview (p, _)) ->
        (if String.equal p.operation.recipe Hardcaml_workbench_protocol.Authoring.add_to_project_recipe
         then "ASIC STARTER PREVIEW · a applies"
         else if String.equal p.operation.recipe Hardcaml_workbench_protocol.Authoring.module_recipe
         then "NEW MODULE PREVIEW · Enter applies"
         else "NEW IP LIBRARY PREVIEW · Enter applies")
        ^ " · Esc cancels · ↑/↓ scroll"
      | Some (H.Starter_result (_, Some _)) ->
        "s: Select new chip target · Enter/Esc closes · ↑/↓ scroll"
      | Some (H.Starter_result _) -> "AUTHORING RESULT · Enter/Esc closes · ↑/↓ scroll"
      | Some (H.Workload_bundle (left, _)) ->
        (if left then "CAPTURE A" else "CAPTURE B")
        ^ " — exact absolute verified bundle directory; source digest stays frozen"
      | Some (H.Finalization_attempt run) ->
        "INSPECT FINALIZATION for "
        ^ run_label run
        ^ " - exact returned attempt; Enter imports; Esc closes"
      | Some (H.Acceptance (run, _, _)) ->
        "FINALIZE AND ACCEPT " ^ run_label run ^ " — Enter submits; Esc closes"
      | Some (H.Simulation_selection _) ->
        "SIMULATION LAUNCH FORM — explicit inputs; Enter accepts each field"
      | None when List.exists p.commands ~f:(fun c -> String.equal c.id "ip.empty") ->
        "NEW IP LIBRARY — choose template"
      | None when List.exists p.commands ~f:(fun c -> String.equal c.id "chip.example") ->
        "NEW CHIP TARGET — choose source"
      | None when List.exists p.commands ~f:(fun c -> String.equal c.id "chip.directory") ->
        "FROM IP LIBRARY — choose a library"
      | None when List.exists p.commands ~f:(fun c -> String.equal c.id "library.new-module") ->
        "SELECTED LIBRARY — choose action"
      | None when List.exists p.commands ~f:(fun c -> String.equal c.id "setup.add") ->
        "SET UP PROJECT — choose how to configure this project"
      | None ->
        (match List.hd p.commands with
         | Some c when String.is_prefix c.id ~prefix:"flow.choice." -> c.aliases
         | Some { action = Edit_run _; _ } -> "Run Flow · select existing flow/profile"
         | _ -> "COMMAND PALETTE · captured target")
    in
    let query =
      match p.argument with
      | Some (H.Simulation_selection _ | H.Acceptance _ | H.Design_executable | H.Flow_field _ | H.Starter_name _ | H.Module_directory | H.Chip_mapping _ | H.Chip_directory) ->
        let input =
          "> "
          ^ p.query
          ^
          match appearance.icons with
          | Unicode -> "▏"
          | Ascii | None_ -> "|"
        in
        (* Anchor overflowing forms at the tail, so a useful path component does not split
           just because the frame/padding consumes a different number of cells. *)
        let input =
          if width > 0 && cell_width input > width * prompt_rows
          then String.make ((width - (cell_width input % width)) % width) ' ' ^ input
          else input
        in
        wrap_cells ~width input |> List.rev |> Fn.flip List.take prompt_rows |> List.rev
      | _ -> []
    in
    let help =
      match p.argument with
      | Some (H.Starter_name starter) ->
        (match starter with
         | Module_in dir -> [ "Library: " ^ Artifact_view.safe dir ]
         | Flow_entry draft -> [ "Owner chip: " ^ Flow_authoring.owner draft ]
         | Sample_ip -> [ "Template: sample behavior" ]
          | Empty_ip -> [ "Template: empty" ]
          | Chip (source, _) -> H.chip_assumptions source
         | Asic_starter -> [])
        @ [ "Enter previews new files in the open project. Esc cancels." ]
      | Some H.Module_directory -> [ "Enter the directory containing the library's dune file." ]
      | Some H.Chip_directory -> [ "Enter the directory containing the library's dune file." ]
      | Some (H.Chip_mapping dir) ->
        [ "Library: " ^ Artifact_view.safe dir
        ; "Supported mapping: ui_in:uo_out:comb8"
        ; "Connect ui_in[7:0] to Block.create and drive uo_out[7:0]."
        ; "Combinational; no clock/reset. Bidirectional outputs and enables tied low."
        ]
      | Some (H.Starter_preview _ | H.Starter_result _) ->
        let rows =
          match p.argument with
          | Some (H.Starter_preview (preview, Chip (source, _))) -> H.starter_preview_lines ~source preview
          | Some (H.Starter_preview (preview, Flow_entry draft)) ->
            H.starter_preview_lines preview @ Flow_authoring.summary draft
          | Some (H.Starter_preview (preview, _)) -> H.starter_preview_lines preview
          | Some (H.Starter_result (rows, _)) -> rows
          | _ -> assert false
        in
        List.concat_map rows ~f:(wrap_cells ~width)
      | Some H.Design_executable ->
        [ "Path to the built design CLI (absolute or relative to the open project)."
        ; "Enter writes .workbench/hardcaml-workbench-asic.sexp. Esc cancels."
        ; "Uses _flow_tools and _flow_results/workbench/asic under the project root."
        ; "No build or EDA runs. Reopen with a fresh daemon to discover flows."
        ] |> List.concat_map ~f:(wrap_cells ~width)
      | Some (H.Simulation_selection (_, _, _, form)) ->
        Simulation_view.Form.help form |> List.concat_map ~f:(wrap_cells ~width)
      | Some (H.Acceptance _) ->
        [ "Acceptance S-expression (≤4096 UTF-8 bytes; quote paths with spaces):"
        ; "((support_tools /tools) (precheck_python /python)"
        ; " (testbench /tb.sv) (testbench_top tb) (replay_trace /trace))"
        ; "All five values are explicit strings; no shell expansion."
        ]
      | _ -> []
    in
    let prompt =
      if (match p.argument with Some (H.Starter_wait _ | H.Starter_preview _ | H.Starter_result _) -> true | _ -> false)
      then []
      else if List.is_empty query
      then
        [ Palette_view.query
            ~attrs:(Role.attrs appearance Surface)
            ~prompt_attrs:(Role.attrs appearance Focus)
            ~caret:
              (match appearance.icons with
               | Unicode -> "▏"
               | Ascii | None_ -> "|")
            ~caret_attrs:(Role.attrs appearance Focus)
            ~width
            p.query
        ]
      else List.map query ~f:(text ~role:Focus)
    in
    let body_height = available - footer_height - footer_gap in
    let help_height = Int.max 0 (body_height - heading_height - List.length prompt) in
    let help_limit = Int.max 0 (List.length help - help_height) in
    let scrolling_help =
      match p.argument with Some (H.Starter_preview _ | H.Starter_result _) -> true | _ -> false
    in
    let help = if scrolling_help then List.drop help (Int.min p.index help_limit) else help in
    let header =
      (if heading_height > 0 then [ text heading ] else [])
      @ prompt
      @ List.map help ~f:text
    in
    let shown = Int.max 0 (body_height - List.length header) in
    let ranked = if H.palette_has_results p then H.ranked_matches p else [] in
    let start = Int.max 0 (p.index - shown + 1) in
    let commands =
      List.drop ranked start
      |> Fn.flip List.take shown
      |> List.mapi ~f:(fun i result ->
        let selected = start + i = p.index in
        let role = if selected then Role.Selection else Surface in
        let attrs = Role.attrs appearance role in
        (* Selection owns the row backdrop; matching owns underline and a warm foreground.
           The two remain distinct even on the selected command. *)
        let match_attrs =
          Role.attrs appearance Matched @ [ Attr.bg (Role.backdrop appearance role) ]
        in
        let suffix =
          match theme, result.Palette_search.item.action with
          | Some picker, H.Set_scheme scheme
            when Appearance.Scheme.equal picker.original scheme -> " [active]"
          | _ -> ""
        in
        let image = Palette_view.result_row
          ~suffix
          ~attrs
          ~match_attrs
          ~marker_attrs:(Role.attrs appearance role)
          ~width
          ~selected
          result
        |> colored appearance role in
        let spans =
          if Option.is_some result.item.unavailable || not (H.current host p.capture)
          then [] else [ 0, width, `Command result.item.id ]
        in
        { Palette_view.image; spans })
    in
    let commands =
      if H.palette_has_results p && List.is_empty ranked && shown > 0
      then (
        let empty = if Option.is_some theme then "No matching themes" else "No matching commands" in
        [ Palette_view.inert (text ~role:Muted empty) ])
      else commands
    in
    let footer =
      if not (String.is_empty host.notice)
      then host.notice
      else if (match p.argument with Some (H.Starter_wait _ | H.Starter_preview _ | H.Starter_result _) -> true | _ -> false)
      then heading
      else if Option.is_some theme
      then
        (if List.is_empty ranked
         then "Edit search · Esc cancel"
         else "Tab/↑/↓ or Ctrl-N/P preview · Enter apply · Esc cancel")
      else if Option.is_some p.argument
      then "Enter accepts input · Esc return · Ctrl-BS/Ctrl-W word · Ctrl-C exits"
      else
        sprintf
          "%d/%d · Tab/Shift-Tab ↑/↓ · Enter run · Esc return · Ctrl-BS/Ctrl-W word"
          (if List.is_empty ranked then 0 else p.index + 1)
          (List.length ranked)
    in
    let body = List.take (List.map header ~f:Palette_view.inert @ commands) body_height in
    let rows =
      body
      @ List.init (body_height - List.length body) ~f:(fun _ -> Palette_view.inert (text ""))
      @ controls
      @ (if footer_gap > 0 then [ Palette_view.inert (text "") ] else [])
      @ (if footer_height > 0 then [ Palette_view.inert (text ~role:Muted footer) ] else [])
    in
    let scroll_limit =
      if scrolling_help && help_height > 0 then Some help_limit
      else if H.palette_has_results p && shown > 0 then Some (Int.max 0 (List.length ranked - 1))
      else None
    in
    Some (bounds, geometry, heading, rows, scroll_limit)
;;

let palette_hit host dimensions ~x ~y =
  Option.bind (palette_page host dimensions) ~f:(fun (bounds, geometry, _, rows, _) ->
    Palette_view.hit rows
      ~x:(x - bounds.x - geometry.border - geometry.horizontal_padding)
      ~y:(y - bounds.y - geometry.border - geometry.vertical_padding))
;;

let palette_scroll host dimensions ~x ~y ~direction =
  match host.H.palette, palette_page host dimensions with
  | Some p, Some (bounds, _, _, _, Some limit)
    when x >= bounds.x && x < bounds.x + bounds.width
         && y >= bounds.y && y < bounds.y + bounds.height ->
    (match direction with
     | `Up when p.index > 0 && limit > 0 -> Some H.Previous
     | `Down when p.index < limit -> Some H.Next
     | `Up | `Down -> None)
  | _ -> None
;;

let render_palette host dimensions background =
  match palette_page host dimensions with
  | None -> background
  | Some (bounds, geometry, heading, rows, _) ->
    let appearance = H.effective_appearance host in
    let panel =
      List.map rows ~f:(fun row -> row.Palette_view.image)
      |> View.vcat
      |> box ~width:geometry.content_width ~height:geometry.content_height
      |> Panel.render
           appearance
           ~attrs:(Role.attrs appearance Focus)
           ~title:(View.text ~attrs:(Role.attrs appearance Focus) heading)
           ~geometry
           ~width:bounds.width
           ~height:bounds.height
      |> box ~width:bounds.width ~height:bounds.height
      |> colored appearance Surface
    in
    Palette_view.overlay ~background ~panel bounds
    |> box ~width:dimensions.width ~height:dimensions.height
;;

(* This page is the single source of terminal coordinates for menu rendering and
   dispatch. Separators and query/status text never acquire command identities. *)
let menu_footer (menu : H.menu) : (Role.t * string) option =
  match List.nth (H.menu_matches menu) menu.index with
  | Some { command = { unavailable = Some text; _ }; _ } ->
    Some (Warning, " Unavailable: " ^ text)
  | _ ->
    (match menu.kind with
     | Project_menu -> None
     | Actions_menu -> Some (Muted, " ↑↓ or j/k browse · Enter choose · Esc back"))
;;

let menu_page (dimensions : Dimensions.t) (menu : H.menu) =
  let left = 0 and top = if dimensions.height >= 6 then 1 else 0 in
  let width = Int.min 64 dimensions.width in
  let matches = H.menu_matches menu in
  let _, entries =
    List.foldi matches ~init:(None, []) ~f:(fun i (last, output) (entry : H.menu_row) ->
      let output =
        if Option.equal String.equal last (Some entry.group)
        then output
        else `Group entry.group :: output
      in
      Some entry.group, `Choice (i, entry) :: output)
  in
  let entries = if List.is_empty entries then [ `Empty ] else List.rev entries in
  let chrome = 3 + Bool.to_int (Option.is_some (menu_footer menu)) in
  let height = Int.min (chrome + List.length entries) (Int.max 0 (dimensions.height - top)) in
  let capacity = Int.max 0 (height - chrome) in
  let selected =
    List.findi entries ~f:(fun _ -> function `Choice (i, _) -> i = menu.index | _ -> false)
    |> Option.value_map ~default:0 ~f:fst
  in
  let page =
    List.drop entries (Int.max 0 (selected - capacity + 1)) |> Fn.flip List.take capacity
  in
  { W.Geometry.x = left; y = top; width; height }, page
;;

let menu_hit host dimensions ~x ~y =
  Option.map host.H.menu ~f:(fun menu ->
    let g, page = menu_page dimensions menu in
    let col = x - g.x
    and row = y - g.y in
    if col < 0 || row < 0 || col >= g.width || row >= g.height
    then `Outside
    else if col = 0 || col = g.width - 1 || row < 2
    then `Chrome
    else (
      match List.nth page (row - 2) with
      | Some (`Choice (i, entry)) -> `Choice (i, entry.command.id)
      | _ -> `Chrome))
;;

let menu_row_at host dimensions ~x ~y =
  match menu_hit host dimensions ~x ~y with Some (`Choice (i, _)) -> Some i | _ -> None
;;

let menu_pointer host dimensions ~x ~y =
  match menu_hit host dimensions ~x ~y with
  | Some (`Choice (_, id)) -> Some (H.Menu_click id)
  | Some `Outside -> Some H.Dismiss_menu
  | _ -> None
;;

let render_menu host dimensions background =
  match host.H.menu with
  | None -> background
  | Some menu ->
    let appearance = host.appearance in
    let g, page = menu_page dimensions menu in
    let inner = Int.max 0 (g.width - 2) in
    let line role text = lines ~appearance ~role ~width:inner ~height:1 [ text ] in
    let filter =
      if menu.filtering
      then (
        let prefix = View.text ~attrs:(Role.attrs appearance Focus) " Filter: " in
        let attrs = Role.attrs appearance Focus in
        let input = View.text ~attrs menu.query in
        let room = Int.max 0 (inner - View.width prefix - 1) in
        View.hcat
          [ prefix
          ; View.crop ~l:(Int.max 0 (View.width input - room)) input
          ; View.text ~attrs "▏"
          ])
      else
        line Muted (if menu.count > 0 then sprintf " Count: %d" menu.count else " / filter")
    in
    let body =
      filter
      :: List.map page ~f:(function
        | `Group name -> line Heading ("─ " ^ name)
        | `Empty -> line Muted " No matching actions"
        | `Choice (i, entry) ->
          let selected = i = menu.index in
          let disabled = Option.is_some entry.command.unavailable in
          let suffix = if disabled then " [unavailable]" else "" in
          let label =
            fit_label ~width:(Int.max 0 (inner - 2 - cell_width suffix)) entry.label
          in
          line (if selected then Selection else if disabled then Muted else Foreground)
            ((if selected then "› " else "  ") ^ label ^ suffix))
      @ List.map (Option.to_list (menu_footer menu)) ~f:(fun (role, text) -> line role text)
      |> View.vcat
    in
    let title =
      match menu.kind with Project_menu -> "Project" | Actions_menu -> "Actions"
    in
    let geometry =
      Panel.geometry ~framed:true ~width:g.width ~height:g.height
        ~horizontal_padding:0 ~vertical_padding:0
    in
    let panel =
      Panel.render appearance ~attrs:(Role.attrs appearance Border)
        ~title:(View.text ~attrs:(Role.attrs appearance Heading) title)
        ~geometry ~width:g.width ~height:g.height body
      |> colored appearance Surface
    in
    View.zcat [ View.pad ~l:g.x ~t:g.y panel; background ]
    |> box ~width:dimensions.width ~height:dimensions.height
;;

(* A focused explorer covers the workspace. Do not construct the obscured tile images:
   those have different widths and would wrap the same large source a second time. *)
let render ?(now = Time_ns.now ()) ?indicator_frames ?render_pane host data dimensions =
  let host = H.dismiss_stale_theme_picker host in
  let appearance = H.effective_appearance host in
  let inspection_tile =
    match host.H.inspection_paste with
    | None -> H.focused host
    | Some id ->
      Option.bind host.registry ~f:(fun registry ->
        List.find registry.tiles ~f:(fun tile -> W.Tile_id.equal tile.id id))
  in
  let background =
    match Option.bind inspection_tile ~f:(inspection_explorer host) with
    | Some view ->
      let width, height = inspection_viewport dimensions in
      let kind =
        inspection_indicator
          ~reading:(evidence_reading data ~views:[ view ] ~runs:[])
          view
      in
      let icon =
        indicator_view ?indicator_frames appearance (indicator_role kind) kind
      in
      let rows =
        Inspection_view.rows view ~width ~height
        |> inspector_breadcrumb host ~width:(Int.max 0 (width - View.width icon))
      in
      let rows =
        List.mapi rows ~f:(fun i row ->
          let text = View.text ~attrs:(Role.attrs appearance Surface) row in
          (if i = 0 then View.hcat [ icon; text ] else text) |> box ~width ~height:1)
      in
      View.vcat rows |> colored appearance Surface |> box ~width ~height
    | None ->
      render_workspace ~now ?indicator_frames ?render_pane { host with appearance } data dimensions
  in
  render_palette host dimensions (render_menu host dimensions background)
;;

let appearance_cases =
  List.concat_map Appearance.Preset.all ~f:(fun preset ->
    List.concat_map Appearance.Color.all ~f:(fun color ->
      List.concat_map Appearance.Icons.all ~f:(fun icons ->
        List.map Appearance.Density.all ~f:(fun density ->
          { Appearance.preset; color; scheme = Slate; icons; density }))))
;;

let plain_text view =
  let buffer = Buffer.create (View.width view * View.height view) in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (View.width view, View.height view)
    (View.Private.notty_image view);
  Buffer.contents buffer
;;

let refinement_fixture (definition : P.Definition.t) =
  let initial = W.initial ~session_id:(W.Session_id.of_string "refinement-render") in
  let workspace = List.hd_exn initial.workspaces in
  let apply registry mutation =
    W.apply
      registry
      (Mutate { expected_revision = registry.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry = apply initial (P.Definition.apply definition ~workspace:workspace.id) in
  let registry =
    apply
      registry
      (Select_run
         { workspace = workspace.id
         ; context = workspace.context
         ; expected_selection_revision = 0
         ; run = Some Asic_snapshot_fixture.run_a
         })
  in
  let stages =
    List.map
      [ "synthesis"; "floorplan"; "placement"; "cts"; "routing"; "signoff" ]
      ~f:(fun id ->
        { Asic.Stage.id
        ; name = id
        ; status = Completed
        ; requested = true
        ; reason = None
        ; action = None
        ; execution_timing = None
        })
  in
  let snapshot =
    { Asic_snapshot_fixture.snapshot with
      runs = List.map Asic_snapshot_fixture.snapshot.runs ~f:(fun run -> { run with stages })
    }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = List.map snapshot.runs ~f:(fun run -> run.Asic.Run.run, run.status)
    ; log_lines = (fun _ -> [])
    ; run_lines = run_lines (Some snapshot)
    ; run_context = request_context (Some snapshot)
    ; summary =
        (fun run -> List.find snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run))
    ; status = "connected"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = Some snapshot
    }
  in
  let host = H.receive H.empty registry in
  let find kind =
    List.find_exn (H.tiles host) ~f:(fun tile -> String.equal tile.W.Tile.kind kind)
  in
  host, data, find
;;

let%test_unit "80-column Project button and visible run rows have distinct hit targets" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "run-selector" in
  let active = Option.value_exn (tile_run host tile) in
  let other = { active with id = "browsed-run" } in
  let data =
    { data with
      runs =
        [ { active with id = "earlier" }, "hit0"
        ; active, "hit1"
        ; { active with id = "filtered-out" }, "skip"
        ; other, "hit2"
        ; { active with id = "later" }, "hit3"
        ]
    }
  in
  let host =
    H.set_local host tile.id
      { (H.local host tile.id) with
        filter = "hit"
      ; scroll = 1
      ; presentation = { T.inherit_ with run_selector_rows = Some 2 }
      }
  in
  let dimensions = { Dimensions.width = 80; height = 40 } in
  let screen = render_workspace host data dimensions |> plain_text |> String.split_lines in
  let buttons label =
    List.filter_mapi screen ~f:(fun y text ->
      String.substr_index text ~pattern:label
      |> Option.map ~f:(fun byte -> cell_width (String.prefix text byte), y))
  in
  let hit (x, y) = menu_trigger_at host data dimensions ~x ~y in
  (match hit (List.hd_exn (buttons "Project ▾")) with
   | Some `Project -> ()
   | _ -> assert false);
  assert (List.is_empty (buttons "Actions ▾"));
  let painted_rows =
    List.map [ "hit1", active; "hit2", other ] ~f:(fun (label, run) ->
      let x, y = List.hd_exn (buttons label) in
      assert (Option.is_none (hit (x, y)));
      (match pointer_geometry host dimensions ~x ~y with
       | Some (selector, body, Some (column, _)) when W.Tile_id.equal tile.id selector.id ->
         let left = x - column in
         List.iter [ left; x; left + body.width - 1 ] ~f:(fun x ->
           match run_context_at host data dimensions ~x ~y with
           | Some (selector, actual) ->
             assert (W.Tile_id.equal tile.id selector.id && Run_ref.equal run actual)
           | None -> assert false);
         List.iter [ left - 1; left + body.width ] ~f:(fun x ->
           assert (Option.is_none (run_context_at host data dimensions ~x ~y)))
       | _ -> assert false);
      y, run)
  in
  let x, _ = List.hd_exn (buttons "hit1") in
  for y = 0 to dimensions.height - 1 do
    let expected = List.Assoc.find painted_rows y ~equal:Int.equal in
    let actual = run_context_at host data dimensions ~x ~y in
    assert (Option.equal Run_ref.equal expected (Option.map actual ~f:snd))
  done;
  let browsing = H.set_local host tile.id { (H.local host tile.id) with cursor = Some (run_label other) } in
  assert (Option.equal Run_ref.equal (local_menu_run browsing data tile) (Some other));
  assert (Option.equal Run_ref.equal (tile_run browsing tile) (Some active))
;;

let%test_unit "menu page hit tests follow grouping, filtering and bounded cursor scrolling" =
  let host, data, _ = refinement_fixture P.Testing.definition in
  let command id = H.command id id "" Toggle_chrome in
  let commands = List.map [ "project.new-ip"; "project.new-chip"; "asic.pick-chip" ] ~f:command in
  let host, _ = H.input host (Open_menu Project_menu) ~commands in
  let check ~width ~height host name id =
    let dimensions = { Dimensions.width; height } in
    let rows = render host data dimensions |> plain_text |> String.split_lines in
    let y = List.findi_exn rows ~f:(fun _ line -> String.is_substring line ~substring:name) |> fst in
    (match menu_pointer host dimensions ~x:2 ~y with
     | Some (Menu_click clicked) -> assert (String.equal id clicked)
     | _ -> assert false);
    assert (Option.is_none (menu_pointer host dimensions ~x:0 ~y))
  in
  check ~width:80 ~height:24 host "New IP Library" "project.new-ip";
  let advance host event = fst (H.input host event ~commands:[]) in
  let last = advance (advance host Next) Next in
  check ~width:80 ~height:7 last "Select Launch Target" "asic.pick-chip";
  let filtered = advance (advance host (Character '/')) (Text "new-chip") in
  check ~width:80 ~height:24 filtered "New Chip Target" "project.new-chip"
;;

let%test_unit "Runs pointer selection follows filtered capped page and never binds a run" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "run-selector" in
  let active = Option.value_exn (tile_run host tile) in
  let before = { active with id = "before" }
  and after = { active with id = "after" } in
  let hidden = { active with id = "excluded" } in
  let data =
    { data with
      runs = [ before, "match"; hidden, "skip"; active, "match"; after, "match" ]
    }
  in
  let host =
    H.set_local
      host
      tile.id
      { (H.local host tile.id) with
        filter = "MATCH"
      ; cursor = None
      ; scroll = 1
      ; presentation = { T.inherit_ with run_selector_rows = Some 2 }
      }
  in
  let values =
    run_candidates data ~filter:"match" |> List.map ~f:(fun (r, _) -> run_label r)
  in
  assert (browse_index values ~cursor:(run_cursor host tile) ~delta:1 = 2);
  assert (browse_index values ~cursor:(run_cursor host tile) ~delta:(-1) = 0);
  let click row = select_body_row host data tile ~width:45 ~height:4 ~row in
  List.iter [ -1; 2; 3; 4 ] ~f:(fun row -> assert (phys_equal host (click row)));
  let clicked = click 1 in
  assert (
    Option.equal String.equal (H.local clicked tile.id).cursor (Some (run_label after)));
  assert (Option.equal Run_ref.equal (tile_run clicked tile) (Some active));
  assert (phys_equal clicked.registry host.registry)
;;

let%test_unit "wrapped job rows resolve raw IDs; headings and logs are inert" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let tile = find "project-tests" in
  let job =
    { (List.hd_exn Baseline_fixture.jobs) with
      kind = { namespace = "dune"; name = "test" }
    ; id = Job_id.of_string "long-wrapped-attempt-id"
    }
  in
  let data =
    { data with
      jobs = [ job ]
    ; log_lines = (fun _ -> [ "> long-wrapped-attempt-id Complete" ])
    }
  in
  let width = 9 in
  let physical host =
    annotated_physical_rows host ~width (execution_annotations host data tile)
  in
  let rows = physical host in
  assert (List.count rows ~f:(fun (_, (target, _)) -> Option.is_some target) > 1);
  let host =
    H.set_local host tile.id { (H.local host tile.id) with scroll = List.length rows - 1 }
  in
  let clicked = select_body_row host data tile ~width ~height:2 ~row:0 in
  assert (
    Option.equal
      String.equal
      (H.local clicked tile.id).cursor
      (Some (Job_id.to_string job.id)));
  List.iteri (physical clicked) ~f:(fun row (_, (target, _)) ->
    if Option.is_none target
    then
      assert (
        phys_equal
          clicked
          (select_body_row clicked data tile ~width ~height:(row + 1) ~row)))
;;

let%test_unit "WB002 stock Overview stage cards render typed freshness markers" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let analysis : Asic.Timing_analysis.t =
    { target =
        { attempt_id = "attempt"
        ; occurrence_id = "signoff"
        ; analysis_id = "sta"
        ; source_digest = "digest"
        ; execution_sha256 = "sha"
        ; stage = "signoff"
        ; execution_file = None
        }
    ; status = Completed
    ; reason = None
    ; duration = None
    ; enclosing_status = "completed"
    ; producer = None
    ; corners = []
    ; metrics = []
    ; timing_goal = Pass
    ; evidence = "retained"
    }
  in
  List.iter
    [ Asic.Summary.Freshness.Cached_unverified, Indicator.Cached, "cached/unverified"
    ; Validated, Completed, "validated"
    ; Missing_source, Unavailable, "source unavailable"
    ; Refresh_failed "offline", Stale, "refresh failed"
    ]
    ~f:(fun (freshness, indicator, label) ->
      List.iter [ None; Some analysis ] ~f:(fun timing_analysis ->
        let data =
          { data with
            summary =
              (fun run ->
                Option.map (data.summary run) ~f:(fun s ->
                  { s with freshness; timing_analysis }))
          }
        in
        List.iter Appearance.Icons.all ~f:(fun icons ->
          let host = { host with appearance = { host.appearance with icons } } in
          List.iter
            [ "synthesis"; "placement"; "routing"; "checks"; "finalization"; "timing" ]
            ~f:(fun kind ->
              let tile = find kind in
              assert (compact_summary_enabled host tile);
              let render ?indicator_frames width height =
                tile_view ?indicator_frames host data tile ~width ~height
              in
              let text = render 120 20 |> plain_text in
              let glyph = Indicator.text icons indicator in
              let expected =
                if String.equal kind "timing" && Option.is_some timing_analysis
                then
                  (if String.is_empty glyph then "" else glyph ^ " ")
                  ^ "Goal: pass · signoff / post-PNR STA"
                  ^
                  if Asic.Summary.Freshness.equal freshness Validated
                  then ""
                  else " [" ^ label ^ "]"
                else
                  (if String.is_empty glyph then "" else glyph ^ " ")
                  ^ "Evidence: "
                  ^ label
              in
              (* Validated compact Timing has no freshness qualifier. *)
              if not
                   (String.equal kind "timing"
                    && Asic.Summary.Freshness.equal freshness Validated)
              then assert (String.is_substring text ~substring:expected);
              if String.equal kind "synthesis"
              then (
                assert (String.is_substring text ~substring:"Reported cells (agg.): 50");
                assert (String.is_substring text ~substring:"synthesis: completed");
                assert (String.is_substring text ~substring:"Time: unknown"));
              let frames glyph : Indicator.frames =
                { dot = View.text glyph; line = View.text glyph }
              in
              assert (
                String.equal
                  (render ~indicator_frames:(frames "A") 120 20 |> plain_text)
                  (render ~indicator_frames:(frames "B") 120 20 |> plain_text));
              List.iter
                [ 1, 1; 24, 4; 80, 8 ]
                ~f:(fun (width, height) ->
                  let view = render width height in
                  assert (View.width view = width && View.height view = height))))))
;;

let%test_unit "Only Overview Session shows the catalog launch target alongside run evidence" =
  let check definition ~expected =
    let host, data, find = refinement_fixture definition in
    let session = find "live-status" in
    let text target =
      let asic = Option.map data.asic ~f:(fun s -> { s with chip_target = target }) in
      tile_view host { data with asic } session ~width:42 ~height:12 |> plain_text
    in
    let target : Asic.Chip_target.t = { chip = "tiny"; variant = "mac" } in
    let rendered = text (Some target) in
    assert (
      Bool.equal expected (String.is_substring rendered ~substring:"Launch target: tiny/mac"));
    assert (not (String.is_substring (text None) ~substring:"Launch target"));
    if expected then assert (String.is_substring rendered ~substring:"Run:")
  in
  check P.Overview.definition ~expected:true;
  check P.Testing.definition ~expected:false
;;

let%test_unit "Session and Runs render effective global workspace and tile compression" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let session = find "live-status" in
  let selector = find "run-selector" in
  let run = { Asic_snapshot_fixture.run_a with id = "opaque00000000000000tail" } in
  let registry = Option.value_exn host.registry in
  let workspace =
    List.find_exn registry.workspaces ~f:(fun w ->
      W.Workspace_id.equal w.id session.workspace)
  in
  let context =
    List.find_exn registry.contexts ~f:(fun c ->
      W.Context_id.equal c.id workspace.context)
  in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Select_run
               { workspace = workspace.id
               ; context = workspace.context
               ; expected_selection_revision = context.selection_revision
               ; run = Some run
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let host = H.receive host registry in
  let data = { data with runs = [ run, "completed" ] } in
  let check host tile compact =
    let text = tile_view host data tile ~width:160 ~height:30 |> plain_text in
    let token = Presentation.identifier ~compress:compact run.id in
    assert (String.is_substring text ~substring:token);
    if compact then assert (not (String.is_substring text ~substring:run.id))
  in
  let full = H.set_global_compression host (Some false) in
  List.iter [ session; selector ] ~f:(fun tile -> check full tile false);
  let compact = H.set_workspace_compression full session.workspace (Some true) in
  List.iter [ session; selector ] ~f:(fun tile -> check compact tile true);
  let overridden, _ =
    H.set_presentation
      compact
      session.id
      { T.inherit_ with string_compression = Some false }
  in
  check overridden session false;
  check overridden selector true;
  let inherited, _ = H.set_presentation overridden session.id T.inherit_ in
  check inherited session true
;;

let%test_unit "hierarchy unavailable presentation is nonempty and clips small panes" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = { (find "stage-checklist") with kind = "hierarchy" } in
  let registry = Option.value_exn host.registry in
  let host =
    H.receive
      host
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun t ->
            if W.Tile_id.equal t.id tile.id then tile else t)
      }
  in
  let text = tile_view host data tile ~width:100 ~height:8 |> plain_text in
  assert (String.is_substring text ~substring:"No hierarchy loaded");
  assert (String.is_substring text ~substring:"unknown");
  List.iter
    [ 1, 1; 4, 2; 20, 4 ]
    ~f:(fun (width, height) ->
      let image = tile_view host data tile ~width ~height in
      assert (View.width image <= width && View.height image <= height))
;;

let%test_unit "workspace pointer targets rendered chips and narrow rows only" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "workspace-tabs" in
  let registry = Option.value_exn host.registry in
  let w = List.hd_exn registry.workspaces in
  let other = { w with id = W.Workspace_id.of_string "second"; name = "Second" } in
  let host = { host with registry = Some { registry with workspaces = [ w; other ] } } in
  let click ~width ~row ~column =
    workspace_tab_at host data tile ~width ~height:3 ~row ~column
  in
  let chips =
    match
      workspace_page
        host
        tile
        ~width:120
        ~height:3
        (Option.value_exn (utility_rows host data tile))
    with
    | `Strip chips -> chips
    | `Rows _ -> assert false
  in
  let boundary = View.width (project_prefix host.appearance ~width:120)
                 + View.width (fst (List.hd_exn chips)) in
  assert (Option.is_none (click ~width:120 ~row:0 ~column:0));
  List.iter
    [ click ~width:120 ~row:0 ~column:boundary; click ~width:4 ~row:1 ~column:0 ]
    ~f:(fun target -> assert (Option.equal W.Workspace_id.equal target (Some other.id)));
  assert (Option.is_none (click ~width:120 ~row:0 ~column:119));
  assert (Option.is_none (click ~width:4 ~row:2 ~column:0))
;;

let%test_unit "preparation pointer selects wrapped history headings but not attempt \
               metadata"
  =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = { (find "workspace-tabs") with kind = "preparation" } in
  let host = { host with preparation = Some (Preparation_view.fixture_snapshot ()) } in
  let local = { (H.local host tile.id) with utility_detail = true } in
  let host = H.set_local host tile.id local in
  let physical =
    inspection_physical_rows ~width:12 (Option.value_exn (utility_rows host data tile))
  in
  let old =
    List.findi_exn physical ~f:(fun _ (_, id) ->
      Option.equal String.equal id (Some "old-success"))
    |> fst
  in
  let host = H.set_local host tile.id { local with scroll = old } in
  let click row =
    select_more_body_row host data tile ~width:12 ~height:4 ~column:0 ~row
  in
  assert (
    Option.equal String.equal (H.local (click 1) tile.id).cursor (Some "old-success"));
  assert (phys_equal host (click 2))
;;

let%test_unit "vertical checklist pointer follows the rendered viewport and skips hints" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "stage-checklist" in
  let registry = Option.value_exn host.registry in
  let host =
    H.receive
      host
      { registry with
        workspaces = List.map registry.workspaces ~f:(fun w -> { w with preset = None })
      }
  in
  let run = Option.value_exn (tile_run host tile) in
  let items = Overview_tiles.checklist_items ~asic:data.asic ~run in
  let host = H.browse_checklist host tile.id ~run ~items ~delta:4 in
  let _, hints, available, page =
    checklist_page
      host
      data
      tile
      ~height:5
      (Option.value_exn (utility_rows host data tile))
  in
  let click row =
    select_more_body_row host data tile ~width:64 ~height:5 ~column:0 ~row
  in
  if hints > 0 then assert (phys_equal host (click 0));
  let i, entry =
    List.findi_exn (List.take page available) ~f:(fun _ entry ->
      Option.is_some entry.Overview_tiles.cursor_id && not entry.active)
  in
  let local = H.local (click (hints + i)) tile.id in
  assert (Option.equal String.equal local.cursor entry.cursor_id);
  assert (Option.equal Run_ref.equal local.stage_run (Some run));
  assert (not local.utility_detail)
;;

let%test_unit "stopped exact-run observation qualifies actual checklist layouts" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "stage-checklist" in
  let snapshot = Option.value_exn data.asic in
  let error = "Final observation unavailable: exact checkpoint read timed out" in
  let runs =
    List.map snapshot.runs ~f:(fun execution ->
      if Run_ref.equal execution.run Asic_snapshot_fixture.run_a
      then
        { execution with
          error = Some error
        ; stages =
            List.mapi execution.stages ~f:(fun i stage ->
              if i = 1 then { stage with status = Running } else stage)
        }
      else execution)
  in
  let snapshot = { snapshot with runs; operations = [] } in
  let data = { data with asic = Some snapshot } in
  let render host data ?horizontal_stages tile =
    tile_view ?horizontal_stages host data tile ~width:100 ~height:16 |> plain_text
  in
  let contains text phrase = String.is_substring text ~substring:phrase in
  let check host ?horizontal_stages () =
    let text = render host data ?horizontal_stages tile in
    assert (contains text observation_qualifier);
    assert (contains text "running");
    assert (contains text "completed")
  in
  assert (H.compact_summary host tile);
  check host ();
  check host ~horizontal_stages:true ();
  let registry = Option.value_exn host.registry in
  let vertical =
    H.receive
      host
      { registry with
        workspaces = List.map registry.workspaces ~f:(fun w -> { w with preset = None })
      }
  in
  assert (not (H.compact_summary vertical tile));
  check vertical ();
  let banner = observation_banner vertical data tile ~width:24 in
  assert (List.length banner > 1);
  List.iteri banner ~f:(fun row _ ->
    assert (phys_equal vertical
              (select_more_body_row vertical data tile ~width:24 ~height:12 ~column:0 ~row)));
  let detail =
    H.set_local host tile.id { (H.local host tile.id) with utility_detail = true }
  in
  assert (contains (render detail data tile) error);
  let operation kind state run error : Asic.Pending.t =
    { key = "test-observation"
    ; kind
    ; state
    ; run = Some run
    ; error
    ; activity = Unreported
    }
  in
  let with_state ?(error = None) ?(stages = (List.hd_exn runs).stages) operations =
    { data with
      asic =
        Some
          { snapshot with
            operations
          ; runs = List.map runs ~f:(fun r -> { r with error; stages })
          }
    }
  in
  let failed = operation "observe" "failed" Asic_snapshot_fixture.run_a (Some "reader lost") in
  let cancelled = { failed with state = "cancelled" } in
  List.iter
    [ failed; cancelled; { failed with kind = "run" } ]
    ~f:(fun failure ->
      assert (contains (render host (with_state [ failure ]) tile) observation_qualifier));
  List.iter
    [ with_state []
    ; with_state [ { failed with kind = "refresh" } ]
    ; with_state [ { failed with run = Some Asic_snapshot_fixture.run_b } ]
    ; with_state
        [ { failed with
            run = Some { Asic_snapshot_fixture.run_a with backend = Backend_id.of_string "other" }
          }
        ]
    ; with_state ~error:(Some "unrelated provider error") []
    ; with_state
        ~error:(Some error)
        [ failed; { failed with state = "executing"; error = None } ]
    ; with_state
        ~error:(Some error)
        [ failed; { failed with kind = "run"; state = "executing"; error = None } ]
    ; with_state
        ~error:(Some error)
        ~stages:
          (List.map (List.hd_exn runs).stages ~f:(fun s -> { s with status = Completed }))
        [ failed ]
    ]
    ~f:(fun data -> assert (not (contains (render host data tile) observation_qualifier)));
  let pinned = { tile with binding = Pin_run Asic_snapshot_fixture.run_b } in
  let pinned_host =
    H.receive
      host
      { registry with
        tiles =
          List.map registry.tiles ~f:(fun t ->
            if W.Tile_id.equal t.id tile.id then pinned else t)
      }
  in
  assert (not (contains (render pinned_host data pinned) observation_qualifier));
  let retained = { tile with binding = Pin_run Asic_snapshot_fixture.run_a } in
  let selected_elsewhere =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation = Option.value_exn (H.select_run host (Some Asic_snapshot_fixture.run_b))
         })
    |> Result.ok
    |> Option.value_exn
  in
  let retained_host =
    H.receive
      host
      { selected_elsewhere with
        tiles =
          List.map selected_elsewhere.tiles ~f:(fun t ->
            if W.Tile_id.equal t.id tile.id then retained else t)
      }
  in
  assert (contains (render retained_host data retained) observation_qualifier);
  let scrolled = H.set_local host tile.id { (H.local host tile.id) with scroll = 100 } in
  assert (contains (render scrolled data tile) observation_qualifier)
;;

let%test_unit "custom Waveforms spec preserves tile policy and focused chrome" =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let stock = P.Presets.builtins "waveforms" |> Or_error.ok_exn in
  let config =
    { config with
      definitions =
        List.map config.definitions ~f:(fun definition ->
          { stock with
            key = definition.key
          ; template = { stock.template with preset = None }
          })
    }
  in
  let initial =
    W.initial ~session_id:(W.Session_id.of_string "custom-waveforms-chrome")
  in
  let registry =
    W.apply initial (Initialize_config config)
    |> Result.ok
    |> Option.value_exn
    |> fun registry -> W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t registry)
  in
  let host = H.receive H.empty registry in
  let signals =
    List.find_exn (H.tiles host) ~f:(fun tile ->
      String.equal tile.W.Tile.kind "waveform-signals")
  in
  let host = { host with focus = Some signals.id } in
  assert (Option.is_none (Option.value_exn (H.active host)).preset);
  assert (not (show_global_header host));
  assert (not (show_footer_hints host));
  assert (not (H.policy host signals).hints);
  let host, _ =
    H.set_presentation host signals.id { T.inherit_ with hints = Some true }
  in
  assert (show_footer_hints host);
  let _, data, _ = refinement_fixture P.Waveforms.definition in
  List.iter
    [ 32, 8; 120, 40 ]
    ~f:(fun (width, height) ->
      let view = render host data { Dimensions.width; height } in
      assert (View.width view = width && View.height view = height))
;;

let%test_unit "Waveforms callback renders bounded independent bodies beneath host palette"
  =
  let host, data, find = refinement_fixture P.Waveforms.definition in
  let signals = find "waveform-signals" in
  assert (
    Option.is_none (tile_run host { signals with binding = Pin_run Asic_snapshot_fixture.run_a }));
  assert (
    T.Binding.equal
      (H.binding_kind { signals with binding = Pin_run Asic_snapshot_fixture.run_a })
      Project);
  let rendered = ref [] in
  let render_pane (tile : W.Tile.t) ~width ~height =
    if not (P.Waveforms.is_pane tile.kind)
    then None
    else (
      rendered := (tile.kind, width, height) :: !rendered;
      Some
        (View.vcat
           (List.init (height + 5) ~f:(fun _ ->
              View.text ("BODY " ^ tile.kind ^ String.make width '!')))))
  in
  List.iter
    [ 80, 24; 120, 40; 180, 55; 32, 8 ]
    ~f:(fun (width, height) ->
      let view = render ~render_pane host data { Dimensions.width; height } in
      assert (View.width view = width && View.height view = height));
  rendered := [];
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let view = render ~render_pane host data dimensions in
  assert (List.length !rendered = 5);
  List.iter !rendered ~f:(fun (_, width, height) -> assert (width > 0 && height > 0));
  let screen = plain_text view in
  List.iter
    [ "Session"; "Signals"; "Waves"; "VCD picker"; "Logs"; "BODY waveform-waves" ]
    ~f:(fun label -> assert (String.is_substring screen ~substring:label));
  let palette : H.palette =
    { capture = Option.value_exn (H.capture host)
    ; commands =
        [ H.command
            "waveforms.test"
            "Waveforms palette sentinel"
            "waveforms"
            H.Toggle_chrome
        ]
    ; query = ""
    ; index = 0
    ; argument = None
    }
  in
  let overlay =
    render ~render_pane { host with palette = Some palette } data dimensions |> plain_text
  in
  assert (String.is_substring overlay ~substring:"Waveforms palette sentinel")
;;

let%test_unit "Waveforms banner and hints stay scoped with explicit local hint overrides" =
  let host, data, find = refinement_fixture P.Waveforms.definition in
  assert (not (show_global_header host));
  let signals = find "waveform-signals" in
  let session = find "waveform-session" in
  assert (not (H.policy host signals).hints);
  assert (not (H.policy host session).hints);
  let host = { host with focus = Some signals.id; notice = "" } in
  let screen host =
    render host data { Dimensions.width = 120; height = 40 } |> plain_text
  in
  assert (not (show_footer_hints host));
  assert (not (String.is_substring (screen host) ~substring:"j/k browse"));
  assert (not (String.is_substring (screen host) ~substring:"Waveforms | run"));
  assert (
    String.is_substring
      (screen { host with notice = "pinned load failed" })
      ~substring:"pinned load failed");
  let local = H.local host signals.id in
  let enabled =
    H.set_local
      host
      signals.id
      { local with presentation = { local.presentation with hints = Some true } }
  in
  assert (show_footer_hints enabled);
  assert (String.is_substring (screen enabled) ~substring:"j/k browse");
  let legacy_registry = Option.value_exn host.registry in
  let legacy_registry =
    { legacy_registry with
      tiles =
        List.filter legacy_registry.tiles ~f:(fun tile ->
          not (W.Tile_id.equal tile.id session.id))
    }
  in
  let legacy = H.receive host legacy_registry in
  assert (not (show_global_header legacy));
  assert (not (H.policy legacy signals).hints);
  (* Preset identity cannot suppress chrome once its domain tiles are gone. *)
  let without_waveforms =
    H.receive
      host
      { legacy_registry with
        tiles =
          List.filter legacy_registry.tiles ~f:(fun tile ->
            not (P.Waveforms.is_pane tile.kind))
      }
  in
  assert (show_global_header without_waveforms);
  assert (show_footer_hints without_waveforms);
  let overview, overview_data, overview_find = refinement_fixture P.Overview.definition in
  let live = overview_find "live-status" in
  assert (H.policy overview live).hints;
  assert (show_footer_hints overview);
  let overview_registry = Option.value_exn overview.registry in
  let overview_registry =
    { overview_registry with
      tiles =
        List.filter overview_registry.tiles ~f:(fun tile ->
          not (String.equal tile.kind "live-status"))
    }
  in
  let overview = H.receive overview overview_registry in
  assert (show_global_header overview);
  assert (
    String.is_substring
      (render overview overview_data { Dimensions.width = 120; height = 40 } |> plain_text)
      ~substring:"j/k browse")
;;

let%test_unit "WB-002 host context labels respect icon policy without duplicating pin \
               badges"
  =
  let host, data, find = refinement_fixture P.Overview.definition in
  let registry = Option.value_exn host.registry in
  let workspace = Option.value_exn (H.active host) in
  let context = W.context registry workspace.context in
  let independent =
    { context with id = W.Context_id.of_string "wb002-independent"; name = "Detached" }
  in
  let detached =
    H.receive
      host
      { registry with
        contexts = independent :: registry.contexts
      ; workspaces =
          List.map registry.workspaces ~f:(fun w ->
            if W.Workspace_id.equal w.id workspace.id
            then { w with context = independent.id }
            else w)
      }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    List.iter
      [ host, Indicator.Linked, "Linked"; detached, Independent, "Independent" ]
      ~f:(fun (host, kind, label) ->
        let host = { host with appearance = { host.appearance with icons } } in
        let registry = Option.value_exn host.registry in
        let host =
          H.receive
            host
            { registry with
              tiles =
                List.filter registry.tiles ~f:(fun tile ->
                  not (String.equal tile.kind "live-status"))
            }
        in
        let screen =
          render_workspace host data { Dimensions.width = 200; height = 40 } |> plain_text
        in
        assert (
          String.is_substring screen ~substring:(indicator_label icons kind label ^ ": ")));
    let tile = { (find "synthesis") with binding = Pin_run Asic_snapshot_fixture.run_a } in
    let host = { host with appearance = { host.appearance with icons } } in
    let screen = tile_view host data tile ~width:100 ~height:16 |> plain_text in
    let label = indicator_label icons Pin ("PIN " ^ run_label Asic_snapshot_fixture.run_a) in
    assert (String.is_substring screen ~substring:label);
    assert (
      List.length (String.substr_index_all screen ~pattern:label ~may_overlap:false) = 1))
;;

let%test_unit "WB-002 host freshness uses typed state and preserves fallback payloads" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "timing" in
  let run = Asic_snapshot_fixture.run_a in
  let fallback = [ "Freshness: running"; "Linked: pass"; "CACHED UNVERIFIED" ] in
  let terminal : Asic.Terminal_result.t =
    { attempt = "attempt"
    ; results_file = "results"
    ; results_digest = "digest"
    ; operation_status = "completed"
    ; physical_completion = "partial"
    ; acceptance = "unknown"
    ; timing_goal = "unknown"
    ; metrics = []
    ; checks = []
    ; evidence = "Freshness: running"
    ; execution_timing = None
    }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    let fallback_data =
      { data with summary = (fun _ -> None); run_lines = (fun _ _ -> fallback) }
    in
    assert (
      List.equal
        String.equal
        fallback
        (terminal_content host fallback_data tile ~run |> List.map ~f:E.text));
    let mismatched =
      { fallback_data with summary = (fun _ -> data.summary Asic_snapshot_fixture.run_b) }
    in
    assert (
      List.equal
        String.equal
        fallback
        (terminal_content host mismatched tile ~run |> List.map ~f:E.text));
    List.iter
      [ Asic.Summary.Freshness.Validated, Indicator.Completed
      ; Cached_unverified, Cached
      ; Missing_source, Unavailable
      ; Refresh_failed "running in an error is not activity", Stale
      ]
      ~f:(fun (freshness, kind) ->
        let summary =
          { (Option.value_exn (data.summary run)) with
            freshness
          ; terminal = Some terminal
          }
        in
        let data = { data with summary = (fun _ -> Some summary) } in
        let row = terminal_content host data tile ~run |> List.hd_exn |> E.text in
        let label =
          "Freshness: " ^ Sexp.to_string_hum (Asic.Summary.Freshness.sexp_of_t freshness)
        in
        assert (String.equal row (indicator_label icons kind label));
        let original = E.freshness freshness in
        let decorated = freshness_row icons freshness original in
        if Appearance.Icons.equal icons None_ then assert (E.equal_row original decorated)));
  let operation : Asic.Pending.t =
    { key = "refresh:host"
    ; kind = "refresh"
    ; state = "executing"
    ; run = Some run
    ; error = None
    ; activity = Evidence_read
    }
  in
  let snapshot = Option.value_exn data.asic in
  List.iter
    [ operation, true
    ; { operation with activity = Evidence_cache_lookup }, false
    ; { operation with activity = Unreported }, false
    ; { operation with state = "completed" }, false
    ; { operation with state = "failed"; error = Some "running" }, false
    ; { operation with state = "cancelled" }, false
    ; { operation with run = Some Asic_snapshot_fixture.run_b }, false
    ]
    ~f:(fun (operation, expected) ->
      let data = { data with asic = Some { snapshot with operations = [ operation ] } } in
      assert (Bool.equal (evidence_reading data ~views:[] ~runs:[ run ]) expected);
      let summary =
        { (Option.value_exn (data.summary run)) with terminal = Some terminal }
      in
      let data = { data with summary = (fun _ -> Some summary) } in
      let row = terminal_content host data tile ~run |> List.hd_exn |> E.text in
      let kind =
        if expected then Indicator.Running else freshness_indicator summary.freshness
      in
      assert (
        String.is_prefix
          row
          ~prefix:(indicator_label host.appearance.icons kind "Freshness: ")))
;;

let%test_unit "WB-002 inspector frames stop for terminal, cache-only and unavailable \
               states"
  =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "timing" in
  let run = Asic_snapshot_fixture.run_a in
  let view =
    Inspection_view.create ~scope:run ~run ~domain:"timing" ~stage:"signoff" ()
  in
  let operation : Asic.Pending.t =
    { key = Inspection_view.index_key view
    ; kind = "inspection"
    ; state = "executing"
    ; run = Some run
    ; error = None
    ; activity = Evidence_read
    }
  in
  let host =
    { (H.set_local host tile.id { H.default_local with inspection = Some view }) with
      focus = Some tile.id
    }
  in
  let frames glyph : Indicator.frames =
    { dot = View.text glyph; line = View.text glyph }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    List.iter
      [ operation, true
      ; { operation with state = "completed" }, false
      ; { operation with state = "failed"; error = Some "running" }, false
      ; { operation with state = "cancelled" }, false
      ; { operation with state = "detached" }, false
      ; { operation with activity = Evidence_cache_lookup }, false
      ; { operation with activity = Unreported }, false
      ; { operation with key = "obsolete-request" }, false
      ]
      ~f:(fun (operation, active) ->
        let snapshot = Option.value_exn data.asic in
        let data =
          { data with asic = Some { snapshot with operations = [ operation ] } }
        in
        let screen glyph width height =
          render ~indicator_frames:(frames glyph) host data { Dimensions.width; height }
        in
        let a = screen "A" 120 24 |> plain_text
        and b = screen "B" 120 24 |> plain_text in
        assert (
          Bool.equal
            (not (String.equal a b))
            (active && not (Appearance.Icons.equal icons None_)));
        assert (String.is_substring a ~substring:"INSPECT timing");
        List.iter
          [ 1, 1; 7, 3; 32, 8; 120, 24 ]
          ~f:(fun (width, height) ->
            let image = screen "A" width height in
            assert (View.width image = width && View.height image = height))));
  assert (
    String.equal
      (Indicator.text Ascii (inspection_indicator ~reading:false view))
      (Indicator.text Ascii Unavailable));
  assert (
    String.equal
      (Indicator.text
         Ascii
         (inspection_indicator
            ~reading:false
            { view with pending_error = Some "running" }))
      (Indicator.text Ascii Stale))
;;

let%test_unit "lifecycle icons do not turn readiness, ownership or completion into case \
               pass"
  =
  let glyph = Indicator.text Unicode in
  let check actual expected = assert (String.equal (glyph actual) (glyph expected)) in
  List.iter
    [ Planned_run.Submitting, Indicator.Running
    ; Allocated, Running
    ; Running, Running
    ; Completed, Completed
    ; Launch_failed, Failed
    ; Cancelled, Cancelled
    ; Detached, Unknown
    ; Unavailable, Unavailable
    ]
    ~f:(fun (state, expected) -> check (producer_indicator state) expected);
  List.iter
    [ Planned_run.Empty, Indicator.Not_requested
    ; Pending, Running
    ; Failed, Failed
    ; Stale, Stale
    ; Ready, Ready
    ]
    ~f:(fun (state, expected) -> check (plan_indicator state) expected);
  assert (not (String.equal (glyph (plan_indicator Ready)) (glyph Completed)));
  List.iter
    [ Job.State.Queued, Indicator.Pending
    ; Starting, Running
    ; Running, Running
    ; Complete, Completed
    ; Failed, Failed
    ; Cancelled, Cancelled
    ]
    ~f:(fun (state, expected) -> check (job_indicator state) expected);
  List.iter
    [ Simulation.Lifecycle.Finished; Cancelled; Interrupted; Queued ]
    ~f:(fun lifecycle ->
      check (Simulation_view.case_indicator ~lifecycle Running) Unknown);
  check (Simulation_view.case_indicator ~lifecycle:Running Running) Running;
  check (Simulation_view.case_indicator ~lifecycle:Finished Incomplete) Unknown;
  check (Simulation_view.case_indicator ~lifecycle:Finished Passed) Completed;
  check (Simulation_view.attempt_indicator Finished Unknown) Unknown;
  check (Simulation_view.attempt_indicator Finished Incomplete) Unknown;
  check (Simulation_view.attempt_indicator Finished Failed) Failed;
  check (Simulation_view.attempt_indicator Finished Passed) Completed;
  List.iter
    [ "pass"; "detached"; "unknown"; "unavailable"; "running in report" ]
    ~f:(fun status -> check (run_indicator status) Unknown)
;;

let%test_unit "cooperative Testing renderer keeps project scope and bounded panes" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let catalog = find "simulation-catalog" in
  assert (
    T.Binding.equal
      (H.binding_kind { catalog with binding = Pin_run Asic_snapshot_fixture.run_a })
      Project);
  let host = H.set_filter host catalog.id "directed" in
  assert (
    String.equal
      (Simulation_catalog.filter
         (Testing_workspace.catalog (H.testing_state host catalog.id)))
      "directed");
  List.iter
    [ 120, 40; 180, 55; 40, 12 ]
    ~f:(fun (width, height) ->
      let view = render host data { Dimensions.width; height } in
      assert (View.width view = width && View.height view = height));
  let frame text : Indicator.frames = { dot = View.text text; line = View.text text } in
  List.iter
    [ "simulation-catalog"
    ; "simulation-attempts"
    ; "simulation-cases"
    ; "simulation-detail"
    ; "simulation-artifacts"
    ; "simulation-logs"
    ]
    ~f:(fun kind ->
      let tile = find kind in
      let host = { host with appearance = { host.appearance with icons = None_ } } in
      let a =
        tile_view ~indicator_frames:(frame "A") host data tile ~width:48 ~height:12
      in
      let b =
        tile_view ~indicator_frames:(frame "B") host data tile ~width:48 ~height:12
      in
      assert (String.equal (plain_text a) (plain_text b));
      assert (
        not (String.is_substring (plain_text a) ~substring:(run_label Asic_snapshot_fixture.run_a))));
  let text =
    tile_view host data (find "project-tests") ~width:24 ~height:8 |> plain_text
  in
  assert (not (String.is_substring text ~substring:"Generic project tests"));
  assert (String.is_substring text ~substring:"Process results only")
;;

let%test_unit "long cooperative lists follow typed wrapped cursors and respect manual \
               scroll"
  =
  let host, data, find = refinement_fixture P.Testing.definition in
  let cases =
    List.init 40 ~f:(fun i ->
      { Simulation.Case.id = sprintf "case-%02d" i
      ; label = "Long case label wrapping across narrow display cells"
      })
  in
  let suite : Simulation.Suite.t =
    { id = "suite-00"
    ; label = "Selected suite"
    ; cases
    ; default_seed = "42"
    ; parameters =
        List.init 20 ~f:(fun i ->
          { Simulation.Parameter.key = sprintf "p%d" i
          ; label = "Parameter"
          ; default = "0"
          ; choices = []
          })
    }
  in
  let selection = Simulation_view.selection suite in
  let attempt : Simulation.Attempt.t =
    { id = "attempt-24"
    ; job = Job_id.of_string "exact-long-list-job"
    ; project_root = "/fixture"
    ; created_at = "now"
    ; parent = None
    ; captured =
        { selection
        ; discovery_digest = String.make 64 'd'
        ; provider_executable = "/provider"
        ; provider_args = []
        ; environment = Inherit_daemon
        }
    ; lifecycle = Finished
    ; outcome = Failed
    ; exit_code = Some 0
    ; diagnostic = None
    ; progress = None
    ; cases =
        List.map cases ~f:(fun c ->
          { Simulation.Case_result.case_id = c.id
          ; status = Failed
          ; message = None
          ; progress = None
          })
    ; artifacts =
        List.mapi cases ~f:(fun i c ->
          { Simulation.Artifact.id = sprintf "artifact-%02d" i
          ; attempt_id = "attempt-24"
          ; case_id = Some c.id
          ; label = sprintf "Artifact-%02d long wrapping artifact label" i
          ; kind = "report"
          ; media_type = "text/plain"
          ; size = Some 42
          ; sha256 = Some (String.make 64 'a')
          ; availability = Available
          })
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery =
        Some
          { protocol_version = 1
          ; suites = List.init 30 ~f:(fun i -> { suite with id = sprintf "suite-%02d" i })
          }
    ; discovery_digest = Some (String.make 64 'd')
    ; discovery_job = None
    ; discovery_error = None
    ; history_error = None
    ; next_before = None
    ; detail = Some attempt
    ; byte_page = None
    ; attempts =
        List.init 25 ~f:(fun i ->
          { Simulation.Summary.id = sprintf "attempt-%02d" i
          ; job = attempt.job
          ; suite = suite.id
          ; seed = "42"
          ; execution_timing = None
          ; created_at = "now"
          ; parent = None
          ; lifecycle = Finished
          ; outcome = Failed
          })
    }
  in
  let view =
    { Simulation_view.empty with snapshot = Some snapshot; attempt = Some attempt.id }
  in
  let host = H.set_simulation host (find "simulation-catalog").id view in
  let catalog_tile = find "simulation-catalog" in
  let physical = simulation_physical_rows host data catalog_tile ~width:18 in
  let i =
    List.findi_exn physical ~f:(fun _ (_, (target, _)) ->
      match target with
      | Some (Catalog_case "case-17") -> true
      | _ -> false)
    |> fst
  in
  let scrolled = H.set_local host catalog_tile.id
      { (H.local host catalog_tile.id) with scroll = i + 1; follow = false } in
  let clicked = select_body_row scrolled data catalog_tile ~width:18 ~height:4 ~row:0 in
  let catalog host = Testing_workspace.catalog (H.testing_state host catalog_tile.id) in
  assert (Option.equal String.equal (Simulation_catalog.case_id (catalog clicked)) (Some "case-17"));
  assert (List.equal String.equal (Simulation_catalog.selected_cases (catalog clicked))
            (Simulation_catalog.selected_cases (catalog host)));
  let overview = simulation_annotations host data (find "simulation-catalog") in
  let first_case =
    List.findi_exn overview ~f:(fun _ row -> row.Simulation_view.selected) |> fst
  in
  assert (first_case < 10);
  let prefix =
    List.take overview (first_case + 1)
    |> List.map ~f:(fun row -> row.Simulation_view.text)
    |> String.concat ~sep:"\n"
  in
  assert (not (String.is_substring prefix ~substring:(String.make 64 'd')));
  assert (not (String.is_substring prefix ~substring:"Parameter p"));
  assert (String.is_substring prefix ~substring:"Ready for explicit launch");
  List.iter
    [ 120, 40; 40, 12; 24, 8 ]
    ~f:(fun (width, height) ->
      let dimensions : Dimensions.t = { width; height } in
      List.iter
        [ "simulation-catalog", 39
        ; "simulation-attempts", 25
        ; "simulation-cases", 40
        ; "simulation-artifacts", 40
        ]
        ~f:(fun (kind, moves) ->
          let tile = find kind in
          let host = { host with focus = Some tile.id } in
          let host =
            if String.equal kind "simulation-attempts"
            then H.set_simulation host tile.id { view with attempt = None }
            else host
          in
          let reconcile host = reconcile_simulation_viewports host data dimensions in
          let selected_visible host =
            let _, _, layout = tile_layout host dimensions in
            let _, g =
              List.find_exn layout ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.id)
            in
            let _, _, _, body_width, body_height =
              body_geometry host tile ~width:g.width ~height:g.height
            in
            let rows =
              simulation_view_rows_with_selection host data tile ~width:body_width
            in
            let index = List.findi_exn rows ~f:(fun _ (selected, _) -> selected) |> fst in
            assert (List.count rows ~f:fst = 1);
            let start = (H.local host tile.id).scroll in
            assert (start <= index && index < start + body_height);
            let image = tile_view host data tile ~width:g.width ~height:g.height in
            assert (View.width image = g.width && View.height image = g.height)
          in
          let press host key =
            let host, _ = H.input host (Character key) ~commands:[] in
            let host = reconcile host in
            selected_visible host;
            host
          in
          let host =
            List.init moves ~f:Fn.id
            |> List.fold ~init:host ~f:(fun host _ -> press host 'j')
          in
          let state = H.testing_state host tile.id in
          (match kind with
           | "simulation-catalog" ->
             assert (
               Option.equal
                 String.equal
                 (Simulation_catalog.case_id (Testing_workspace.catalog state))
                 (Some "case-39"))
           | "simulation-attempts" ->
             assert (
               Option.equal
                 String.equal
                 (Testing_workspace.view state).attempt
                 (Some "attempt-24"))
           | "simulation-cases" ->
             assert (
               Option.equal
                 String.equal
                 (Testing_workspace.view state).case_id
                 (Some "case-39"))
           | "simulation-artifacts" ->
             assert (
               Option.equal
                 String.equal
                 (Testing_workspace.selected_artifact state)
                 (Some "artifact-39"))
           | _ -> assert false);
          assert ((H.local host tile.id).scroll > 0);
          let host = scroll_run_focused host data dimensions ~delta:Int.min_value in
          assert ((not (H.local host tile.id).follow) && (H.local host tile.id).scroll = 0);
          let host = reconcile host in
          assert ((H.local host tile.id).scroll = 0);
          let host = press host 'k' in
          assert ((H.local host tile.id).follow && (H.local host tile.id).scroll > 0);
          ignore
            (List.init moves ~f:Fn.id
             |> List.fold ~init:host ~f:(fun host _ -> press host 'k')
             : H.t)));
  List.iter [ "simulation-detail"; "simulation-logs" ] ~f:(fun kind ->
    let tile = find kind in
    let host =
      H.set_local host tile.id { (H.local host tile.id) with scroll = 17; follow = true }
    in
    let host =
      reconcile_simulation_viewports host data { Dimensions.width = 120; height = 40 }
    in
    assert ((H.local host tile.id).scroll = 17))
;;

let%test_unit "project command hints follow tile policy in compact and full images" =
  List.iter [ "project-tests"; "execution" ] ~f:(fun kind ->
    List.iter [ true; false ] ~f:(fun compact ->
      let definition =
        if compact
        then P.Testing.definition
        else { P.Testing.definition with id = "overview" }
      in
      let host, data, find = refinement_fixture definition in
      let tile = find kind in
      List.iter [ true; false ] ~f:(fun hints ->
        let host =
          H.set_local
            host
            tile.id
            { (H.local host tile.id) with
              presentation = { T.inherit_ with hints = Some hints }
            }
        in
        let image = tile_view host data tile ~width:100 ~height:20 |> plain_text in
        assert (Bool.equal hints (String.is_substring image ~substring:"b build | t test"));
        assert (
          String.is_substring
            image
            ~substring:
              (if compact then "Process results only" else "Environment: fixture")))))
;;

let%test_unit "cooperative detail artifacts and logs paint typed values only" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let host = { host with appearance = { host.appearance with icons = None_ } } in
  let logs = [ "Passed Failed report artifact"; "Failed / Finished"; "case: Passed" ] in
  let data = { data with log_lines = (fun _ -> logs) } in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  List.iter
    [ Simulation.Artifact.Availability.Available, Role.Success
    ; Missing, Warning
    ; Changed, Warning
    ; Rejected "Passed Failed", Failure
    ]
    ~f:(fun (availability, availability_role) ->
      let artifact : Simulation.Artifact.t =
        { id = "artifact"
        ; attempt_id = "Failed-ID"
        ; case_id = Some "Passed-case"
        ; label = "Failed report"
        ; kind = "report"
        ; media_type = "text/plain"
        ; size = None
        ; sha256 = None
        ; availability
        }
      in
      List.iter
        [ ( Simulation.Lifecycle.Finished
          , Simulation.Outcome.Failed
          , Role.Success
          , Role.Failure )
        ; Finished, Passed, Success, Success
        ; Running, Unknown, Running, Muted
        ; Interrupted, Incomplete, Warning, Warning
        ]
        ~f:(fun (lifecycle, outcome, lifecycle_role, outcome_role) ->
          let attempt : Simulation.Attempt.t =
            { id = "Failed-ID"
            ; job = Job_id.of_string "Passed-job"
            ; project_root = "/fixture"
            ; created_at = "now"
            ; parent = None
            ; captured =
                { selection =
                    { suite = "suite"
                    ; cases = []
                    ; seed = "42"
                    ; parameters = []
                    ; asic_inputs = []
                    }
                ; discovery_digest = "digest"
                ; provider_executable = "/provider"
                ; provider_args = []
                ; environment = Inherit_daemon
                }
            ; lifecycle
            ; outcome
            ; exit_code = None
            ; diagnostic = Some "Passed Failed diagnostic"
            ; progress = None
            ; cases =
                [ { case_id = "Passed-case"
                  ; status = Failed
                  ; message = Some "Passed message"
                  ; progress = None
                  }
                ]
            ; artifacts = [ artifact ]
            ; next_sequence = 0
            ; recent_events = []
            ; execution_timing = None
            }
          in
          let snapshot : Simulation.Snapshot.t =
            { configured = true
            ; discovery = None
            ; discovery_digest = None
            ; discovery_job = None
            ; discovery_error = None
            ; history_error = None
            ; next_before = None
            ; detail = Some attempt
            ; byte_page = None
            ; attempts = []
            }
          in
          let host =
            H.set_simulation
              host
              (find "simulation-detail").id
              { Simulation_view.empty with
                snapshot = Some snapshot
              ; attempt = Some attempt.id
              }
            |> fun host ->
            H.update_testing host (find "simulation-detail").id (fun state ->
              Testing_workspace.select_artifact state artifact.id)
          in
          let life = Simulation_view.atom Simulation.Lifecycle.sexp_of_t lifecycle in
          let result = Simulation_view.atom Simulation.Outcome.sexp_of_t outcome in
          let available =
            Simulation_view.atom Simulation.Artifact.Availability.sexp_of_t availability
          in
          let check kind text segments =
            let source = simulation_annotations host data (find kind) in
            let index =
              List.findi_exn source ~f:(fun _ r ->
                String.equal r.Simulation_view.text text)
              |> fst
            in
            let expected =
              List.concat_map segments ~f:(fun (text, role) ->
                Overview_tiles.display_clusters text
                |> List.map ~f:(fun text -> text, role))
            in
            List.iter [ 7; 120 ] ~f:(fun width ->
              let images = simulation_view_rows host data (find kind) ~width in
              let offset =
                List.take source index
                |> List.sum (module Int) ~f:(fun r ->
                  List.length (wrap_cells ~width r.Simulation_view.text))
              in
              List.iteri expected ~f:(fun i (text, role) ->
                let actual =
                  List.nth_exn images (offset + (i / width))
                  |> View.crop ~l:(i mod width)
                  |> box ~width:1 ~height:1
                in
                let expected = View.text ~attrs:(Role.attrs host.appearance role) text in
                assert (String.equal (ansi actual) (ansi expected))))
          in
          check
            "simulation-detail"
            (result ^ " / " ^ life)
            [ result, outcome_role; " / ", Foreground; life, lifecycle_role ];
          check
            "simulation-detail"
            "Passed-case: Failed"
            [ "Passed-case: ", Foreground; "Failed", Failure ];
          check
            "simulation-detail"
            "Passed Failed diagnostic"
            [ "Passed Failed diagnostic", Foreground ];
          check
            "simulation-detail"
            ("Availability: " ^ available)
            [ "Availability: ", Foreground; available, availability_role ];
          check
            "simulation-detail"
            "Attempt: Failed-ID"
            [ "Attempt: Failed-ID", Foreground ];
          check
            "simulation-artifacts"
            ("> Failed report — Passed-case [" ^ available ^ "]")
            [ "> Failed report — Passed-case [", Foreground
            ; available, availability_role
            ; "]", Foreground
            ];
          check
            "simulation-logs"
            (life ^ "/" ^ result)
            [ life, lifecycle_role; "/", Foreground; result, outcome_role ];
          check
            "simulation-logs"
            "Attempt: Failed-ID; job: Passed-job"
            [ "Attempt: Failed-ID; job: Passed-job", Foreground ];
          let projected =
            List.drop (simulation_annotations host data (find "simulation-logs")) 2
          in
          assert (
            List.equal
              String.equal
              logs
              (List.map projected ~f:(fun r -> r.Simulation_view.text)));
          List.iter logs ~f:(fun text ->
            check "simulation-logs" text [ text, Foreground ])))
;;

let%test_unit "Testing paints readiness and independent attempt facts in actual images" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let suite : Simulation.Suite.t =
    { id = "Failed-suite"
    ; label = "Running label"
    ; cases = [ { id = "case"; label = "Case" } ]
    ; default_seed = "42"
    ; parameters = []
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = Some { protocol_version = 1; suites = [ suite ] }
    ; discovery_digest = Some "digest"
    ; discovery_job = None
    ; discovery_error = None
    ; history_error = None
    ; next_before = None
    ; detail = None
    ; byte_page = None
    ; attempts = []
    }
  in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    let token role text = View.text ~attrs:(Role.attrs host.appearance role) text in
    let check_cell image ~x role text =
      let actual = View.crop ~l:x image |> box ~width:1 ~height:1 in
      assert (String.equal (ansi actual) (ansi (token role text)))
    in
    List.iter
      [ ( Simulation.Lifecycle.Finished
        , Simulation.Outcome.Passed
        , Role.Success
        , Role.Success )
      ; Finished, Failed, Success, Failure
      ; Running, Unknown, Running, Muted
      ; Cancelled, Incomplete, Warning, Warning
      ]
      ~f:(fun (lifecycle, outcome, lifecycle_role, outcome_role) ->
        let summary : Simulation.Summary.t =
          { id = "Passed-ID"
          ; job = Job_id.of_string "job"
          ; suite = suite.id
          ; seed = "42"
          ; execution_timing = None
          ; created_at = "now"
          ; parent = None
          ; lifecycle
          ; outcome
          }
        in
        let tile = find "simulation-attempts" in
        let host =
          H.set_simulation
            host
            tile.id
            { Simulation_view.empty with
              snapshot = Some { snapshot with attempts = [ summary ] }
            ; attempt = Some summary.id
            }
        in
        let prefix = "> Passed-ID " in
        let lifecycle_text =
          Simulation_view.atom Simulation.Lifecycle.sexp_of_t lifecycle
        in
        let outcome_text = Simulation_view.atom Simulation.Outcome.sexp_of_t outcome in
        let expected =
          [ prefix, Role.Foreground
          ; lifecycle_text, lifecycle_role
          ; "/", Foreground
          ; outcome_text, outcome_role
          ]
          |> List.concat_map ~f:(fun (text, role) ->
            String.to_list text |> List.map ~f:(fun c -> String.of_char c, role))
        in
        let icon_width = if Appearance.Icons.equal icons None_ then 0 else 2 in
        let context =
          Overview_tiles.display_clusters "    Time: unknown · Failed-suite · seed=42"
        in
        List.iter [ 5; 11; 120 ] ~f:(fun width ->
          let selected_rows = simulation_view_rows_with_selection host data tile ~width in
          assert (List.count selected_rows ~f:fst = 1);
          assert (fst (List.hd_exn selected_rows));
          let rendered = List.map selected_rows ~f:snd in
          let capacity = width - icon_width in
          let first_height = (List.length expected + capacity - 1) / capacity in
          assert (
            List.length rendered
            = first_height + ((List.length context + width - 1) / width));
          List.iteri expected ~f:(fun i (text, role) ->
            check_cell
              (List.nth_exn rendered (i / capacity))
              ~x:(icon_width + (i mod capacity))
              role
              text);
          List.iteri context ~f:(fun i text ->
            check_cell
              (List.nth_exn rendered (first_height + (i / width)))
              ~x:(i mod width)
              Foreground
              text);
          if icon_width > 0
          then (
            let glyph =
              match lifecycle, outcome, icons with
              | Finished, Passed, Unicode -> "✓"
              | Finished, Passed, _ -> "+"
              | Finished, Failed, _ -> "!"
              | Running, _, Unicode -> "⣷"
              | Running, _, _ -> "|"
              | Cancelled, _, Unicode -> "×"
              | _ -> "x"
            in
            let role =
              if Simulation.Outcome.equal outcome Failed
              then Role.Failure
              else lifecycle_role
            in
            let actual = List.hd_exn rendered |> box ~width:1 ~height:1 in
            let expected =
              View.text ~attrs:[ Attr.fg (Role.foreground host.appearance role) ] glyph
            in
            assert (String.equal (ansi actual) (ansi expected)))));
    List.iter [ true; false ] ~f:(fun ready ->
      let tile = find "simulation-catalog" in
      let host =
        H.set_simulation
          host
          tile.id
          { Simulation_view.empty with
            snapshot = Some { snapshot with configured = ready }
          }
      in
      let expected =
        if ready
        then "Ready for explicit launch"
        else "Launch disabled: No simulation provider configured"
      in
      let row =
        simulation_view_rows host data tile ~width:120
        |> List.find_exn ~f:(fun row ->
          String.is_prefix (plain_text row) ~prefix:expected)
      in
      String.iteri expected ~f:(fun x c ->
        check_cell row ~x (if ready then Success else Warning) (String.of_char c))))
;;

let%test_unit "simulation annotations preserve typed rows, logs and terminal case fences" =
  let definition =
    { P.Testing.definition with
      tiles = P.Testing.definition.tiles @ [ P.Common.tile "simulation" ]
    }
  in
  let host, data, find = refinement_fixture definition in
  let tile = find "simulation" in
  let attempt : Simulation.Attempt.t =
    { id = "exact-running-ID"
    ; job = Job_id.of_string "exact-job"
    ; project_root = "/fixture"
    ; created_at = "now"
    ; parent = None
    ; captured =
        { selection =
            { suite = "suite"
            ; cases = [ "case" ]
            ; seed = "17"
            ; parameters = []
            ; asic_inputs = []
            }
        ; discovery_digest = "digest"
        ; provider_executable = "/fixture/provider"
        ; provider_args = []
        ; environment = V1.Environment_selection.Inherit_daemon
        }
    ; lifecycle = Running
    ; outcome = Unknown
    ; exit_code = None
    ; diagnostic = Some "completed failed running\nraw diagnostic"
    ; progress = None
    ; cases =
        [ { case_id = "case"
          ; status = Running
          ; message = Some "passed\nraw message"
          ; progress = None
          }
        ]
    ; artifacts = []
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = None
    ; discovery_digest = None
    ; discovery_job = None
    ; discovery_error = None
    ; history_error = Some "running\nraw history error"
    ; attempts = []
    ; next_before = None
    ; detail = Some attempt
    ; byte_page = None
    }
  in
  let logs =
    [ "running failed completed"
    ; "Attempt: exact-running-ID"
    ; "case: Running"
    ; "raw\nlog"
    ]
  in
  let data = { data with log_lines = (fun _ -> logs) } in
  let frames glyph : Indicator.frames =
    { dot = View.text glyph; line = View.text glyph }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    List.iter [ Simulation.Lifecycle.Running; Finished; Interrupted ] ~f:(fun lifecycle ->
      let simulation =
        { Simulation_view.empty with
          snapshot = Some { snapshot with detail = Some { attempt with lifecycle } }
        ; attempt = Some attempt.id
        ; logs = true
        ; case_id = Some "case"
        }
      in
      let host =
        H.set_local
          { host with appearance = { host.appearance with icons } }
          tile.id
          { H.default_local with simulation }
      in
      let source = Simulation_view.rows simulation ~log_lines:data.log_lines in
      let projected =
        Simulation_view.annotated_rows simulation ~log_lines:data.log_lines
      in
      assert (
        List.equal
          String.equal
          source
          (List.map projected ~f:(fun row -> row.Simulation_view.text)));
      let log_count = List.concat_map logs ~f:String.split_lines |> List.length in
      let log_start = List.length source - 1 - log_count in
      List.iteri projected ~f:(fun i { Simulation_view.text; indicator = kind; _ } ->
        if (i >= log_start && i < log_start + log_count)
           || List.mem
                [ "raw diagnostic"
                ; "completed failed running"
                ; "  passed"
                ; "  raw message"
                ; "running"
                ]
                text
                ~equal:String.equal
        then assert (Option.is_none kind));
      let views frames width =
        simulation_view_rows ~indicator_frames:frames host data tile ~width
      in
      let a = views (frames "A") 120 |> View.vcat |> plain_text in
      let b = views (frames "B") 120 |> View.vcat |> plain_text in
      let animated =
        Simulation.Lifecycle.equal lifecycle Running
        && not (Appearance.Icons.equal icons None_)
      in
      assert (Bool.equal (not (String.equal a b)) animated);
      List.iter logs ~f:(fun log ->
        String.split_lines log
        |> List.iter ~f:(fun line -> assert (String.is_substring a ~substring:line)));
      if Appearance.Icons.equal icons None_
      then
        assert (
          String.equal
            a
            (List.map source ~f:(fun text -> View.text text |> box ~width:120 ~height:1)
             |> View.vcat
             |> plain_text));
      List.iter [ 0; 1; 7; 32; 120 ] ~f:(fun width ->
        let a = views (frames "A") width
        and b = views (frames "B") width in
        assert (List.length a = List.length b);
        List.iter a ~f:(fun view ->
          assert (View.width view = width && View.height view = 1)))))
;;

let%test_unit "shared host frames follow exact producers and leave tile layout unchanged" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let stage_tile = find "stage-checklist" in
  let plan_tile = find "planned-run" in
  let snapshot = Option.value_exn data.asic in
  let operation : Asic.Pending.t =
    { key = "run:exact"
    ; kind = "run"
    ; state = "executing"
    ; run = Some Asic_snapshot_fixture.run_a
    ; error = None
    ; activity = Unreported
    }
  in
  let snapshot =
    { snapshot with
      operations = [ operation ]
    ; runs =
        List.map snapshot.runs ~f:(fun execution ->
          { execution with
            status = "observing"
          ; stages =
              List.map execution.stages ~f:(fun stage -> { stage with status = Running })
          })
    }
  in
  let data =
    { data with asic = Some snapshot; runs = [ Asic_snapshot_fixture.run_a, "observing" ] }
  in
  assert (run_has_producer data Asic_snapshot_fixture.run_a);
  assert (not (run_has_producer data Asic_snapshot_fixture.run_b));
  let frames glyph : Indicator.frames =
    { dot = View.text glyph; line = View.text glyph }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    let render data tile frame width height =
      tile_view ~indicator_frames:(frames frame) host data tile ~width ~height
    in
    let a = render data stage_tile "A" 100 16 |> plain_text in
    let b = render data stage_tile "B" 100 16 |> plain_text in
    assert (Bool.equal (not (String.equal a b)) (not (Appearance.Icons.equal icons None_)));
    List.iter
      [ []
      ; [ { operation with run = Some Asic_snapshot_fixture.run_b } ]
      ; [ { operation with state = "detached" } ]
      ]
      ~f:(fun operations ->
        let data = { data with asic = Some { snapshot with operations } } in
        assert (not (run_has_producer data Asic_snapshot_fixture.run_a));
        assert (
          String.equal
            (render data stage_tile "A" 100 16 |> plain_text)
            (render data stage_tile "B" 100 16 |> plain_text)));
    List.iter
      [ "completed"; "failed"; "detached"; "unknown"; "unavailable" ]
      ~f:(fun status ->
        let data =
          { data with
            asic =
              Some
                { snapshot with
                  runs = List.map snapshot.runs ~f:(fun run -> { run with status })
                }
          }
        in
        assert (not (run_has_producer data Asic_snapshot_fixture.run_a)));
    let selection : Asic.Selection.t =
      { chip_target = None
      ; flow = "flow"
      ; profile = "profile"
      ; endpoint = "exact-endpoint"
      ; assignments = []
      }
    in
    let planned_run, _ = Planned_run.begin_plan Planned_run.empty selection in
    let pending_host = { host with planned_run; planned_preparation = false } in
    let plan frame =
      planned_view_rows ~indicator_frames:(frames frame) pending_host plan_tile ~width:100
      |> View.vcat
      |> plain_text
    in
    assert (
      Bool.equal
        (not (String.equal (plan "A") (plan "B")))
        (not (Appearance.Icons.equal icons None_)));
    assert (String.is_substring (plan "A") ~substring:"exact-endpoint");
    List.iter
      [ 0, 0; 1, 1; 32, 8; 100, 16 ]
      ~f:(fun (width, height) ->
        List.iter [ stage_tile; plan_tile ] ~f:(fun tile ->
          let a = render data tile "A" width height
          and b = render data tile "B" width height in
          assert (View.width a = width && View.height a = height);
          assert (View.width b = width && View.height b = height))))
;;

let%test_unit "generic job icons retain exact identity and completion vocabulary" =
  let definition =
    { P.Testing.definition with
      id = "generic-job-icon-regression"
    ; tiles =
        List.map P.Testing.definition.tiles ~f:(fun tile ->
          { tile with
            presentation = { tile.presentation with compact_summary = Some false }
          })
    }
  in
  let host, data, find = refinement_fixture definition in
  let tile = find "project-tests" in
  let base = List.hd_exn Baseline_fixture.jobs in
  let frames glyph : Indicator.frames =
    { dot = View.text glyph; line = View.text glyph }
  in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    List.iter Job.State.all ~f:(fun state ->
      let job = { base with kind = { namespace = "dune"; name = "test" }; state } in
      let data = { data with jobs = [ job ] } in
      let render frame =
        tile_view ~indicator_frames:(frames frame) host data tile ~width:140 ~height:16
      in
      let a = render "A" |> plain_text
      and b = render "B" |> plain_text in
      let animated =
        List.mem [ Job.State.Starting; Running ] state ~equal:Job.State.equal
        && not (Appearance.Icons.equal icons None_)
      in
      assert (Bool.equal (not (String.equal a b)) animated);
      assert (
        String.is_substring
          a
          ~substring:(Overview_tiles.short_id (Job_id.to_string job.id)));
      assert (String.is_substring a ~substring:(Job.State.to_string state));
      assert (String.is_substring a ~substring:"Case details / progress: unavailable");
      assert (not (String.is_substring a ~substring:"Passed"));
      List.iter
        [ 0, 0; 1, 1; 32, 8 ]
        ~f:(fun (width, height) ->
          let view =
            tile_view ~indicator_frames:(frames "A") host data tile ~width ~height
          in
          assert (View.width view = width && View.height view = height))))
;;

let%test_unit "execution rows use readable labels while selected detail retains raw kinds"
  =
  let host, data, find = refinement_fixture P.Testing.definition in
  let tile = find "execution" in
  let base = List.hd_exn Baseline_fixture.jobs in
  List.iter
    [ "simulation", "discover", "sim discover"
    ; "simulation", "run", "sim run"
    ; "dune", "test", "dune test"
    ; "project-driver", "generate-rtl", "RTL generate"
    ; "provider", "run", "provider.run"
    ]
    ~f:(fun (namespace, name, label) ->
      let job = { base with kind = { namespace; name } } in
      let host =
        H.set_local
          host
          tile.id
          { (H.local host tile.id) with cursor = Some (Job_id.to_string job.id) }
      in
      let rows = execution_annotations host { data with jobs = [ job ] } tile in
      let job_row = List.last_exn rows in
      assert job_row.selected;
      assert (String.is_suffix job_row.text ~suffix:("  " ^ label));
      assert (
        List.exists rows ~f:(fun row ->
          String.equal row.text ("Kind: " ^ namespace ^ "." ^ name))))
;;

let%test_unit "execution labels reuse simulation history from their own workspace" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let tile = find "execution" in
  let catalog = find "simulation-catalog" in
  let base = List.hd_exn Baseline_fixture.jobs in
  let job = { base with kind = { namespace = "simulation"; name = "run" } } in
  let summary : Simulation.Summary.t =
    { id = "attempt"
    ; job = job.id
    ; suite = "fifo"
    ; seed = "1"
    ; execution_timing = None
    ; created_at = "now"
    ; parent = None
    ; lifecycle = Finished
    ; outcome = Passed
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = None
    ; discovery_digest = None
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = [ summary ]
    ; next_before = None
    ; detail = None
    ; byte_page = None
    ; history_error = None
    }
  in
  let view = { Simulation_view.empty with snapshot = Some snapshot } in
  let host = H.set_simulation host catalog.id view in
  let rows = execution_annotations host { data with jobs = [ job ] } tile in
  assert (String.is_suffix (List.last_exn rows).text ~suffix:"  sim run fifo");
  let other_job = { job with id = Job_id.of_string "other-job" } in
  let rows = execution_annotations host { data with jobs = [ other_job ] } tile in
  assert (String.is_suffix (List.last_exn rows).text ~suffix:"  sim run")
;;

let%test_unit "execution images paint typed states and condense only display identities" =
  let host, data, find = refinement_fixture P.Testing.definition in
  let id = "Failed-0123456789abcdef0123456789-Complete" in
  let base = List.hd_exn Baseline_fixture.jobs in
  let ansi view =
    let buffer = Buffer.create 100 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  List.iter [ "execution"; "project-tests" ] ~f:(fun kind ->
    let tile = find kind in
    List.iter Appearance.Icons.all ~f:(fun icons ->
      let host = { host with appearance = { host.appearance with icons } } in
      List.iter Job.State.all ~f:(fun state ->
        let job =
          { base with
            id = Job_id.of_string id
          ; kind = { namespace = "dune"; name = "test" }
          ; state
          }
        in
        let data = { data with jobs = [ job ] } in
        let host =
          H.set_local host tile.id { (H.local host tile.id) with cursor = Some id }
        in
        let annotations = execution_annotations host data tile in
        assert (List.last_exn annotations).selected;
        assert (
          List.exists annotations ~f:(fun row -> String.equal row.text "Kind: dune.test"));
        assert (Option.equal String.equal (H.local host tile.id).cursor (Some id));
        let commands =
          H.catalog host ~project:None ~jobs:[ { job with state = Running } ]
        in
        assert (
          List.exists commands ~f:(fun command ->
            match command.H.action with
            | Cancel actual -> Job_id.equal actual job.id
            | _ -> false));
        List.iter
          [ 0; List.length annotations - 1 ]
          ~f:(fun scroll ->
            let host = H.set_local host tile.id { (H.local host tile.id) with scroll } in
            let image = tile_view host data tile ~width:100 ~height:18 in
            let text = plain_text image in
            assert (String.is_substring text ~substring:(Overview_tiles.short_id id));
            assert (not (String.is_substring text ~substring:id));
            assert (String.is_substring text ~substring:"dune test");
            let status = Job.State.to_string state in
            let role =
              match state with
              | Complete -> Role.Success
              | Failed -> Failure
              | Starting | Running -> Running
              | Queued | Cancelled -> Warning
            in
            (* Find the status in the actual job row, not the selected-job summary. *)
            let y =
              List.find_exn
                (List.init (View.height image) ~f:Fn.id)
                ~f:(fun y ->
                  let line =
                    View.crop ~t:y image |> box ~width:100 ~height:1 |> plain_text
                  in
                  String.is_substring line ~substring:(Overview_tiles.short_id id))
            in
            let x =
              let suffix = status ^ "  dune test" in
              List.find_exn
                (List.init (100 - String.length suffix) ~f:Fn.id)
                ~f:(fun x ->
                  String.equal
                    (View.crop ~l:x ~t:y image
                     |> box ~width:(String.length suffix) ~height:1
                     |> plain_text)
                    suffix)
            in
            let actual =
              View.crop ~l:x ~t:y image |> box ~width:(String.length status) ~height:1
            in
            let prefix = ">" ^ Overview_tiles.short_id id ^ "  " in
            let identity =
              View.crop ~l:(x - cell_width prefix) ~t:y image
              |> box ~width:(cell_width prefix) ~height:1
            in
            let neutral =
              View.text ~attrs:(Role.attrs host.appearance Foreground) prefix
              |> colored host.appearance Foreground
            in
            [%test_result: string] (ansi identity) ~expect:(ansi neutral);
            let expected =
              View.text ~attrs:(Role.attrs host.appearance role) status
              |> colored host.appearance Foreground
            in
            [%test_result: string] (ansi actual) ~expect:(ansi expected)))))
;;

let%test_unit "Overview renders four primary domains with shallow frames and bounded \
               selector growth"
  =
  let host, data, find = refinement_fixture P.Overview.definition in
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let _, compact, layout = tile_layout host dimensions in
  assert (not compact);
  let cell tile =
    List.find_exn layout ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.W.Tile.id) |> snd
  in
  let navigation = cell (find "workspace-tabs") in
  assert (navigation.height = 1);
  assert ((cell (find "live-status")).y = navigation.y + 1);
  List.iter [ "live-status"; "run-selector" ] ~f:(fun kind ->
    let tile = find kind in
    let g = cell tile in
    let panel = panel_geometry host tile ~width:g.width ~height:g.height in
    assert (panel.border = 1 && panel.vertical_padding = 0);
    let image = tile_view host data tile ~width:g.width ~height:g.height in
    assert (String.is_prefix (plain_text image) ~prefix:"╭");
    let _, _, _, _, rows = body_geometry host tile ~width:g.width ~height:g.height in
    assert (rows = g.height - 2));
  let image = render_workspace host data dimensions |> plain_text in
  List.iter [ "synthesis"; "timing"; "placement"; "routing" ] ~f:(fun kind ->
    assert (String.is_substring image ~substring:kind);
    let tile = find kind in
    let g = cell tile in
    let panel = tile_view host data tile ~width:g.width ~height:g.height in
    let first = View.crop ~b:(g.height - 1) panel |> plain_text in
    assert (String.is_substring first ~substring:kind);
    let body =
      View.crop ~l:1 ~t:1 panel |> box ~width:(g.width - 2) ~height:1 |> plain_text
    in
    assert (
      String.is_substring
        body
        ~substring:
          (match kind with
           | "synthesis" -> "Reported cells (agg.): 50"
           | "timing" -> "not reported unknown"
           | "placement" -> "Aggregate resources: unavailable"
           | _ -> "Routing-stage metrics: unsupported"));
    assert (not (String.is_substring body ~substring:(String.uppercase kind))));
  assert (String.is_substring image ~substring:"Reported cells (agg.): 50");
  let selector = find "run-selector" in
  let large =
    H.set_local
      host
      selector.id
      { H.default_local with
        presentation = { T.inherit_ with run_selector_rows = Some 1_000_000 }
      }
  in
  let _, compact, expanded = tile_layout large dimensions in
  assert (not compact);
  let grown =
    List.find_exn expanded ~f:(fun (t, _) -> W.Tile_id.equal t.id selector.id) |> snd
  in
  assert (grown.height > (cell selector).height && grown.height < dimensions.height);
  let _, _, _, _, capacity =
    body_geometry large selector ~width:grown.width ~height:grown.height
  in
  assert (capacity < 1_000_000);
  List.iter
    [ 1, 1; 12, 4; 80, 24 ]
    ~f:(fun (width, height) ->
      let view = render_workspace large data { Dimensions.width; height } in
      assert (View.width view = width && View.height view = height));
  let synthesis = find "synthesis" in
  let explicit =
    H.set_local
      host
      synthesis.id
      { H.default_local with
        synthesis = Synthesis_view.State.set_mode Synthesis_view.State.empty Cells
      }
  in
  assert (Option.is_none (compact_rows explicit data synthesis));
  assert (Option.is_some (semantic_rows explicit data synthesis ~width:60 ~height:12))
;;

let%test_unit "physical detail without finalization retains stages independently of \
               headers and compression"
  =
  let host, data, find = refinement_fixture P.Overview.definition in
  let snapshot = Option.value_exn data.asic in
  let summary run =
    Option.map (data.summary run) ~f:(fun s -> { s with terminal = None })
  in
  let data =
    { data with
      summary
    ; run_context = (fun _ -> [ "Request endpoint: timing" ])
    ; run_lines = (fun _ _ -> failwith "physical detail must use typed stage evidence")
    }
  in
  List.iter [ "placement"; "routing" ] ~f:(fun kind ->
    let tile = find kind in
    List.iter [ false; true ] ~f:(fun header ->
      List.iter [ false; true ] ~f:(fun detail ->
        let local = H.local host tile.id in
        let host =
          H.set_local
            host
            tile.id
            { local with
              presentation = { T.inherit_ with header = Some header }
            ; terminal_result = { local.terminal_result with detail }
            }
        in
        let render host data = tile_view host data tile ~width:100 ~height:32 in
        let image = render host data in
        let text = plain_text image in
        assert (String.is_substring text ~substring:(kind ^ ": completed"));
        assert (not (String.is_substring text ~substring:"No terminal result imported"));
        let heading = View.crop ~b:31 image |> plain_text |> String.lowercase in
        assert (Bool.equal header (String.is_substring heading ~substring:kind));
        if detail
        then (
          assert (String.is_substring text ~substring:("Stage ID: " ^ kind));
          assert (String.is_substring text ~substring:"Request endpoint: timing"));
        List.iter [ None; Some false; Some true ] ~f:(fun choice ->
          let global = H.set_global_compression host choice in
          let workspace = H.set_workspace_compression global tile.workspace choice in
          let local = H.local workspace tile.id in
          let tile_host, _ =
            H.set_presentation
              workspace
              tile.id
              { local.presentation with string_compression = choice }
          in
          List.iter [ global; workspace; tile_host ] ~f:(fun changed ->
            assert (String.equal text (render changed data |> plain_text))));
        (* A Timing-only observation does not imply physical completion, nor invent a
           terminal result or borrow cached synthesis measurements. *)
        let missing =
          { data with
            asic =
              Some
                { snapshot with
                  runs =
                    List.map snapshot.runs ~f:(fun r ->
                      { r with
                        stages =
                          [ { Asic.Stage.id = "timing"
                            ; name = "Timing"
                            ; status = Completed
                            ; requested = true
                            ; reason = None
                            ; action = None
                            ; execution_timing = None
                            }
                          ]
                      })
                }
          ; summary = (fun _ -> None)
          }
        in
        let text = render host missing |> plain_text in
        assert (String.is_substring text ~substring:"Stage: not reported");
        List.iter
          [ "completed"; "Cell count:"; "No terminal result imported" ]
          ~f:(fun substring -> assert (not (String.is_substring text ~substring)));
        let mismatched =
          { missing with
            summary =
              (fun _ ->
                Option.map (summary Asic_snapshot_fixture.run_a) ~f:(fun s ->
                  { s with run = Asic_snapshot_fixture.run_b; source_digest = "wrong-run-source" }))
          }
        in
        let text = render host mismatched |> plain_text in
        assert (String.is_substring text ~substring:"Stage: not reported");
        assert (not (String.is_substring text ~substring:"wrong-run-source")))))
;;

let%test_unit "two-row compact facts retain stages and stale warnings with freshness off" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let synthesis = find "synthesis" in
  let data =
    { data with
      summary =
        (fun run ->
          Option.map (data.summary run) ~f:(fun s ->
            { s with freshness = Cached_unverified }))
    }
  in
  let before = compact_rows host data synthesis |> Option.value_exn in
  let quiet =
    H.set_local
      host
      synthesis.id
      { H.default_local with presentation = { T.inherit_ with freshness = Some false } }
  in
  let after = compact_rows quiet data synthesis |> Option.value_exn in
  assert (Poly.equal (List.take before 2) (List.take after 2));
  (* Warning freshness survives chrome suppression; ordinary validated freshness is
     optional, without hiding either the metric or the independent stage. *)
  assert (List.length after = List.length before);
  let validated =
    { data with
      summary =
        (fun run ->
          Option.map (data.summary run) ~f:(fun s -> { s with freshness = Validated }))
    }
  in
  let before_validated = compact_rows host validated synthesis |> Option.value_exn in
  let after_validated = compact_rows quiet validated synthesis |> Option.value_exn in
  assert (List.length after_validated = List.length before_validated - 1);
  assert (Poly.equal (List.take before_validated 2) (List.take after_validated 2));
  let text = tile_view quiet data synthesis ~width:100 ~height:4 |> plain_text in
  List.iter
    [ "Reported cells (agg.): 50"; "cached/unverified"; "synthesis: completed" ]
    ~f:(fun substring -> assert (String.is_substring text ~substring));
  let checklist = find "stage-checklist" in
  let normal = utility_rows host data checklist |> Option.value_exn in
  assert (List.length normal = 8);
  assert (List.for_all normal ~f:(fun row -> Option.is_some row.Overview_tiles.status));
  let detailed =
    H.set_local
      host
      checklist.id
      { H.default_local with
        utility_detail = true
      ; cursor = Some "synthesis"
      ; stage_run = Some Asic_snapshot_fixture.run_a
      }
  in
  let details =
    utility_rows detailed data checklist
    |> Option.value_exn
    |> Overview_tiles.inspection_lines
    |> String.concat ~sep:"\n"
  in
  List.iter
    [ "Stage ID: synthesis"; "Source digest:"; "Accept (agg.)" ]
    ~f:(fun substring -> assert (String.is_substring details ~substring))
;;

let%test_unit "shallow plan always shows readiness and endpoint; detail retains metadata" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "planned-run" in
  let snapshot = Option.value_exn data.asic in
  let selection : Asic.Selection.t =
    { chip_target = None
    ; flow = String.concat (List.init 100 ~f:(fun _ -> "界"))
    ; profile = "Exact-Profile"
    ; endpoint = "signoff"
    ; assignments = [ String.make 100 'A' ]
    }
  in
  let preview : Asic.Preview.t =
    { selection
    ; plan_identity = "Exact-Identity-AbC"
    ; plan_json = "{\"exact\":\"Metadata-AbC\"}"
    }
  in
  let key = List.hd_exn (Plain_rpc.keys (Plan selection) snapshot) in
  let snapshot =
    { snapshot with
      preview = Some preview
    ; operations =
        [ { key
          ; kind = "plan"
          ; state = "completed"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
        ]
    }
  in
  let host =
    { host with
      planned_run = Planned_run.receive host.planned_run ~revision:1 snapshot
    ; planned_preparation = false
    }
  in
  let preparing =
    { host with stage_preparation = Some "Preparing NEW run through routing" }
  in
  let preparation_text =
    planned_rows preparing tile ~width:80
    |> List.map ~f:(fun row -> row.Planned_run.text)
    |> String.concat ~sep:"\n"
  in
  assert (
    String.is_substring preparation_text ~substring:"Preparing NEW run through routing");
  assert (String.is_substring preparation_text ~substring:"Launch disabled");
  assert (not (String.is_substring preparation_text ~substring:"ready:"));
  List.iter [ 4; 5 ] ~f:(fun height ->
    let image = tile_view host data tile ~width:60 ~height in
    assert (View.width image = 60 && View.height image = height);
    let text = plain_text image in
    assert (String.is_substring text ~substring:"ready:");
    assert (String.is_substring text ~substring:"endpoint: signoff"));
  let detail = H.set_local host tile.id { H.default_local with utility_detail = true } in
  let full =
    planned_rows detail tile ~width:30
    |> List.map ~f:(fun row -> row.Planned_run.text)
    |> String.concat
  in
  List.iter
    [ "Exact-Identity-AbC"
    ; "Metadata-AbC"
    ; selection.flow
    ; List.hd_exn selection.assignments
    ]
    ~f:(fun substring -> assert (String.is_substring full ~substring));
  let launched_snapshot =
    { snapshot with
      launches =
        [ { key = "rendered-launch"; preview; run_id = Some Asic_snapshot_fixture.run_b.id } ]
    ; runs = [ Asic_snapshot_fixture.run Asic_snapshot_fixture.run_b ]
    }
  in
  let launched_host =
    { host with
      planned_run = Planned_run.receive host.planned_run ~revision:2 launched_snapshot
    }
  in
  let launched_text =
    tile_view
      launched_host
      { data with asic = Some launched_snapshot }
      tile
      ~width:80
      ~height:10
    |> plain_text
  in
  List.iter
    [ "last launch: completed"; "exact allocated run: fixture-B"; "rendered-launch" ]
    ~f:(fun substring -> assert (String.is_substring launched_text ~substring))
;;

let%test_unit "live schemes change semantic paint without geometry registry or queries" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let layout host =
    tile_layout host dimensions
    |> fun (_, _, cells) ->
    List.map cells ~f:(fun (tile, geometry) -> tile.W.Tile.id, geometry)
  in
  let original = layout host in
  let plain = render host data dimensions |> plain_text in
  List.iter Appearance.Scheme.all ~f:(fun scheme ->
    let appearance = { host.H.appearance with scheme } in
    let changed = H.set_scheme host scheme in
    assert (phys_equal changed.registry host.registry);
    assert (phys_equal changed.locals host.locals);
    assert (phys_equal changed.focus host.focus);
    assert (Poly.equal original (layout changed));
    assert (String.equal plain (render changed data dimensions |> plain_text));
    let title =
      tile_view changed data (find "live-status") ~width:40 ~height:5 |> plain_text
    in
    assert (String.is_prefix title ~prefix:"╭ session ─");
    List.iter Appearance.Color.all ~f:(fun color ->
      let appearance = { appearance with color } in
      let attrs = Role.attrs appearance in
      assert (not (Poly.equal (attrs Success) (attrs Failure)));
      assert (not (Poly.equal (attrs Warning) (attrs Foreground)));
      assert (
        not
          (Poly.equal
             (Role.backdrop appearance Selection)
             (Role.backdrop appearance Foreground)))))
;;

let%test_unit "theme picker paints the live workspace and restores committed paint on cancel" =
  let host, data, _ = refinement_fixture P.Overview.definition in
  let host = H.set_scheme host Carbon in
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let now = Time_ns.epoch in
  let draw host = render ~now host data dimensions in
  let top_row view =
    let buffer = Buffer.create 512 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (dimensions.width, 1)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let step host key =
    match H.input host key ~commands:[] with
    | host, No_effect -> host
    | _ -> failwith "preview emitted an action"
  in
  let original = top_row (draw host) in
  let opened = H.open_theme_picker host (Option.value_exn (H.capture host)) in
  let screen = draw opened |> plain_text in
  List.iter [ "Choose theme"; "Carbon [active]"; "Enter apply"; "Esc cancel" ] ~f:(fun text ->
    assert (String.is_substring screen ~substring:text));
  assert (String.equal original (top_row (draw opened)));
  let preview = step opened (Text "crimson") in
  let live = top_row (draw preview) in
  assert (not (String.equal live original));
  assert (String.equal live (top_row (draw (H.set_scheme host Crimson))));
  assert (Appearance.equal preview.appearance host.appearance);
  let no_match = step preview (Text "zzzzzz") in
  let screen = draw no_match |> plain_text in
  assert (String.is_substring screen ~substring:"No matching themes");
  assert (not (String.is_substring screen ~substring:"[Apply]"));
  assert (String.equal live (top_row (draw no_match)));
  assert (String.equal original (top_row (draw (step no_match Escape))));
  List.iter [ 80, 24; 30, 9; 12, 4 ] ~f:(fun (width, height) ->
    let image = render ~now preview data { Dimensions.width; height } in
    assert (View.width image = width && View.height image = height))
;;

let%test_unit "host vertical stages preserve exact selected identity and detail" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let tile = find "stage-checklist" in
  let host =
    H.set_local
      host
      tile.id
      { H.default_local with cursor = Some "signoff"; stage_run = Some Asic_snapshot_fixture.run_a }
  in
  List.iter
    [ 120, 5; 40, 10; 12, 4 ]
    ~f:(fun (width, height) ->
      let image = tile_view host data tile ~width ~height in
      assert (View.width image = width && View.height image = height));
  let text = tile_view host data tile ~width:120 ~height:5 |> plain_text in
  let selected_line =
    String.split_lines text
    |> List.find_exn ~f:(fun line -> String.is_substring line ~substring:"signoff:")
  in
  assert (String.is_substring selected_line ~substring:"completed");
  let detail =
    H.set_local host tile.id { (H.local host tile.id) with utility_detail = true }
  in
  assert (
    String.is_substring
      (tile_view detail data tile ~width:100 ~height:20 |> plain_text)
      ~substring:"Stage ID: signoff")
;;

let%test_unit "Timing panes render typed selection and exact scoped detail with normal \
               panel chrome"
  =
  let host, data, find = refinement_fixture P.Timing.definition in
  let paths = find "timing-paths"
  and detail = find "timing-detail"
  and context = find "timing-context" in
  let _, compact, layout = tile_layout host { Dimensions.width = 120; height = 40 } in
  assert (not compact);
  assert (
    not
      (List.exists (H.tiles host) ~f:(fun tile ->
         String.equal tile.W.Tile.kind "stage-checklist")));
  let cell tile =
    List.find_exn layout ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.W.Tile.id) |> snd
  in
  let pg = cell paths
  and dg = cell detail
  and cg = cell context in
  assert (pg.x < dg.x && dg.x = cg.x && dg.y < cg.y);
  assert (Int.abs (dg.width - pg.width) <= 1 && dg.height > cg.height);
  List.iter [ paths; detail; context ] ~f:(fun tile ->
    let g = cell tile in
    let panel = panel_geometry host tile ~width:g.width ~height:g.height in
    assert (panel.border = 1 && panel.vertical_padding = 0));
  let rows =
    List.init 30 ~f:(fun i ->
      { Asic_inspection.Row.id = Int.to_string i
      ; name = sprintf "path-%02d/endpoint/Q" i
      ; category = "path"
      ; producer = "sta"
      ; corner = Some "slow"
      ; group = Some "clk"
      ; value = Some (Float.of_int i -. 1.)
      ; unit_ = Some "ns"
      ; status = "violated"
      ; source = "/exact/report"
      ; fields = [ "startpoint", "input/D" ]
      })
  in
  let index : Asic_inspection.Index.t =
    { run = Asic_snapshot_fixture.run_a
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "exact-source-digest"
    ; execution_file = "/exact/execution"
    ; execution_sha256 = "exact-sha"
    ; rows
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = true
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let snapshot = { (Option.value_exn data.asic) with inspections = [ index ] } in
  let state =
    Inspection_view.reconcile
      (Timing_workspace.create ~generation:1 ~run:Asic_snapshot_fixture.run_a ~stage:"signoff")
      snapshot
  in
  let state = { state with selected = Some "29" } in
  let host = H.set_timing host paths state in
  let data = { data with asic = Some snapshot } in
  let _, headers, page = timing_paths_page state ~height:10 in
  let clicked = List.findi_exn page ~f:(fun _ path -> not (String.equal path.id "29")) in
  let select row = select_body_row host data paths ~width:70 ~height:10 ~row in
  assert (phys_equal host (select (headers - 1)));
  let selected = Option.value_exn (H.timing (select (headers + fst clicked)) paths) in
  assert (Option.equal String.equal selected.selected (Some (snd clicked).id));
  assert (Option.is_none selected.requested);
  List.iter [ paths; detail; context ] ~f:(fun tile ->
    let image = tile_view host data tile ~width:70 ~height:14 in
    assert (String.is_prefix (plain_text image) ~prefix:"╭");
    assert (String.is_substring (plain_text image) ~substring:"timing"));
  let path_image = tile_view host data paths ~width:70 ~height:14 |> plain_text in
  assert (String.is_substring path_image ~substring:"path-29/endpoint/Q");
  assert (String.is_substring path_image ~substring:"violated");
  assert (String.is_substring path_image ~substring:"Cached unverified");
  assert (
    String.is_substring
      (tile_view host data detail ~width:70 ~height:14 |> plain_text)
      ~substring:"Path: path-29/endpoint/Q");
  assert (
    String.is_substring
      (tile_view host data detail ~width:70 ~height:14 |> plain_text)
      ~substring:"Slack: 28.000 ns · violated");
  assert (
    String.is_substring
      (tile_view host data context ~width:70 ~height:14 |> plain_text)
      ~substring:"Row: 29");
  let selection = Timing_workspace.selection state |> Option.value_exn in
  assert (
    String.equal selection.row_id "29"
    && String.equal selection.source_digest "exact-source-digest");
  assert (
    String.is_substring
      (tile_view host data context ~width:70 ~height:14 |> plain_text)
      ~substring:"exac…gest");
  List.iter [ Timing_workspace.Detail; Context ] ~f:(fun pane ->
    List.iter
      [ 12, 3; 40, 7; 70, 14 ]
      ~f:(fun (width, height) ->
        List.iter [ 0; 2; Int.max_value ] ~f:(fun scroll ->
          let actual =
            timing_body host.appearance ~pane ~scroll ~width ~height state |> plain_text
          in
          let expected =
            Timing_workspace.rows ~pane ~scroll ~width ~height state
            |> lines ~width ~height
            |> plain_text
          in
          assert (String.equal actual expected))));
  let prefix = timing_semantic_prefix ~pane:Detail ~width:70 state in
  assert (
    List.exists prefix ~f:(fun (role, text) ->
      match role with
      | Metric -> String.equal text "Slack: 28.000 ns · violated"
      | _ -> false));
  let prefix = timing_semantic_prefix ~pane:Context ~width:70 state in
  assert (
    List.exists prefix ~f:(fun (role, text) ->
      match role with
      | Warning -> String.equal text "CACHED UNVERIFIED"
      | _ -> false));
  let verified = { state with index = Some { index with cached_unverified = false } } in
  let verified_prefix = timing_semantic_prefix ~pane:Context ~width:70 verified in
  let verified_image =
    timing_body host.appearance ~pane:Context ~scroll:0 ~width:70 ~height:40 verified
  in
  let check_token ~line ~x role token =
    let y =
      List.findi_exn verified_prefix ~f:(fun _ (_, text) -> String.equal text line) |> fst
    in
    let ansi view =
      let buffer = Buffer.create 128 in
      Notty.Render.to_buffer
        buffer
        Notty.Cap.ansi
        (0, 0)
        (cell_width token, 1)
        (View.Private.notty_image view);
      Buffer.contents buffer
    in
    let actual =
      View.crop ~l:x ~t:y verified_image |> box ~width:(cell_width token) ~height:1
    in
    assert (
      String.equal
        (ansi actual)
        (ansi (View.text ~attrs:(Role.attrs host.appearance role) token)))
  in
  check_token
    ~line:"Verified cached observation"
    ~x:0
    Success
    "Verified cached observation";
  check_token ~line:"Source digest: exac…gest" ~x:0 Muted "Source digest:";
  check_token ~line:"Source digest: exac…gest" ~x:14 Focus " exac…gest";
  List.iter [ Timing_workspace.Detail; Context ] ~f:(fun pane ->
    let typed = timing_semantic_prefix ~pane ~width:70 state |> List.map ~f:snd in
    let actual =
      Timing_workspace.rows ~pane ~scroll:0 ~width:70 ~height:Int.max_value state
    in
    assert (List.equal String.equal typed (List.take actual (List.length typed))));
  let long_source = String.make 2048 'j'
  and long_field = String.make 3072 'f' in
  let long_row =
    { (List.last_exn rows) with
      name = String.make 3000 'n'
    ; source = long_source
    ; fields =
        [ "startpoint", "exact/start/D"
        ; "endpoint", "exact/end/Q"
        ; "payload", long_field
        ]
    }
  in
  let payload = "failed pending selected raw\nprovider second line" in
  let provider_detail : Asic_inspection.Detail.t =
    { run = state.run
    ; domain = state.domain
    ; stage = state.stage
    ; source_digest = index.source_digest
    ; row_id = long_row.id
    ; text = payload
    ; error = None
    }
  in
  let loaded =
    { state with
      index = Some { index with rows = [ long_row ] }
    ; cache = None
    ; requested = Some (index.source_digest, long_row.id)
    ; detail = Some provider_detail
    }
  in
  let prefix = timing_semantic_prefix ~pane:Detail ~width:40 loaded in
  assert (List.length prefix = 4);
  let rendered =
    timing_body host.appearance ~pane:Detail ~scroll:0 ~width:40 ~height:6 loaded
  in
  let body = View.crop ~t:4 rendered |> box ~width:40 ~height:2 in
  let expected =
    String.split_lines payload |> lines ~appearance:host.appearance ~width:40 ~height:2
  in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (40, 2)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  assert (String.equal (ansi body) (ansi expected));
  let scrolled =
    timing_body host.appearance ~pane:Detail ~scroll:4 ~width:40 ~height:2 loaded
  in
  assert (String.equal (ansi scrolled) (ansi expected));
  let full_context =
    timing_semantic_prefix
      ~presentation:{ T.defaults with string_compression = false }
      ~pane:Context
      ~width:40
      loaded
    |> List.map ~f:snd
    |> String.concat
  in
  List.iter
    [ "Row: 29"
    ; long_source
    ; long_field
    ; index.source_digest
    ; "exact/start/D"
    ; "exact/end/Q"
    ]
    ~f:(fun value -> assert (String.is_substring full_context ~substring:value));
  let pasting =
    { state with
      pasting = true
    ; filter = "literal"
    ; filter_notice = Some "Rejected control text"
    }
  in
  let paste_image =
    timing_body host.appearance ~pane:Paths ~scroll:0 ~width:70 ~height:12 pasting
    |> plain_text
  in
  assert (String.is_substring paste_image ~substring:"Paste filter: literal|");
  assert (String.is_substring paste_image ~substring:"Rejected control text");
  let tiny = tile_view host data paths ~width:40 ~height:3 |> plain_text in
  assert (String.is_substring tiny ~substring:"path-29");
  let registry = Option.value_exn host.registry in
  let registry =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun t ->
          if W.Tile_id.equal t.id paths.id
          then { t with binding = Pin_run Asic_snapshot_fixture.run_b }
          else t)
    }
  in
  let mismatched = { host with registry = Some registry } in
  let stale =
    tile_view mismatched data (W.tile registry paths.id) ~width:70 ~height:14
    |> plain_text
  in
  assert (not (String.is_substring stale ~substring:"path-29"));
  assert (String.is_substring stale ~substring:"No matching Timing investigation")
;;

let%test_unit "actual palette reserves a blank footer separator within its styled frame" =
  let host, data, _ = refinement_fixture P.Overview.definition in
  let palette : H.palette =
    { capture = Option.value_exn (H.capture host)
    ; commands = []
    ; query = "palette-query"
    ; index = 0
    ; argument = None
    }
  in
  let host = { host with palette = Some palette } in
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let image = render host data dimensions in
  let bounds = Palette_view.bounds ~width:dimensions.width ~height:dimensions.height in
  let blank =
    View.crop ~l:(bounds.x + 1) ~t:(bounds.y + bounds.height - 3) image
    |> box ~width:(bounds.width - 2) ~height:1
    |> plain_text
  in
  assert (String.for_all blank ~f:(Char.equal ' '));
  let panel =
    View.crop ~l:bounds.x ~t:bounds.y image
    |> box ~width:bounds.width ~height:bounds.height
    |> plain_text
  in
  assert (String.is_prefix panel ~prefix:"╭");
  assert (String.is_substring panel ~substring:"> palette-query▏");
  assert (String.is_substring panel ~substring:"Esc return");
  assert (String.is_substring panel ~substring:"╰─")
;;

let%test_unit "main-window and palette hints hide independently and reclaim rows" =
  let base, data, _ = refinement_fixture P.Overview.definition in
  let base = { base with notice = "" } in
  let catalog = H.catalog base ~project:None ~jobs:[] in
  let palette_for host index =
    { H.capture = Option.value_exn (H.capture host)
    ; commands = catalog
    ; query = ""
    ; index
    ; argument = None
    }
  in
  let panel_text host dimensions =
    let image = render host data dimensions in
    let bounds =
      Palette_view.bounds ~width:dimensions.Dimensions.width ~height:dimensions.height
    in
    View.crop ~l:bounds.x ~t:bounds.y image
    |> box ~width:bounds.width ~height:bounds.height
    |> plain_text
  in
  let visible_titles text =
    List.count catalog ~f:(fun command ->
      String.is_substring text ~substring:(String.prefix command.title 20))
  in
  List.iter
    [ { Dimensions.width = 120; height = 40 }
    ; { width = 80; height = 24 }
    ; { width = 44; height = 14 }
    ; { width = 30; height = 9 }
    ]
    ~f:(fun dimensions ->
      let shown_available, _, _ = tile_layout base dimensions in
      let shown_panel =
        panel_text { base with palette = Some (palette_for base 0) } dimensions
      in
      List.iter [ true; false ] ~f:(fun main_hints ->
        List.iter [ true; false ] ~f:(fun palette_hints ->
          let host = { base with main_hints; palette_hints } in
          (* Main window: the hidden hint row is given back to the tiles, and every tile
             (and therefore its focus marker) stays inside the reclaimed area. *)
          let available, compact, layout = tile_layout host dimensions in
          assert (available = shown_available + if main_hints then 0 else 1);
          assert (not (List.is_empty layout));
          List.iter layout ~f:(fun (_, (g : W.Geometry.t)) ->
            assert (g.y + g.height <= available && g.x + g.width <= dimensions.width));
          let screen = plain_text (render host data dimensions) in
          let hint =
            if compact then "Compact: focused tile only" else "Space c c commands"
          in
          assert (Bool.equal (String.is_substring screen ~substring:hint) main_hints);
          (* Palette: independent of the main-window choice; hidden hints return the hint
             row and its separator to the result list, and the last selection stays
             visible. *)
          let last = List.length catalog - 1 in
          List.iter [ 0; last ] ~f:(fun index ->
            let opened = { host with palette = Some (palette_for host index) } in
            let panel = panel_text opened dimensions in
            let other =
              panel_text { opened with main_hints = not main_hints } dimensions
            in
            assert (String.equal panel other);
            if dimensions.height >= 14
            then (
              assert (
                Bool.equal
                  (String.is_substring panel ~substring:"Tab/Shift-Tab ↑/↓")
                  palette_hints);
              assert (String.is_substring panel ~substring:"> "));
            if index = 0 && dimensions.height >= 14
            then
              assert (
                visible_titles panel
                = visible_titles shown_panel + if palette_hints then 0 else 2));
          (* A notice still claims the bottom row in both places. *)
          let noticed = { host with notice = "Unavailable: fixture reason" } in
          assert (fst3 (tile_layout noticed dimensions) = shown_available);
          if dimensions.height >= 14
          then (
            assert (
              String.is_substring
                (plain_text (render noticed data dimensions))
                ~substring:"Unavailable: fixture reason");
            assert (
              String.is_substring
                (panel_text
                   { noticed with palette = Some (palette_for noticed 0) }
                   dimensions)
                ~substring:"Unavailable: fixture reason")))));
  (* The existing global chrome toggle is unchanged: it still suppresses the footer
     regardless of the hint choices, and hint choices never touch it. *)
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let chromeless = { base with chrome = false } in
  List.iter [ true; false ] ~f:(fun main_hints ->
    let host = { chromeless with main_hints } in
    assert (fst3 (tile_layout host dimensions) = fst3 (tile_layout chromeless dimensions));
    assert (
      not
        (String.is_substring
           (plain_text (render host data dimensions))
           ~substring:"Space c c commands")))
;;

let%test_unit "every hint area is restorable by keyboard while all are hidden" =
  let base, _, _ = refinement_fixture P.Overview.definition in
  let hidden = { base with main_hints = false; palette_hints = false; notice = "" } in
  let catalog = H.catalog hidden ~project:None ~jobs:[] in
  let step host event = fst (H.input host event ~commands:catalog) in
  let chord key =
    let host = step (step hidden (Character ' ')) (Character 'c') in
    H.input host (Character key) ~commands:catalog
  in
  (match chord 'h' with
   | after, Execute (_, Toggle_main_hints) ->
     assert (after.prefix = 0 && Option.is_none after.palette)
   | _ -> assert false);
  (match chord 'p' with
   | after, Execute (_, Toggle_palette_hints) ->
     assert (after.prefix = 0 && Option.is_none after.palette)
   | _ -> assert false);
  (* The palette itself stays reachable and searchable; both restore commands are
     discoverable, name their chord, and run from the captured target. *)
  let opened =
    step (step (step hidden (Character ' ')) (Character 'c')) (Character 'c')
  in
  let searched =
    String.fold "hints" ~init:opened ~f:(fun host c -> step host (Character c))
  in
  let p = Option.value_exn searched.palette in
  let ids = List.map (H.matches p) ~f:(fun command -> command.H.id) in
  assert (List.mem ids "host.hints.main" ~equal:String.equal);
  assert (List.mem ids "host.hints.palette" ~equal:String.equal);
  List.iter catalog ~f:(fun command ->
    match command.id with
    | "host.hints.main" ->
      assert (String.is_substring command.title ~substring:"Show main window");
      assert (String.is_substring command.title ~substring:"Space c h")
    | "host.hints.palette" ->
      assert (String.is_substring command.title ~substring:"Show command palette");
      assert (String.is_substring command.title ~substring:"Space c p")
    | _ -> ());
  let rec select host =
    let p = Option.value_exn host.H.palette in
    if String.equal (List.nth_exn (H.matches p) p.index).id "host.hints.palette"
    then host
    else select (step host Next)
  in
  (match H.input (select searched) Enter ~commands:catalog with
   | after, Execute (_, Toggle_palette_hints) ->
     assert (Option.is_none after.palette);
     assert (Option.equal W.Tile_id.equal after.focus hidden.focus)
   | _ -> assert false);
  let dismissed = step searched Escape in
  assert (Option.is_none dismissed.palette);
  assert (Option.equal W.Tile_id.equal dismissed.focus hidden.focus);
  assert ((not dismissed.main_hints) && not dismissed.palette_hints)
;;

let%test_unit "Timing Session connected uses shared success theme attributes" =
  let host, data, find = refinement_fixture P.Timing.definition in
  let tile = find "live-status" in
  let host =
    { host with appearance = { host.appearance with density = Compact; icons = None_ } }
  in
  let host =
    H.set_local
      host
      tile.id
      { (H.local host tile.id) with
        presentation =
          { T.inherit_ with
            header = Some false
          ; frame = Some false
          ; padding = Some 0
          ; hints = Some false
          }
      }
  in
  let image =
    tile_view host { data with status = "Connected" } tile ~width:60 ~height:7
  in
  let ansi image =
    let buffer = Buffer.create 128 in
    Notty.Render.to_buffer buffer Notty.Cap.ansi (0, 0) (9, 1) image;
    Buffer.contents buffer
  in
  let actual =
    View.crop ~l:12 image |> box ~width:9 ~height:1 |> View.Private.notty_image
  in
  let expected =
    View.text ~attrs:(Role.attrs host.appearance Success) "Connected"
    |> View.Private.notty_image
  in
  assert (String.equal (ansi actual) (ansi expected));
  assert (Overview_tiles.Role.equal (Overview_tiles.connection_role "Connected") Success)
;;

let%test_unit "selector width budget preserves useful IDs and aligns compact status" =
  let run =
    { Asic_snapshot_fixture.run_a with id = "long-distinguishable-selected-run-abcdefghijklmnop" }
  in
  let wide =
    run_selector_row
      ~string_compression:false
      ~width:90
      ~status_width:9
      ~cursor:true
      ~active:true
      run
      "completed"
  in
  assert (String.is_substring wide ~substring:(run_label run));
  assert (String.is_prefix wide ~prefix:">* ");
  assert (cell_width wide = 90);
  let narrow =
    run_selector_row
      ~string_compression:false
      ~width:36
      ~status_width:9
      ~cursor:true
      ~active:false
      run
      "completed"
  in
  assert (cell_width narrow = 36);
  assert (String.is_suffix narrow ~suffix:" completed");
  assert (String.is_substring narrow ~substring:"#1");
  List.iter [ 0; 1; 2; 3; 5; 10; 20 ] ~f:(fun width ->
    let label = fit_label ~width "界é selected run identity 界é" in
    assert (cell_width label <= width))
;;

let%test_unit "actual utility and selector token images carry independent attributes" =
  let appearance = { Appearance.default with density = Compact; icons = None_ } in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let slice view ~x ~width = View.crop ~l:x view |> box ~width ~height:1 |> ansi in
  let token role text = View.text ~attrs:(Role.attrs appearance role) text |> ansi in
  let utility =
    Overview_tiles.render
      ~appearance
      ~attrs:(utility_attrs appearance)
      ~width:40
      ~height:1
      [ Overview_tiles.row ~role:Success "Evidence" "validated" ]
  in
  assert (String.equal (slice utility ~x:0 ~width:10) (token Foreground "Evidence: "));
  assert (String.equal (slice utility ~x:10 ~width:9) (token Success "validated"));
  assert (not (String.equal (token Foreground "validated") (token Success "validated")));
  List.iter Appearance.Scheme.all ~f:(fun scheme ->
    let appearance = { appearance with scheme } in
    let bg = Role.backdrop appearance Selection in
    let expected role text =
      View.text ~attrs:(Role.attrs appearance role @ [ Attr.bg bg ]) text |> ansi
    in
    List.iter
      [ "validated", Overview_tiles.Role.Success, Role.Success
      ; "cached/unverified", Warning, Warning
      ; "pending", Warning, Warning
      ; "running", Running, Running
      ; "cancelled", Warning, Warning
      ; "future-value", Foreground, Foreground
      ]
      ~f:(fun (value, utility_role, value_role) ->
        let image =
          Overview_tiles.render
            ~selected_bg:bg
            ~appearance
            ~attrs:(utility_attrs appearance)
            ~width:40
            ~height:1
            [ Overview_tiles.row ~active:true ~role:utility_role "Evidence" value ]
        in
        assert (
          String.equal (slice image ~x:0 ~width:10) (expected Foreground "Evidence: "));
        assert (
          String.equal
            (slice image ~x:10 ~width:(cell_width value))
            (expected value_role value))));
  let stage_appearance = { appearance with icons = Ascii } in
  let stage_bg = Role.backdrop stage_appearance Selection in
  let stage : Asic.Stage.t =
    { id = "synthesis"
    ; name = "Synthesis"
    ; status = Completed
    ; requested = true
    ; reason = None
    ; action = None
    ; execution_timing = None
    }
  in
  let strip =
    Overview_tiles.Stage_strip.model
      ~appearance:stage_appearance
      ~width:80
      ~run:Asic_snapshot_fixture.run_a
      ~selected_id:(Some stage.id)
      [ stage ]
  in
  let image =
    Overview_tiles.Stage_strip.render
      ~selected_bg:stage_bg
      ~appearance:stage_appearance
      ~attrs:(utility_attrs stage_appearance)
      ~width:80
      ~height:2
      strip
  in
  let expected role text =
    View.text ~attrs:(Role.attrs stage_appearance role @ [ Attr.bg stage_bg ]) text
    |> ansi
  in
  let prefix = "> " ^ Indicator.text Ascii Completed ^ " " in
  let prefix_width = cell_width prefix in
  assert (String.equal (slice image ~x:0 ~width:prefix_width) (expected Selection prefix));
  assert (
    String.equal
      (slice image ~x:prefix_width ~width:11)
      (expected Foreground "Synthesis: "));
  assert (
    String.equal
      (slice image ~x:(prefix_width + 11) ~width:9)
      (expected Success "completed"));
  let detail = View.crop ~t:1 image in
  let label = strip.selected_line.label ^ ": " in
  assert (
    String.equal
      (slice detail ~x:prefix_width ~width:(cell_width label))
      (expected Foreground label));
  assert (
    String.equal
      (slice detail ~x:(prefix_width + cell_width label) ~width:9)
      (expected Success "completed"));
  let run = { Asic_snapshot_fixture.run_a with id = "failed-running-identity" } in
  List.iter
    [ "completed", Role.Success
    ; "failed", Failure
    ; "running", Running
    ; "starting", Running
    ; "pending", Warning
    ; "queued", Warning
    ; "cancelled", Warning
    ; "interrupted", Warning
    ; "skipped", Warning
    ; "pass", Foreground
    ; "future-status", Foreground
    ]
    ~f:(fun (status, role) ->
      List.iter [ false; true ] ~f:(fun cursor ->
        let width = 65
        and status_width = cell_width status in
        let image =
          run_selector_view
            ~string_compression:false
            appearance
            ~width
            ~status_width
            ~cursor
            ~active:true
            run
            status
        in
        let expected role text =
          View.text
            ~attrs:
              (Role.attrs appearance role
               @ if cursor then [ Attr.bg (Role.backdrop appearance Selection) ] else [])
            text
          |> ansi
        in
        let identity = if cursor then ">* " else " * " in
        assert (
          String.equal
            (slice image ~x:0 ~width:3)
            (expected (if cursor then Selection else Foreground) identity));
        assert (
          String.equal
            (slice image ~x:3 ~width:(cell_width (run_label run)))
            (expected (if cursor then Selection else Foreground) (run_label run)));
        assert (
          String.equal
            (slice image ~x:(width - status_width) ~width:status_width)
            (expected role status))));
  let clipped =
    run_selector_view
      appearance
      ~width:20
      ~status_width:3
      ~cursor:false
      ~active:false
      run
      "completed"
  in
  assert (String.equal (slice clipped ~x:17 ~width:3) (token Success "com"))
;;

let%test_unit "actual tile headers use legible ink on fresh, light, and legacy grounds" =
  let host, data, find = refinement_fixture P.Overview.definition in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let tile = find "live-status" in
  List.iter
    [ Appearance.default.scheme, 0xe0e5e9, 0x191d22
    ; Appearance.Scheme.silver_light, 0x293540, 0xf5f7f9
    ; Appearance.Scheme.Carbon, 0xffffff, 0x000000
    ]
    ~f:(fun (scheme, fg, bg) ->
      let expected =
        View.text
          ~attrs:[ Attr.fg (Role.color fg); Attr.bg (Role.color bg); Attr.bold ]
          "session"
      in
      List.iter Appearance.Preset.all ~f:(fun preset ->
        List.iter [ false; true ] ~f:(fun focused ->
          let appearance = { Appearance.default with preset; scheme } in
          let host =
            { host with H.appearance; focus = (if focused then Some tile.id else None) }
          in
          let image = tile_view host data tile ~width:60 ~height:8 in
          let y, line =
            plain_text image
            |> String.split_lines
            |> List.findi_exn ~f:(fun _ line ->
              String.is_substring line ~substring:"session")
          in
          let prefix =
            String.substr_index_exn line ~pattern:"session" |> String.prefix line
          in
          let header =
            View.crop ~l:(cell_width prefix) ~t:y image |> box ~width:7 ~height:1
          in
          assert (String.equal (ansi header) (ansi expected));
          let geometry = panel_geometry host tile ~width:60 ~height:8 in
          if geometry.border > 0
          then (
            let corner = if Appearance.Preset.equal preset Instrument then "╭" else "┌" in
            let expected =
              View.text
                ~attrs:(Role.attrs appearance (if focused then Focus else Border))
                corner
            in
            assert (String.equal (ansi (box ~width:1 ~height:1 image)) (ansi expected))))))
;;

let%test_unit "palette prompt caret and fuzzy spans have independent typed attributes" =
  let appearance = { Appearance.default with color = Vivid } in
  let ansi view =
    let buffer = Buffer.create 200 in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.ansi
      (0, 0)
      (View.width view, View.height view)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let normal = ansi (View.text ~attrs:(Role.attrs appearance Surface) "x")
  and selected = ansi (View.text ~attrs:(Role.attrs appearance Selection) "x")
  and matched = ansi (View.text ~attrs:(Role.attrs appearance Matched) "x") in
  assert (not (String.equal normal selected));
  assert (not (String.equal selected matched));
  let query =
    Palette_view.query
      ~attrs:(Role.attrs appearance Surface)
      ~prompt_attrs:(Role.attrs appearance Focus)
      ~width:20
      "search"
  in
  assert (String.is_substring (plain_text query) ~substring:"> search▏");
  assert (String.is_substring (ansi query) ~substring:"search")
;;

let%test_unit "palette scroll keeps selected result visible at normal and tiny sizes" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "palette-scrolling") in
  let host = H.receive H.empty registry in
  let commands =
    List.init 40 ~f:(fun i ->
      H.command (Int.to_string i) (sprintf "Similar command %02d" i) "" Toggle_chrome)
  in
  let host =
    List.fold [ ' '; 'c'; 'c' ] ~init:host ~f:(fun host c ->
      fst (H.input host (Character c) ~commands))
  in
  let host =
    List.fold (List.init 39 ~f:Fn.id) ~init:host ~f:(fun host _ ->
      fst (H.input host Focus ~commands))
  in
  List.iter
    [ 80, 24; 120, 40; 40, 4 ]
    ~f:(fun (width, height) ->
      let dimensions = { Dimensions.width; height } in
      let background = lines ~width ~height [ "WORKSPACE BACKGROUND" ] in
      let frame = render_palette host dimensions background in
      let text = plain_text frame in
      assert (View.width frame = width && View.height frame = height);
      assert (String.is_substring text ~substring:"Similar command 39");
      assert (not (String.is_substring text ~substring:"Similar command 00")));
  List.iter
    [ 1, 1; 3, 2; 12, 3 ]
    ~f:(fun (width, height) ->
      let frame =
        render_palette
          host
          { Dimensions.width; height }
          (View.rectangle ~width ~height ())
      in
      assert (View.width frame = width && View.height frame = height))
;;

let%test_unit "palette hit tests use visible row IDs and exact rendered form buttons" =
  let base = H.receive H.empty (W.initial ~session_id:(W.Session_id.of_string "palette-hit")) in
  let base = { base with appearance = { base.appearance with icons = Ascii } } in
  let capture = Option.value_exn (H.capture base) in
  let commands =
    List.init 40 ~f:(fun i ->
      H.command ?unavailable:(Option.some_if (i = 38) "disabled")
        (sprintf "id%d" i) (sprintf "Choice %02d" i) "" Toggle_chrome)
  in
  let palette : H.palette = { capture; commands; query = ""; index = 39; argument = None } in
  let scroll ?(x = 59) ?(y = 20) p direction =
    palette_scroll { base with palette = Some p } { Dimensions.width = 120; height = 40 }
      ~x ~y ~direction
  in
  assert (Poly.equal (scroll palette `Up) (Some H.Previous));
  assert (Option.is_none (scroll palette `Down));
  assert (Option.is_none (scroll ~x:0 palette `Up));
  let check ~width ~height p label target =
    let host = { base with palette = Some p } in
    let dimensions = { Dimensions.width; height } in
    let frame = render_palette host dimensions (View.rectangle ~width ~height ()) in
    let x, y =
      List.find_map (List.init height ~f:Fn.id) ~f:(fun y ->
        let line = View.crop ~t:y ~b:(height - y - 1) frame |> plain_text in
        Option.map (String.substr_index line ~pattern:label) ~f:(fun x ->
          cell_width (String.prefix line x), y))
      |> Option.value_exn
    in
    let hit x = palette_hit host dimensions ~x ~y in
    assert (Poly.equal (hit x) target);
    assert (Poly.equal (hit (x + String.length label - 1)) target);
    if String.is_prefix label ~prefix:"[" then assert (Option.is_none (hit (x - 1)));
    assert (Option.is_none (palette_hit host dimensions ~x:(-1) ~y))
  in
  check ~width:120 ~height:40 palette "Choice 38" None;
  check ~width:120 ~height:40 palette "Choice 39" (Some (`Command "id39"));
  let form argument = { palette with argument = Some argument; query = "demo" } in
  let name = form (Starter_name Empty_ip) in
  assert (Option.is_none (scroll name `Up));
  List.iter [ 17, 9; 100, 32 ] ~f:(fun (width, height) ->
    check ~width ~height name "[Preview]" (Some (`Input Enter));
    check ~width ~height name "[Cancel]" (Some (`Input Escape)));
  let preview : Authoring.Preview.t =
    { preview_id = "captured"
    ; operation =
        { recipe = Authoring.chip_recipe; name = "demo"
        ; target = { destination = "/project"; project = None; object_id = None } }
    ; new_files = []; files = []; provider = "fixture"; version = "1"; registration = None
    }
  in
  let chip = form (Starter_preview (preview, Chip (Example, true))) in
  let long_preview = { preview with new_files = List.init 60 ~f:Int.to_string } in
  let at_top argument = { (form argument) with index = 0 } in
  List.iter [ H.Starter_preview (long_preview, Empty_ip); Starter_result (long_preview.new_files, None) ]
    ~f:(fun argument ->
      let page = at_top argument in
      assert (Poly.equal (scroll page `Down) (Some H.Next));
      assert (Option.is_none (scroll page `Up));
      assert (Option.is_none (scroll ~y:0 page `Down)));
  check ~width:100 ~height:32 chip "[Toggle registration]" (Some (`Input (Character 'r')));
  let ip = form (Starter_preview (preview, Empty_ip)) in
  check ~width:17 ~height:9 ip "[Apply]" (Some (`Input (Character 'a')));
  check ~width:17 ~height:9 ip "[Cancel]" (Some (`Input Escape));
  assert (not (List.Assoc.mem (palette_controls base ip) "Toggle registration" ~equal:String.equal));
  let result = form (Starter_result ([ "Created" ], Some "demo")) in
  check ~width:100 ~height:32 result "[Done]" (Some (`Input Enter));
  check ~width:100 ~height:32 result "[Select target]" (Some (`Input (Character 's')));
  assert (not (List.Assoc.mem (palette_controls base (form (Starter_result ([], None))))
                 "Select target" ~equal:String.equal))
;;

let%test_unit "form overlay keeps query tail visible without changing captured form state"
  =
  let registry = W.initial ~session_id:(W.Session_id.of_string "form-overlay-tail") in
  let host = H.receive H.empty registry in
  let query = String.make 290 'x' ^ "QUERY-TAIL" in
  let palette : H.palette =
    { capture = Option.value_exn (H.capture host)
    ; commands = []
    ; query
    ; index = 0
    ; argument = Some (Acceptance (Asic_snapshot_fixture.run_a, "/exact/execution", "captured-key"))
    }
  in
  let host = { host with palette = Some palette } in
  List.iter
    [ 40, 4; 80, 24 ]
    ~f:(fun (width, height) ->
      let frame =
        render_palette
          host
          { Dimensions.width; height }
          (View.rectangle ~width ~height ())
      in
      if not (String.is_substring (plain_text frame) ~substring:"QUERY-TAIL")
      then failwithf "form %dx%d: %s" width height (plain_text frame) ();
      assert (phys_equal (Option.value_exn host.palette) palette));
  let returned, effect = H.input host Escape ~commands:[] in
  assert (Option.is_none returned.palette);
  match effect with
  | No_effect -> ()
  | _ -> assert false
;;

let%test_unit "density changes rendered padding while explicit overrides retain geometry" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "density-rendering") in
  let original = List.hd_exn registry.tiles in
  let tile = { original with kind = "project" } in
  let registry = { registry with tiles = tile :: List.tl_exn registry.tiles } in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> assert false)
    ; run_lines = (fun _ _ -> assert false)
    ; run_context = (fun _ -> assert false)
    ; summary = (fun _ -> assert false)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let host = H.receive H.empty registry in
  let host =
    H.set_local
      { host with focus = None }
      tile.id
      { H.default_local with presentation = { T.inherit_ with header = Some false } }
  in
  let host = { host with appearance = { host.appearance with preset = Minimal } } in
  let density host density = H.set_appearance host { host.H.appearance with density } in
  let geometry host = body_geometry host tile ~width:40 ~height:12 in
  let image host = tile_view host data tile ~width:40 ~height:12 in
  let compact = density host Compact
  and comfortable = density host Comfortable in
  let equal_geometry = [%equal: int * int * int * int * int] in
  assert (equal_geometry (geometry compact) (40, 12, 0, 40, 12));
  assert (equal_geometry (geometry comfortable) (40, 12, 1, 38, 12));
  assert (String.is_prefix (plain_text (image compact)) ~prefix:"No project open");
  let comfortable_body = image comfortable |> View.crop ~l:1 in
  assert (String.is_prefix (plain_text comfortable_body) ~prefix:"No project open");
  assert (not (String.equal (plain_text (image compact)) (plain_text (image comfortable))));
  List.iter [ 0; 2 ] ~f:(fun padding ->
    let explicit =
      H.set_local
        host
        tile.id
        { (H.local host tile.id) with
          presentation = { T.inherit_ with header = Some false; padding = Some padding }
        }
    in
    let a = density explicit Compact
    and b = density explicit Comfortable in
    assert ((H.policy a tile).padding = padding && (H.policy b tile).padding = padding);
    assert (equal_geometry (geometry a) (geometry b));
    assert (String.equal (plain_text (image a)) (plain_text (image b))));
  let app = { host with presentation = { T.inherit_ with padding = Some 0 } } in
  assert ((H.policy (density app Comfortable) tile).padding = 0);
  let workspace =
    { app with
      workspace_presentation =
        [ W.Workspace_id.to_string tile.workspace, { T.inherit_ with padding = Some 2 } ]
    }
  in
  assert ((H.policy (density workspace Compact) tile).padding = 2);
  let navigation = { tile with kind = "workspace-tabs" } in
  assert (
    (H.policy compact navigation).padding = 0
    && (H.policy comfortable navigation).padding = 0);
  assert (
    let _, _, padding, _, _ = body_geometry comfortable tile ~width:3 ~height:2 in
    padding = 0);
  List.iter [ compact; comfortable; app; workspace ] ~f:(fun host ->
    assert (phys_equal (Option.value_exn host.H.registry) registry);
    assert (W.Tile.equal (W.tile (Option.value_exn host.registry) tile.id) tile))
;;

let%test_unit "actual preset host resolves quiet chrome, headerless pins and selector cap"
  =
  let initial = W.initial ~session_id:(W.Session_id.of_string "composed-host") in
  let workspace = List.hd_exn initial.workspaces in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry =
    apply initial (P.Definition.apply P.Overview.definition ~workspace:workspace.id)
  in
  let context = W.context registry workspace.context in
  let registry =
    apply
      registry
      (Select_run
         { workspace = workspace.id
         ; context = context.id
         ; expected_selection_revision = context.selection_revision
         ; run = Some Asic_snapshot_fixture.run_a
         })
  in
  let find kind =
    List.find_exn registry.tiles ~f:(fun t ->
      W.Workspace_id.equal t.W.Tile.workspace workspace.id && String.equal t.kind kind)
  in
  let synthesis = find "synthesis"
  and selector = find "run-selector"
  and navigation = find "workspace-tabs" in
  let data =
    { project = None
    ; jobs = []
    ; runs =
        List.init 12 ~f:(fun i ->
          { Asic_snapshot_fixture.run_a with id = sprintf "run-%02d" i }, sprintf "candidate-%02d" i)
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary =
        (fun run ->
          List.find Asic_snapshot_fixture.snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run))
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = Some Asic_snapshot_fixture.snapshot
    }
  in
  let host = H.receive H.empty registry in
  let image host tile = tile_view host data tile ~width:100 ~height:16 |> plain_text in
  let normal = image host synthesis in
  assert (not (String.is_substring normal ~substring:"follow"));
  assert (
    not (String.is_substring normal ~substring:("Run: " ^ run_label Asic_snapshot_fixture.run_a)));
  assert (String.is_substring normal ~substring:"Evidence: cached/unverified");
  let pin_registry =
    apply
      registry
      (Set_tile_binding { tile = synthesis.id; binding = Pin_run Asic_snapshot_fixture.run_a })
  in
  let pinned = W.tile pin_registry synthesis.id in
  let pin_host = H.receive host pin_registry in
  let pin_host =
    H.set_local
      pin_host
      pinned.id
      { H.default_local with
        presentation = { T.inherit_ with header = Some false; freshness = Some false }
      }
  in
  let pinned_text = image pin_host pinned in
  assert (String.is_substring pinned_text ~substring:("PIN " ^ run_label Asic_snapshot_fixture.run_a));
  let titled_pin =
    H.set_local
      pin_host
      pinned.id
      { H.default_local with presentation = { T.inherit_ with header = Some true } }
  in
  let narrow_pin = tile_view titled_pin data pinned ~width:32 ~height:6 |> plain_text in
  assert (String.is_substring narrow_pin ~substring:("PIN " ^ run_label Asic_snapshot_fixture.run_a));
  assert (String.is_substring pinned_text ~substring:"Evidence: cached/unverified");
  assert (String.is_substring pinned_text ~substring:"Reported cells (agg.): 50");
  let hidden =
    H.set_local
      pin_host
      pinned.id
      { (H.local pin_host pinned.id) with
        presentation = { T.inherit_ with header = Some false; badge = Some Hidden }
      }
  in
  assert (not (String.is_substring (image hidden pinned) ~substring:"PIN "));
  assert (W.Snapshot.equal (Option.value_exn hidden.registry) pin_registry);
  let nav_policy = H.policy host navigation in
  assert (
    (not (T.show_title nav_policy))
    && (not nav_policy.hints)
    && (not nav_policy.frame)
    && nav_policy.padding = 0);
  let nav = image host navigation in
  assert (
    (not (String.is_substring nav ~substring:"project"))
    && not (String.is_substring nav ~substring:"j/k browse"));
  let selector_host =
    H.set_local host selector.id { H.default_local with cursor = Some "asic/run-11" }
  in
  let candidates = rows selector_host data selector ~width:100 ~height:12 in
  assert (List.length candidates = 4);
  assert (
    List.exists candidates ~f:(fun row ->
      String.is_substring row ~substring:"candidate-11"));
  let global_rows =
    { selector_host with presentation = { T.inherit_ with run_selector_rows = Some 7 } }
  in
  assert (List.length (rows global_rows data selector ~width:100 ~height:12) = 7);
  let more =
    H.set_local
      selector_host
      selector.id
      { (H.local selector_host selector.id) with
        presentation = { T.inherit_ with run_selector_rows = Some 6 }
      }
  in
  assert (List.length (rows more data selector ~width:100 ~height:12) = 6);
  let dimensions = { Dimensions.width = 120; height = 40 } in
  let _, compact, layout = tile_layout host dimensions in
  assert (not compact);
  let cell tile =
    List.find_exn layout ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.W.Tile.id) |> snd
  in
  let select_cell = cell selector
  and synthesis_cell = cell synthesis in
  assert (
    select_cell.width = (cell (find "live-status")).width
    && select_cell.x < synthesis_cell.x
    && select_cell.y >= synthesis_cell.y);
  let renamed =
    { registry with
      workspaces =
        List.map registry.workspaces ~f:(fun w ->
          if W.Workspace_id.equal w.id workspace.id
          then { w with name = "Custom title" }
          else w)
    }
  in
  let _, _, renamed_layout = tile_layout (H.receive host renamed) dimensions in
  assert (
    List.equal
      (fun (a, g) (b, h) ->
        W.Tile_id.equal a.W.Tile.id b.W.Tile.id && W.Geometry.equal g h)
      layout
      renamed_layout)
;;

let%test_unit "host semantic terminal rows preserve failure and raw evidence when chrome \
               hidden"
  =
  let initial = W.initial ~session_id:(W.Session_id.of_string "semantic-host") in
  let workspace = List.hd_exn initial.workspaces in
  let registry =
    W.apply
      initial
      (Mutate
         { expected_revision = initial.revision
         ; mutation = P.Definition.apply P.Overview.definition ~workspace:workspace.id
         })
    |> Result.ok
    |> Option.value_exn
  in
  let timing =
    List.find_exn registry.tiles ~f:(fun t -> String.equal t.W.Tile.kind "timing")
  in
  let timing = { timing with binding = Pin_run Asic_snapshot_fixture.run_a } in
  let registry =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun t ->
          if W.Tile_id.equal t.id timing.id then timing else t)
    }
  in
  let terminal : Asic.Terminal_result.t =
    { attempt = "exact"
    ; results_file = "/results"
    ; results_digest = "digest"
    ; operation_status = "completed"
    ; physical_completion = "partial"
    ; acceptance = "fail"
    ; timing_goal = "unknown"
    ; metrics = []
    ; checks =
        [ { name = "drc"
          ; status = "fail"
          ; reason = Some "validated passed is provider prose"
          ; source = None
          }
        ]
    ; evidence =
        "Freshness: provider source\nRun: original raw identity\nfailed pending validated"
    ; execution_timing = None
    }
  in
  let summary =
    { (List.hd_exn Asic_snapshot_fixture.snapshot.summaries) with
      run = Asic_snapshot_fixture.run_a
    ; freshness = Validated
    ; terminal = Some terminal
    ; timing_analysis = None
    }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> Some summary)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let host = H.receive H.empty registry in
  let local =
    { H.default_local with
      terminal_result =
        Terminal_result_view.State.inspect
          (Terminal_result_view.State.reconcile
             Terminal_result_view.State.empty
             ~run:Asic_snapshot_fixture.run_a
             ~summary:(Some summary))
    }
  in
  let host = H.set_local host timing.id local in
  let typed = semantic_rows host data timing ~width:120 ~height:200 |> Option.value_exn in
  assert (
    List.exists typed ~f:(List.exists ~f:(fun span -> E.Role.equal span.E.role Validated)));
  assert (
    List.exists typed ~f:(List.exists ~f:(fun span -> E.Role.equal span.E.role Failed)));
  let hidden =
    H.set_local
      host
      timing.id
      { local with
        presentation =
          { T.inherit_ with
            freshness = Some false
          ; run_reference = Some false
          ; hints = Some false
          }
      }
  in
  let hidden_rows =
    semantic_rows hidden data timing ~width:120 ~height:200 |> Option.value_exn
  in
  let text = String.concat ~sep:"\n" (List.map hidden_rows ~f:E.text) in
  assert (String.is_substring text ~substring:"Freshness: provider source");
  assert (String.is_substring text ~substring:"Run: original raw identity");
  assert (
    not
      (List.exists
         hidden_rows
         ~f:(List.exists ~f:(fun span -> E.Role.equal span.E.role Validated))));
  assert (
    List.exists
      hidden_rows
      ~f:
        (List.exists ~f:(fun span ->
           E.Role.equal span.E.role Plain
           && String.is_substring
                span.text
                ~substring:"validated passed is provider prose")));
  assert (W.Snapshot.equal registry (Option.value_exn hidden.registry));
  let hidden = { hidden with focus = Some timing.id } in
  List.iter
    [ 32, 8; 80, 24 ]
    ~f:(fun (width, height) ->
      let dimensions = { Dimensions.width; height } in
      let bottom = scroll_focused hidden data dimensions ~delta:Int.max_value in
      let stopped = scroll_focused bottom data dimensions ~delta:1 in
      assert (
        (H.local stopped timing.id).terminal_result.offset
        = (H.local bottom timing.id).terminal_result.offset);
      let reverse = scroll_focused stopped data dimensions ~delta:(-1) in
      if (H.local bottom timing.id).terminal_result.offset > 0
      then
        assert (
          not
            (String.equal
               (render bottom data dimensions |> plain_text)
               (render reverse data dimensions |> plain_text))))
;;

let%test_unit "utility navigation filters match input and inspection scroll is bounded" =
  let registry = W.initial ~session_id:(W.Session_id.of_string "utility-rendering") in
  let workspace = List.hd_exn registry.workspaces in
  let registry =
    W.apply
      registry
      (Mutate
         { expected_revision = registry.revision
         ; mutation =
             Create_tile
               { workspace = workspace.id
               ; kind = "workspace-tabs"
               ; geometry = { x = 0; y = 0; width = 32; height = 8 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile = List.last_exn registry.tiles in
  let host = H.receive H.empty registry in
  let host =
    H.set_local
      { host with focus = Some tile.id }
      tile.id
      { H.default_local with filter = "Timing" }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; status = "connected"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let rows = utility_rows host data tile |> Option.value_exn in
  assert (
    List.equal
      String.equal
      (List.map rows ~f:(fun row -> row.Overview_tiles.label))
      [ "Timing" ]);
  let host = H.browse_workspaces host tile.id ~delta:1 in
  assert (String.equal (Option.value_exn (H.workspace_cursor host tile.id)).name "Timing");
  let registry =
    { registry with
      tiles =
        List.map registry.tiles ~f:(fun t ->
          if W.Tile_id.equal t.id tile.id then { t with kind = "live-status" } else t)
    }
  in
  let host = H.receive host registry in
  let host = H.set_local host tile.id { H.default_local with utility_detail = true } in
  let dimensions = { Dimensions.width = 32; height = 8 } in
  let bottom = scroll_focused host data dimensions ~delta:Int.max_value in
  assert ((H.local bottom tile.id).scroll > 0);
  let stopped = scroll_focused bottom data dimensions ~delta:1 in
  assert ((H.local stopped tile.id).scroll = (H.local bottom tile.id).scroll);
  let reverse = scroll_focused stopped data dimensions ~delta:(-1) in
  assert ((H.local reverse tile.id).scroll = (H.local stopped tile.id).scroll - 1)
;;

let%test_unit "checklist follows exact run and pin with selected-stage detail and \
               aggregate checks"
  =
  let initial = W.initial ~session_id:(W.Session_id.of_string "stage-frames") in
  let workspace = (List.hd_exn initial.workspaces).id in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let registry =
    apply
      initial
      (Create_tile
         { workspace
         ; kind = "stage-checklist"
         ; geometry = { x = 0; y = 0; width = 64; height = 20 }
         })
  in
  let following = List.last_exn registry.tiles in
  let registry =
    apply
      registry
      (Create_tile
         { workspace
         ; kind = "stage-checklist"
         ; geometry = { x = 0; y = 0; width = 64; height = 20 }
         })
  in
  let pinned = List.last_exn registry.tiles in
  let registry =
    apply
      registry
      (Set_tile_binding { tile = pinned.id; binding = Pin_run Asic_snapshot_fixture.run_a })
  in
  let stage id status reason : Asic.Stage.t =
    { id
    ; name = id
    ; status
    ; requested = true
    ; reason
    ; action = None
    ; execution_timing = None
    }
  in
  let terminal : Asic.Terminal_result.t =
    { attempt = "attempt"
    ; results_file = "results"
    ; results_digest = "digest"
    ; operation_status = "completed"
    ; physical_completion = "partial"
    ; acceptance = "unknown"
    ; timing_goal = "unknown"
    ; metrics = []
    ; checks =
        [ { name = "drc"
          ; status = "fail"
          ; reason = Some "aggregate reason"
          ; source = Some "report"
          }
        ]
    ; evidence = "{}"
    ; execution_timing = None
    }
  in
  let snapshot =
    { Asic_snapshot_fixture.snapshot with
      summaries =
        List.map Asic_snapshot_fixture.snapshot.summaries ~f:(fun s ->
          { s with terminal = Some terminal })
    ; preview =
        Some
          { selection =
              { chip_target = None
              ; flow = "ordinary"
              ; profile = "default"
              ; endpoint = "placement"
              ; assignments = []
              }
          ; plan_identity = "ready-plan"
          ; plan_json = "{}"
          }
    ; runs =
        [ { (Asic_snapshot_fixture.run Asic_snapshot_fixture.run_a) with
            stages =
              [ stage "placement" Completed None
              ; stage "routing" Failed (Some "route reason")
              ]
          }
        ; { (Asic_snapshot_fixture.run Asic_snapshot_fixture.run_b) with
            stages = [ stage "placement" Running None ]
          }
        ]
    }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = run_lines (Some snapshot)
    ; run_context = request_context (Some snapshot)
    ; summary =
        (fun run -> List.find snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run))
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = Some snapshot
    }
  in
  let select host run =
    let mutation = H.select_run host (Some run) |> Option.value_exn in
    H.receive host (apply (Option.value_exn host.H.registry) mutation)
  in
  let host = select (H.receive H.empty registry) Asic_snapshot_fixture.run_a in
  let stages = Overview_tiles.observed_stages ~asic:data.asic ~run:Asic_snapshot_fixture.run_a in
  let host = H.browse_stages host following.id ~run:Asic_snapshot_fixture.run_a ~stages ~delta:1 in
  let host =
    H.set_local
      host
      following.id
      { (H.local host following.id) with utility_detail = true }
  in
  let detail =
    utility_rows host data following
    |> Option.value_exn
    |> Overview_tiles.inspection_lines
    |> String.concat ~sep:"\n"
  in
  List.iter
    [ "routing: failed"
    ; "Stage ID: routing"
    ; "route reason"
    ; "Action: unavailable"
    ; "Accept (agg.)"
    ; "Check drc (aggregate): fail"
    ; "aggregate reason"
    ; "Source: report"
    ]
    ~f:(fun text -> assert (String.is_substring detail ~substring:text));
  assert (not (String.is_substring detail ~substring:"Matching project preview"));
  assert (not (String.is_substring detail ~substring:"placement: completed"));
  let host = select host Asic_snapshot_fixture.run_b in
  let projected tile =
    utility_rows host data tile
    |> Option.value_exn
    |> List.filter_map ~f:(fun row ->
      Option.map row.Overview_tiles.status ~f:(fun _ -> row.value))
  in
  assert (List.equal String.equal (projected following) [ "unavailable" ]);
  assert (
    List.equal
      String.equal
      (projected pinned)
      [ "unavailable"; "completed"; "failed"; "not reported" ]);
  let compact_host =
    H.set_local
      host
      following.id
      { H.default_local with
        presentation = { T.inherit_ with header = Some false; hints = Some true }
      }
  in
  let compact =
    tile_view compact_host data following ~width:40 ~height:10 |> plain_text
  in
  List.iter [ "running"; "unknown" ] ~f:(fun text ->
    assert (String.is_substring compact ~substring:text));
  let missing = { data with asic = None } in
  let fallback = utility_rows host missing following |> Option.value_exn in
  assert (
    List.for_all fallback ~f:(fun row ->
      Option.value_map row.Overview_tiles.status ~default:true ~f:(fun status ->
        Overview_tiles.Status.equal status Unknown
        || (String.equal row.label "Elaboration"
            && Overview_tiles.Status.equal status Unsupported))));
  (* Six stages plus run identity, summaries and hints exceed an ordinary Overview
     viewport. Selection must survive both browsing and a stale manual scroll. *)
  let selection = (Option.value_exn snapshot.preview).selection in
  let stages =
    List.init 6 ~f:(fun i ->
      { (stage (sprintf "stage-%d" i) Pending None) with action = Some selection })
  in
  let snapshot =
    { snapshot with
      runs =
        List.map snapshot.runs ~f:(fun run ->
          if Run_ref.equal run.run Asic_snapshot_fixture.run_b then { run with stages } else run)
    }
  in
  let data = { data with asic = Some snapshot } in
  let host =
    H.browse_stages compact_host following.id ~run:Asic_snapshot_fixture.run_b ~stages ~delta:5
  in
  let key = List.hd_exn (Plain_rpc.keys (Plan selection) snapshot) in
  let snapshot =
    { snapshot with
      operations =
        [ { key
          ; kind = "plan"
          ; state = "completed"
          ; run = None
          ; error = None
          ; activity = Unreported
          }
        ]
    }
  in
  let host =
    { host with planned_run = Planned_run.receive host.planned_run ~revision:1 snapshot }
  in
  assert (Option.is_some (checklist_preview host data following));
  List.iter [ 8; 9; 10; 12; 14 ] ~f:(fun height ->
    List.iter [ 0; 99 ] ~f:(fun scroll ->
      let host =
        H.set_local
          host
          following.id
          { (H.local host following.id) with presentation = T.inherit_; scroll }
      in
      let text = tile_view host data following ~width:60 ~height |> plain_text in
      assert (
        String.split_lines text
        |> List.exists ~f:(fun line ->
          String.is_substring line ~substring:"stage-5:"
          && String.is_substring line ~substring:"pending"))));
  let top =
    H.browse_stages host following.id ~run:Asic_snapshot_fixture.run_b ~stages ~delta:(-5)
  in
  let top =
    H.set_local top following.id { (H.local top following.id) with scroll = 99 }
  in
  assert (
    tile_view top data following ~width:60 ~height:10
    |> plain_text
    |> String.split_lines
    |> List.exists ~f:(fun line ->
      String.is_substring line ~substring:"stage-0:"
      && String.is_substring line ~substring:"pending"));
  let ready = tile_view host data following ~width:40 ~height:14 |> plain_text in
  assert (String.is_substring ready ~substring:"Space c c: Launch");
  assert (String.is_substring ready ~substring:"or Launch and view");
  assert (Option.is_none (checklist_preview host data pinned));
  List.iter
    [ { selection with endpoint = "unrelated" }
    ; { selection with flow = "other-flow" }
    ; { selection with profile = "other-profile" }
    ; { selection with assignments = [ "different=value" ] }
    ]
    ~f:(fun selection ->
      let unrelated =
        { data with
          asic =
            Some
              { snapshot with
                preview =
                  Option.map snapshot.preview ~f:(fun preview ->
                    { preview with selection })
              }
        }
      in
      assert (Option.is_none (checklist_preview host unrelated following));
      let text = tile_view host unrelated following ~width:40 ~height:14 |> plain_text in
      assert (not (String.is_substring text ~substring:"Space c c: Launch")))
;;

let%test_unit "simulation tile renders project scope and independent selection at real \
               cell bounds"
  =
  let s = W.initial ~session_id:(W.Session_id.of_string "simulation-render") in
  let s =
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation =
             Create_tile
               { workspace = (List.hd_exn s.workspaces).id
               ; kind = "simulation"
               ; geometry = { x = 0; y = 0; width = 80; height = 20 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let tile = List.last_exn s.tiles in
  let host = H.receive H.empty s in
  let host =
    H.set_local
      host
      tile.id
      { H.default_local with
        simulation =
          { Simulation_view.empty with
            notice = Some "Verified simulation bytes retained: /host/trace.vcd"
          }
      }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; asic = None
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    }
  in
  List.iter
    [ 80, 24; 120, 40; 32, 8; 1, 1 ]
    ~f:(fun (width, height) ->
      let view = tile_view host data tile ~width ~height in
      assert (View.width view = width && View.height view = height));
  let text = tile_view host data tile ~width:120 ~height:24 |> plain_text in
  assert (String.is_substring text ~substring:"Structured simulation");
  assert (not (String.is_substring text ~substring:"[project]"));
  let explicit =
    H.set_local
      host
      tile.id
      { (H.local host tile.id) with
        presentation = { T.inherit_ with badge = Some Always }
      }
  in
  assert (
    String.is_substring
      (tile_view explicit data tile ~width:120 ~height:24 |> plain_text)
      ~substring:"[project]");
  assert (String.is_substring text ~substring:"/host/trace.vcd");
  assert (not (String.is_substring text ~substring:"No run selected"));
  let local = H.local host tile.id in
  let host =
    H.set_local
      { host with focus = Some tile.id }
      tile.id
      { local with
        simulation =
          { local.simulation with notice = Some (String.make 512 'x' ^ "HORIZONTAL-END") }
      }
  in
  let dimensions : Dimensions.t = { width = 32; height = 8 } in
  let bottom = scroll_focused host data dimensions ~delta:Int.max_value in
  assert ((H.local bottom tile.id).scroll > 0);
  assert (
    String.is_substring
      (render bottom data dimensions |> plain_text)
      ~substring:"HORIZONTAL-END");
  let stopped = scroll_focused bottom data dimensions ~delta:1 in
  assert ((H.local stopped tile.id).scroll = (H.local bottom tile.id).scroll);
  let back = scroll_focused stopped data dimensions ~delta:(-1) in
  assert ((H.local back tile.id).scroll = (H.local stopped tile.id).scroll - 1);
  let top = scroll_focused bottom data dimensions ~delta:Int.min_value in
  assert ((H.local top tile.id).scroll = 0)
;;

let%test_unit "fit geometry fills tracks, keeps thirteen tiles visible, and falls back" =
  let grid ~width ~height ~count =
    match Fit_layout.compute ~width ~height ~count with
    | Compact -> assert false
    | Grid cells ->
      assert (List.length cells = count);
      List.iteri cells ~f:(fun i (a : W.Geometry.t) ->
        assert (a.x >= 0 && a.y >= 0 && a.width >= 24 && a.height >= 6);
        assert (a.x + a.width <= width && a.y + a.height <= height);
        List.iter
          (List.drop cells (i + 1))
          ~f:(fun (b : W.Geometry.t) ->
            assert (
              a.x + a.width < b.x
              || b.x + b.width < a.x
              || a.y + a.height < b.y
              || b.y + b.height < a.y)));
      assert (List.exists cells ~f:(fun g -> g.x + g.width = width));
      assert (List.exists cells ~f:(fun g -> g.y + g.height = height));
      cells
  in
  let two = grid ~width:120 ~height:40 ~count:2 in
  assert (
    Poly.equal
      (Some (List.mapi two ~f:(fun i g -> i, g)))
      (P.Layout.grid ~gutter:1 ~width:120 ~height:40 2));
  ignore (grid ~width:120 ~height:40 ~count:13 : W.Geometry.t list);
  List.iter
    [ 24, 6; 32, 6; 1, 1; 120, 5 ]
    ~f:(fun (width, height) ->
      match Fit_layout.compute ~width ~height ~count:2 with
      | Compact -> ()
      | Grid _ -> assert false)
;;

let%test_unit "stage evidence is scoped honestly and never borrows synthesis counts" =
  let known =
    { Asic_snapshot_fixture.snapshot with
      runs =
        List.map Asic_snapshot_fixture.snapshot.runs ~f:(fun execution ->
          { execution with
            selection =
              Some
                { chip_target = None
                ; Asic.Selection.flow = "fixture"
                ; profile = "fixture"
                ; endpoint = "synthesis"
                ; assignments = []
                }
          })
    }
  in
  let text snapshot kind =
    run_lines (Some snapshot) Asic_snapshot_fixture.run_a kind |> String.concat ~sep:"\n"
  in
  List.iter [ "placement"; "cts"; "routing" ] ~f:(fun kind ->
    let requested = text known kind in
    assert (
      String.is_substring
        requested
        ~substring:"No terminal result imported; inspect exact finalization reference");
    assert (String.is_substring requested ~substring:"Request endpoint: synthesis");
    let unknown = text Asic_snapshot_fixture.snapshot kind in
    assert (String.is_substring unknown ~substring:"Request scope: unknown");
    assert (String.is_substring unknown ~substring:"No terminal result imported"));
  let physical =
    { known with
      runs =
        List.map known.runs ~f:(fun execution ->
          { execution with
            selection =
              Option.map execution.selection ~f:(fun selection ->
                { selection with endpoint = "physical" })
          })
    }
  in
  List.iter [ "placement"; "cts"; "routing"; "finalization"; "timing" ] ~f:(fun kind ->
    let output = text physical kind in
    assert (String.is_substring output ~substring:"Request endpoint: physical");
    assert (String.is_substring output ~substring:"No terminal result imported");
    assert (not (String.is_substring output ~substring:"not requested")));
  List.iter
    [ "placement"; "cts"; "routing"; "checks"; "finalization"; "timing"; "unknown" ]
    ~f:(fun kind ->
      let output = text known kind in
      assert (not (String.is_substring output ~substring:"Cell count"));
      assert (not (String.is_substring output ~substring:"NAND2"));
      assert (not (String.is_substring output ~substring:"PASS"));
      assert (String.is_substring output ~substring:"acceptance: not evaluated"));
  assert (
    String.is_substring
      (text known "checks")
      ~substring:"Synthesis diagnostics unavailable; explicit Refresh needed");
  let with_metrics =
    { known with
      summaries =
        List.map known.summaries ~f:(fun summary ->
          { summary with
            metrics =
              [ { Asic.Metric.key = "synthesis__check_error__count"
                ; label = "Synthesis check errors"
                ; value = Some 0.
                ; unit_ = Some "count"
                ; availability = "available"
                ; source = Some "/private/checkpoint/check.json#errors"
                }
              ]
          })
    }
  in
  let checks = text with_metrics "checks" in
  assert (
    String.is_substring checks ~substring:"Synthesis check errors: 0 count [available]");
  assert (String.is_substring checks ~substring:"not DRC/LVS");
  assert (
    String.is_substring checks ~substring:"Zero diagnostic counts do not imply signoff");
  assert (String.is_substring checks ~substring:"Acceptance (reported): not evaluated");
  assert (not (String.is_substring checks ~substring:"/private/checkpoint"));
  List.iter [ "placement"; "cts"; "routing"; "finalization" ] ~f:(fun kind ->
    assert (
      not
        (String.is_substring (text with_metrics kind) ~substring:"Synthesis check errors")));
  assert (
    String.is_substring
      (text known "finalization")
      ~substring:"No terminal result imported");
  assert (
    String.is_substring (text known "timing") ~substring:"No terminal result imported");
  assert (String.is_substring (text known "synthesis") ~substring:"Cell count: 50")
;;

let%test_unit "imported clock configuration retains explicit known or unknown request \
               scope"
  =
  let clock : Asic.Metric.t =
    { key = "declared_clock_period"
    ; label = "Declared clock clk_i period"
    ; value = Some 10.
    ; unit_ = Some "ns"
    ; availability = "available"
    ; source = Some "/private/recorded/config.json#clock"
    }
  in
  let terminal : Asic.Terminal_result.t =
    { attempt = "/private/returned-operation"
    ; results_file = "/private/results.json"
    ; results_digest = "exact-results-digest"
    ; operation_status = "completed"
    ; physical_completion = "unknown"
    ; acceptance = "unknown"
    ; timing_goal = "unknown"
    ; metrics = [ clock ]
    ; checks = []
    ; evidence = "original terminal evidence"
    ; execution_timing = None
    }
  in
  let snapshot =
    { Asic_snapshot_fixture.snapshot with
      summaries =
        List.map Asic_snapshot_fixture.snapshot.summaries ~f:(fun summary ->
          { summary with terminal = Some terminal })
    }
  in
  let output = run_lines (Some snapshot) Asic_snapshot_fixture.run_a "cts" in
  assert (
    List.mem output "Declared clock clk_i period: 10 ns [available]" ~equal:String.equal);
  assert (
    List.mem output "Request scope: unknown (selection unavailable)" ~equal:String.equal);
  let snapshot =
    { snapshot with
      runs =
        List.map snapshot.runs ~f:(fun execution ->
          { execution with
            selection =
              Some
                { chip_target = None
                ; Asic.Selection.flow = "fixture"
                ; profile = "fixture"
                ; endpoint = "physical"
                ; assignments = []
                }
          })
    }
  in
  assert (
    List.mem
      (run_lines (Some snapshot) Asic_snapshot_fixture.run_a "cts")
      "Request endpoint: physical"
      ~equal:String.equal);
  let summary = List.hd_exn snapshot.summaries in
  let output =
    Terminal_result_view.rows
      ~request_context:(request_context (Some snapshot) summary.run)
      Terminal_result_view.State.empty
      ~run:summary.run
      ~summary:(Some summary)
      ~kind:"cts"
      ~width:100
      ~height:100
  in
  assert (List.mem output "Request endpoint: physical" ~equal:String.equal);
  assert (
    List.mem
      output
      "Recorded methodology configuration, not measured CTS"
      ~equal:String.equal)
;;

let%test_unit "fit renders all thirteen tiles across skins and distinguishes loading \
               from empty"
  =
  let initial = W.initial ~session_id:(W.Session_id.of_string "fit-frames") in
  let workspace = (List.hd_exn initial.workspaces).id in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let empty =
    List.fold initial.tiles ~init:initial ~f:(fun s tile ->
      apply s (Set_tile_hidden { tile = tile.id; hidden = true }))
  in
  let kinds = List.init 13 ~f:(fun i -> sprintf "fixture%02d" i) in
  let loaded =
    List.fold kinds ~init:empty ~f:(fun s kind ->
      apply
        s
        (Create_tile
           { workspace; kind; geometry = { x = 0; y = 0; width = 40; height = 6 } }))
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let frame host = render host data { width = 120; height = 40 } |> plain_text in
  assert (String.is_substring (frame H.empty) ~substring:"Loading workspace...");
  let empty_text = frame (H.receive H.empty empty) in
  assert (String.is_substring empty_text ~substring:"Apply default layout");
  assert (not (String.is_substring empty_text ~substring:"Loading workspace"));
  List.iter appearance_cases ~f:(fun appearance ->
    let host = { (H.receive H.empty loaded) with appearance; layout_mode = H.Fit } in
    let text = frame host |> String.lowercase in
    List.iter kinds ~f:(fun kind -> assert (String.is_substring text ~substring:kind));
    let compact = render host data { width = 32; height = 8 } |> plain_text in
    assert (String.is_substring compact ~substring:"Compact: focused tile only"))
;;

let%test_unit "actual renderer clips cell geometry and distinguishes run and project \
               scope"
  =
  let s = W.initial ~session_id:(W.Session_id.of_string "render-test") in
  let workspace = (List.hd_exn s.workspaces).id in
  let s =
    W.apply
      s
      (Mutate
         { expected_revision = s.revision
         ; mutation =
             Create_tile
               { workspace
               ; kind = "project-tests"
               ; geometry = { x = 0; y = 0; width = 64; height = 8 }
               }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let host = H.receive H.empty s in
  let test_tile = List.last_exn s.tiles in
  let host = { host with focus = Some test_tile.id } in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [ "No measurement" ])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; status = "fixture"
    ; environment = "test"
    ; asic_lines = [ "Explicit synthetic rendering fixture" ]
    ; asic = None
    }
  in
  List.iter appearance_cases ~f:(fun appearance ->
    let host = { host with appearance } in
    List.iter
      [ 80, 24; 120, 40; 32, 8; 1, 1 ]
      ~f:(fun (width, height) ->
        let view = render host data { width; height } in
        assert (View.width view = width);
        assert (View.height view = height));
    let tile = tile_view host data test_tile ~width:64 ~height:12 in
    let text = plain_text tile in
    assert (View.width tile = 64 && View.height tile = 12);
    assert (String.is_substring text ~substring:"Project tests (not ASIC-run scoped)");
    (match appearance.icons with
     | None_ | Ascii -> assert (String.for_all text ~f:(fun ch -> Char.to_int ch < 128))
     | Unicode -> ());
    let local = H.local host test_tile.id in
    let without_headers =
      H.set_local
        host
        test_tile.id
        { local with presentation = { local.presentation with header = Some false } }
    in
    let text =
      tile_view without_headers data test_tile ~width:64 ~height:12 |> plain_text
    in
    assert (String.is_substring text ~substring:"Project tests (not ASIC-run scoped)"));
  let skins =
    List.map Appearance.Preset.all ~f:(fun preset ->
      let appearance = { Appearance.default with preset; icons = Unicode } in
      tile_view { host with appearance } data test_tile ~width:64 ~height:12 |> plain_text)
  in
  assert (List.length (List.dedup_and_sort skins ~compare:String.compare) = 5);
  let view = render host data { width = 80; height = 24 } in
  let buffer = Buffer.create 2048 in
  Notty.Render.to_buffer
    buffer
    Notty.Cap.dumb
    (0, 0)
    (80, 24)
    (View.Private.notty_image view);
  assert (
    String.is_substring
      (Buffer.contents buffer)
      ~substring:"Project tests (not ASIC-run scoped)");
  let unicode = box ~width:3 ~height:1 (View.text "界界é") in
  assert (View.width unicode = 3);
  assert (View.height unicode = 1);
  let wrapped = wrap_cells ~width:3 "界界é" in
  assert (String.equal (String.concat wrapped) "界界é");
  List.iter wrapped ~f:(fun line -> assert (View.width (View.text line) <= 3))
;;

let%test_unit "artifact overlay cannot render retained page after tile binding changes" =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "artifact-scope") in
  let tile = List.hd_exn snapshot.tiles in
  let bind snapshot run =
    W.apply
      snapshot
      (Mutate
         { expected_revision = snapshot.W.Snapshot.revision
         ; mutation = Set_tile_binding { tile = tile.id; binding = Pin_run run }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let snapshot = bind snapshot Asic_snapshot_fixture.run_a in
  let reference : Asic_artifact.Reference.t =
    { id = "report"
    ; run = Asic_snapshot_fixture.run_a
    ; terminal_attempt = "attempt-a"
    ; label = "Report"
    ; path = "/daemon/report"
    ; sha256 = "hash-a"
    ; size = 24
    ; kind = "text"
    }
  in
  let page : Asic_artifact.Page.t =
    { artifact_id = reference.id
    ; run = reference.run
    ; terminal_attempt = reference.terminal_attempt
    ; sha256 = reference.sha256
    ; offset = 0
    ; limit = Artifact_view.limit
    ; next_offset = 24
    ; eof = true
    ; text = "PRIVATE-RUN-A-PAGE"
    ; error = None
    }
  in
  let inspector =
    { (Artifact_view.create ~scope:reference.run reference.run) with
      catalog = [ reference ]
    ; reading = Some { artifact = reference; offset = 0; previous = []; page = Some page }
    }
  in
  let host = H.receive H.empty snapshot in
  let host =
    H.set_local
      { host with focus = Some tile.id }
      tile.id
      { H.default_local with artifacts = Some inspector }
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let frame host = render host data { width = 100; height = 30 } |> plain_text in
  assert (String.is_substring (frame host) ~substring:page.text);
  (* Deliberately retain old local state: the renderer independently checks binding. *)
  let changed = { host with registry = Some (bind snapshot Asic_snapshot_fixture.run_b) } in
  assert (Option.is_none (artifact_inspector changed tile));
  assert (not (String.is_substring (frame changed) ~substring:page.text))
;;

let%test_unit "inspection overlay and input share full viewport and visibly reverse from \
               bottom"
  =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "inspection-viewport") in
  let tile = List.hd_exn snapshot.tiles in
  let run = Asic_snapshot_fixture.run_a in
  let bind snapshot run =
    W.apply
      snapshot
      (Mutate
         { expected_revision = snapshot.W.Snapshot.revision
         ; mutation = Set_tile_binding { tile = tile.id; binding = Pin_run run }
         })
    |> Result.ok
    |> Option.value_exn
  in
  let snapshot = bind snapshot run in
  let row : Asic_inspection.Row.t =
    { id = "row"
    ; category = "path"
    ; producer = "sta"
    ; corner = None
    ; group = None
    ; name = "path"
    ; value = Some 0.
    ; unit_ = Some "ns"
    ; status = "ok"
    ; source = "/report"
    ; fields = []
    }
  in
  let index : Asic_inspection.Index.t =
    { run
    ; execution_file = "/execution"
    ; execution_sha256 = "sha"
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; rows = [ row ]
    ; diagnostics = []
    ; truncated = false
    ; cached_unverified = false
    ; analysis = None
    ; times = Evidence_time.Index.empty
    }
  in
  let detail : Asic_inspection.Detail.t =
    { run
    ; domain = "timing"
    ; stage = "signoff"
    ; source_digest = "digest"
    ; row_id = "row"
    ; text =
        String.concat
          ~sep:"\n"
          (List.init 120 ~f:(fun i -> sprintf "detail-%03d %s" i (String.make 130 'x')))
    ; error = None
    }
  in
  let inspector =
    { (Inspection_view.create ~scope:run ~run ~domain:"timing" ~stage:"signoff" ()) with
      index = Some index
    ; selected = Some "row"
    ; requested = Some ("digest", "row")
    ; detail = Some detail
    }
  in
  let host = H.receive H.empty snapshot in
  let host = { host with focus = Some tile.id } in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> assert false)
    ; run_lines = (fun _ _ -> assert false)
    ; run_context = (fun _ -> assert false)
    ; summary = (fun _ -> assert false)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  List.iter
    [ { Dimensions.width = 120; height = 40 }; { width = 112; height = 40 } ]
    ~f:(fun dimensions ->
      let width, height = inspection_viewport dimensions in
      assert (width = dimensions.width && height = dimensions.height);
      let step state action =
        let state, operation = Inspection_view.input ~width ~height state action in
        assert (Option.is_none operation);
        Option.value_exn state
      in
      let bottom =
        List.fold (List.init 1000 ~f:Fn.id) ~init:inspector ~f:(fun state _ ->
          step state Down)
      in
      let up = step bottom Up in
      assert (up.scroll = bottom.scroll - 1);
      let host_for inspection =
        H.set_local host tile.id { H.default_local with inspection = Some inspection }
      in
      let frame state = render (host_for state) data dimensions in
      assert (View.width (frame bottom) = width && View.height (frame bottom) = height);
      assert (not (String.equal (plain_text (frame bottom)) (plain_text (frame up))));
      (* Opening the palette must preserve this actual inspector, not rebuild a different
         workspace underneath. Data callbacks above deliberately fail if the workspace
         renderer is accidentally entered. *)
      let source = host_for bottom in
      let opened =
        List.fold [ ' '; 'c'; 'c' ] ~init:source ~f:(fun host ch ->
          fst (H.input host (Character ch) ~commands:[]))
      in
      let overlay = render opened data dimensions in
      let b = Palette_view.bounds ~width ~height in
      let top image = View.crop ~b:(height - b.y) image |> plain_text in
      assert (b.y > 0 && String.equal (top overlay) (top (frame bottom)));
      let returned = fst (H.input opened Escape ~commands:[]) in
      assert (
        String.equal
          (plain_text (render returned data dimensions))
          (plain_text (frame bottom)));
      let stale =
        { (host_for bottom) with registry = Some (bind snapshot Asic_snapshot_fixture.run_b) }
      in
      assert (Option.is_none (inspection_explorer stale tile)))
;;

let%test_unit "unterminated inspection paste keeps query and rejection visible without \
               chrome after polling"
  =
  let open Bonsai_term.Event in
  let registry =
    W.initial ~session_id:(W.Session_id.of_string "inspection-paste-visible")
  in
  let tile = List.hd_exn registry.tiles in
  let inspector =
    { (Inspection_view.create ~run:Asic_snapshot_fixture.run_a ~domain:"timing" ~stage:"signoff" ()) with
      editing = true
    }
  in
  let host = H.receive H.empty registry in
  let host =
    H.set_local
      { host with focus = Some tile.id; chrome = false }
      tile.id
      { H.default_local with inspection = Some inspector }
  in
  let send host event =
    match H.route_inspection_filter_event host event with
    | H.Filter_handled host -> host
    | _ -> assert false
  in
  let host = send host (Paste `Start) in
  let host =
    String.fold "endpoint/Q jtr" ~init:host ~f:(fun host c ->
      send host (Key_press { key = ASCII c; mods = [] }))
  in
  let host = send host (Key_press { key = Enter; mods = [] }) in
  let host = H.receive host registry in
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> assert false)
    ; run_lines = (fun _ _ -> assert false)
    ; run_context = (fun _ -> assert false)
    ; summary = (fun _ -> assert false)
    ; status = "fixture"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let frame host = render host data { width = 120; height = 40 } |> plain_text in
  List.iter
    [ host; { host with focus = None } ]
    ~f:(fun host ->
      let text = frame host in
      assert (String.is_substring text ~substring:"FILTER PASTE ACTIVE");
      assert (String.is_substring text ~substring:"filter=endpoint/Q jtr");
      assert (String.is_substring text ~substring:"rejects controls"));
  let host = send host (Paste `End) in
  assert (not (String.is_substring (frame host) ~substring:"FILTER PASTE ACTIVE"))
;;

let%test_unit "filter input remains visible after polling and with chrome hidden" =
  let snapshot = W.initial ~session_id:(W.Session_id.of_string "filter-visible") in
  let tile = List.hd_exn snapshot.tiles in
  let host = H.receive H.empty snapshot in
  let host = H.set_local host tile.id { H.default_local with filter = "no-match" } in
  let host = H.receive { host with editing_filter = true; chrome = false } snapshot in
  assert (String.is_empty host.notice);
  let data =
    { project = None
    ; jobs = []
    ; runs = []
    ; log_lines = (fun _ -> [])
    ; run_lines = (fun _ _ -> [])
    ; run_context = (fun _ -> [])
    ; summary = (fun _ -> None)
    ; status = "connected"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = None
    }
  in
  let text = render host data { width = 120; height = 40 } |> plain_text in
  List.iter
    [ "FILTER INPUT"; "Enter/Esc finish"; "Ctrl-U clear"; "no-match" ]
    ~f:(fun label -> assert (String.is_substring text ~substring:label))
;;

let%test_unit "warm synthesis run switch renders 73 while pinned reference retains 50, \
               including compact frames"
  =
  let s = W.initial ~session_id:(W.Session_id.of_string "synthesis-frames") in
  let workspace = (List.hd_exn s.workspaces).id in
  let apply s mutation =
    W.apply s (Mutate { expected_revision = s.W.Snapshot.revision; mutation })
    |> Result.ok
    |> Option.value_exn
  in
  let s = apply s (Set_tile_hidden { tile = (List.hd_exn s.tiles).id; hidden = true }) in
  let geometry : W.Geometry.t = { x = 0; y = 0; width = 64; height = 10 } in
  let s = apply s (Create_tile { workspace; kind = "synthesis"; geometry }) in
  let following = (List.last_exn s.tiles).id in
  let s = apply s (Create_tile { workspace; kind = "synthesis"; geometry }) in
  let pinned = (List.last_exn s.tiles).id in
  let s =
    apply s (Set_tile_binding { tile = pinned; binding = Pin_run Asic_snapshot_fixture.run_a })
  in
  let select host run =
    let s = Option.value_exn host.H.registry in
    let mutation = H.select_run host (Some run) |> Option.value_exn in
    H.receive host (apply s mutation)
  in
  let data =
    { project = None
    ; jobs = []
    ; runs = List.map Asic_snapshot_fixture.snapshot.runs ~f:(fun run -> run.run, run.status)
    ; log_lines = (fun _ -> [])
    ; run_lines = run_lines (Some Asic_snapshot_fixture.snapshot)
    ; run_context = request_context (Some Asic_snapshot_fixture.snapshot)
    ; summary =
        (fun run ->
          List.find Asic_snapshot_fixture.snapshot.summaries ~f:(fun s -> Run_ref.equal s.run run))
    ; status = "SYNTHETIC FIXTURE"
    ; environment = "fixture"
    ; asic_lines = []
    ; asic = Some Asic_snapshot_fixture.snapshot
    }
  in
  let frame host width height =
    let view = render host data { width; height } in
    let buffer = Buffer.create (width * height) in
    Notty.Render.to_buffer
      buffer
      Notty.Cap.dumb
      (0, 0)
      (width, height)
      (View.Private.notty_image view);
    Buffer.contents buffer
  in
  let has frame text = String.is_substring frame ~substring:text in
  let host = select (H.receive H.empty s) Asic_snapshot_fixture.run_a in
  let host = { host with focus = Some following } in
  (* Overview is compact by default. Counts and provenance survive a run switch; cell
     tables remain an explicit Cells mode instead of consuming summary rows. *)
  let before = frame host 32 10 in
  assert (has before "Reported cells (agg.): 50");
  assert (has before "Evidence: cached/unver");
  assert (has before "Cell breakdown: 2 reported");
  assert (not (has before "/explicit/synthetic"));
  let host = select host Asic_snapshot_fixture.run_b in
  let registry_before = Option.value_exn host.registry |> W.Snapshot.sexp_of_t in
  List.iter appearance_cases ~f:(fun appearance ->
    let host = { host with appearance } in
    let both = frame host 128 24 in
    assert (has both "Reported cells (agg.): 73" && has both "Reported cells (agg.): 50");
    assert (has both "run asic/fixture-B" && has both "PIN asic/fixture-A");
    let small = frame host 32 10 in
    assert (has small "Reported cells (agg.): 73");
    assert (has small "Evidence: cached/unver");
    assert (has small "Cell breakdown: 2 reported");
    assert (not (has small "/explicit/synthetic"));
    let pinned_frame = frame { host with focus = Some pinned } 32 8 in
    assert (has pinned_frame "Reported cells (agg.): 50");
    assert (not (has pinned_frame "Reported cells (agg.): 73"));
    assert (
      Sexp.equal registry_before (Option.value_exn host.registry |> W.Snapshot.sexp_of_t)));
  let both = frame host 128 24 in
  assert (has both "Reported cells (agg.): 73" && has both "Reported cells (agg.): 50");
  assert (has both "run asic/fixture-B" && has both "PIN asic/fixture-A");
  let compact_following = frame host 32 8 in
  assert (has compact_following "Reported cells (agg.): 73");
  assert (not (has compact_following "Reported cells (agg.): 50"));
  let compact_pinned = frame { host with focus = Some pinned } 32 8 in
  assert (has compact_pinned "Reported cells (agg.): 50");
  assert (not (has compact_pinned "Reported cells (agg.): 73"));
  let _, intents =
    Asic_intents.plan
      Asic_intents.empty
      ~now:Time_ns.epoch
      Asic_snapshot_fixture.snapshot
      ~visible:(H.evidence_runs host)
  in
  assert (List.is_empty intents);
  let detail =
    H.set_local
      host
      following
      { (H.local host following) with
        synthesis =
          Synthesis_view.State.set_mode (H.local host following).synthesis Evidence
      }
  in
  List.iter [ H.Fit; H.Preferred ] ~f:(fun layout_mode ->
    let detail = { detail with layout_mode } in
    let small = { Dimensions.width = 32; height = 8 } in
    let large = { Dimensions.width = 128; height = 24 } in
    let bottom = scroll_focused detail data small ~delta:Int.max_value in
    let stopped =
      List.fold (List.init 100 ~f:Fn.id) ~init:bottom ~f:(fun host _ ->
        scroll_focused host data small ~delta:1)
    in
    let reverse = scroll_focused stopped data small ~delta:(-1) in
    assert (not (String.equal (frame bottom 32 8) (frame reverse 32 8)));
    let resized = scroll_focused stopped data large ~delta:(-1) in
    let expected =
      scroll_focused detail data large ~delta:Int.max_value
      |> fun host -> scroll_focused host data large ~delta:(-1)
    in
    assert (String.equal (frame resized 128 24) (frame expected 128 24));
    assert (
      Synthesis_view.Mode.equal
        (Synthesis_view.State.mode (H.local resized pinned).synthesis)
        Summary));
  let host = select host Asic_snapshot_fixture.run_a in
  assert (has (frame host 32 8) "Reported cells (agg.): 50")
;;

let%test_unit "stock Fit navigation completes rendered subtrees without reassigning cells"
  =
  List.iter P.Presets.all ~f:(fun definition ->
    let host, data, _ = refinement_fixture definition in
    let registry = Option.value_exn host.registry in
    (* Model a saved session whose tile order no longer matches the declaration. *)
    let registry = { registry with tiles = List.rev registry.tiles } in
    let host = { (H.receive host registry) with layout_mode = H.Fit; chrome = false } in
    let tiles = H.tiles host in
    let _, compact, cells = tile_layout host { width = 240; height = 100 } in
    assert (not compact);
    assert (
      List.equal
        W.Tile_id.equal
        (List.map tiles ~f:(fun tile -> tile.W.Tile.id))
        (List.map cells ~f:(fun (tile, _) -> tile.W.Tile.id)));
    let painted = ref [] in
    let render_pane (tile : W.Tile.t) ~width:_ ~height:_ =
      painted := tile.id :: !painted;
      None
    in
    let image = render ~render_pane host data { width = 240; height = 100 } in
    assert (View.width image = 240 && View.height image = 100);
    assert (
      List.equal
        W.Tile_id.equal
        (List.rev !painted)
        (List.map cells ~f:(fun (tile, _) -> tile.W.Tile.id)));
    let tree = P.Layout.resolve definition.layout (H.layout_keys host tiles) in
    let rec check = function
      | P.Layout.Cell (index, _, _, _) ->
        let tile = List.nth_exn tiles index in
        let rendered, geometry = List.nth_exn cells index in
        assert (W.Tile_id.equal tile.id rendered.id);
        [ tile ], geometry
      | Narrow child -> check child
      | Stack children -> check_children ~vertical:true children
      | Columns children -> check_children ~vertical:false children
      | Weighted_columns children ->
        check_children ~vertical:false (List.map children ~f:snd)
    and check_children ~vertical children =
      let groups = List.map children ~f:check in
      List.iteri groups ~f:(fun i (_, (a : W.Geometry.t)) ->
        List.iter
          (List.drop groups (i + 1))
          ~f:(fun (_, (b : W.Geometry.t)) ->
            assert (if vertical then a.y + a.height <= b.y else a.x + a.width <= b.x)));
      let bounds =
        List.map groups ~f:snd
        |> List.reduce_exn ~f:(fun (a : W.Geometry.t) (b : W.Geometry.t) ->
          let x = Int.min a.x b.x
          and y = Int.min a.y b.y in
          { W.Geometry.x
          ; y
          ; width = Int.max (a.x + a.width) (b.x + b.width) - x
          ; height = Int.max (a.y + a.height) (b.y + b.height) - y
          })
      in
      List.concat_map groups ~f:fst, bounds
    in
    let declared, _ = check (Option.value_exn tree) in
    let navigation = H.navigation_tiles host in
    assert (
      List.equal
        W.Tile_id.equal
        (List.map declared ~f:(fun tile -> tile.W.Tile.id))
        (List.map navigation ~f:(fun tile -> tile.W.Tile.id)));
    if String.equal definition.id "overview"
    then
      assert (
        List.equal
          String.equal
          (List.map navigation ~f:(fun tile -> tile.W.Tile.kind))
          [ "workspace-tabs"
          ; "live-status"
          ; "run-selector"
          ; "resource-summary"
          ; "stage-checklist"
          ; "planned-run"
          ; "preparation"
          ; "synthesis"
          ; "timing"
          ; "placement"
          ; "routing"
          ; "checks"
          ; "finalization"
          ]);
    assert (W.Snapshot.equal registry (Option.value_exn host.registry)))
;;

let%test_unit "keyed Fit navigation follows duplicate-kind placement while Preferred \
               packs registry order"
  =
  let config =
    P.Presets.custom_example () |> Or_error.ok_exn |> P.Presets.resolve |> Or_error.ok_exn
  in
  let initial = W.initial ~session_id:(W.Session_id.of_string "navigation-render") in
  let registry =
    W.apply initial (Initialize_config config)
    |> Result.ok
    |> Option.value_exn
    |> fun registry -> W.Snapshot.t_of_sexp (W.Snapshot.sexp_of_t registry)
  in
  let host = { (H.receive H.empty registry) with layout_mode = H.Fit; chrome = false } in
  let _, data, _ = refinement_fixture P.Overview.definition in
  let tiles = H.tiles host in
  assert (List.equal String.equal (H.layout_keys host tiles) [ "choose"; "left"; "right" ]);
  let choose = List.nth_exn tiles 0
  and left = List.nth_exn tiles 1
  and right = List.nth_exn tiles 2 in
  assert (String.equal left.kind right.kind);
  let ids tiles = List.map tiles ~f:(fun tile -> tile.W.Tile.id) in
  let fit_order = [ choose; right; left ] in
  assert (List.equal W.Tile_id.equal (ids (H.navigation_tiles host)) (ids fit_order));
  let _, compact, cells = tile_layout host { width = 120; height = 40 } in
  assert (not compact);
  assert (
    List.equal W.Tile_id.equal (List.map cells ~f:(fun (t, _) -> t.W.Tile.id)) (ids tiles));
  let geometry tile =
    List.find_exn cells ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.W.Tile.id) |> snd
  in
  let c = geometry choose
  and l = geometry left
  and r = geometry right in
  assert (c.y + c.height <= l.y && c.y + c.height <= r.y);
  assert (r.x + r.width <= l.x && r.y = l.y);
  let preferred = { host with layout_mode = H.Preferred } in
  assert (List.equal W.Tile_id.equal (ids (H.navigation_tiles preferred)) (ids tiles));
  let _, compact, packed = tile_layout preferred { width = 200; height = 40 } in
  assert (not compact);
  assert (
    List.equal
      W.Tile_id.equal
      (List.map packed ~f:(fun (t, _) -> t.W.Tile.id))
      (ids tiles));
  List.iteri packed ~f:(fun i (_, (a : W.Geometry.t)) ->
    List.iter
      (List.drop packed (i + 1))
      ~f:(fun (_, (b : W.Geometry.t)) -> assert (a.y = b.y && a.x + a.width <= b.x)));
  (* The narrow viewport cannot fit the declared columns, but can fit a grid. Geometry
     stays registry-associated while semantic focus order survives resize. *)
  let _, compact, grid = tile_layout host { width = 25; height = 25 } in
  assert (not compact);
  assert (
    List.equal W.Tile_id.equal (List.map grid ~f:(fun (t, _) -> t.W.Tile.id)) (ids tiles));
  List.iteri grid ~f:(fun i (_, (a : W.Geometry.t)) ->
    List.iter
      (List.drop grid (i + 1))
      ~f:(fun (_, (b : W.Geometry.t)) -> assert (a.x = b.x && a.y + a.height <= b.y)));
  let step host event =
    let host, effect = H.input host event ~commands:[] in
    (match effect with
     | No_effect -> ()
     | _ -> assert false);
    host
  in
  List.iter
    [ host, fit_order, { Dimensions.width = 25; height = 25 }, false
    ; host, fit_order, { Dimensions.width = 1; height = 1 }, true
    ; preferred, tiles, { Dimensions.width = 25; height = 8 }, false
    ]
    ~f:(fun (host, order, dimensions, expect_compact) ->
      let check host tile =
        assert (Option.equal W.Tile_id.equal host.H.focus (Some tile.W.Tile.id));
        let _, compact, visible = tile_layout host dimensions in
        assert (Bool.equal compact expect_compact);
        assert (List.exists visible ~f:(fun (t, _) -> W.Tile_id.equal t.id tile.id));
        if expect_compact
           ||
           match host.H.layout_mode with
           | Preferred -> true
           | Fit -> false
        then assert (List.length visible = 1);
        let image = render host data dimensions in
        assert (
          View.width image = dimensions.width && View.height image = dimensions.height);
        assert (W.Snapshot.equal registry (Option.value_exn host.registry))
      in
      let first = List.hd_exn order in
      let start = { host with focus = Some first.id } in
      let last =
        List.fold
          (List.tl_exn order @ [ first ])
          ~init:start
          ~f:(fun host tile ->
            let host = step host H.Focus in
            check host tile;
            host)
      in
      ignore
        (List.fold
           (List.rev (List.tl_exn order) @ [ first ])
           ~init:last
           ~f:(fun host tile ->
             let host = step host H.Focus_previous in
             check host tile;
             host)
         : H.t))
;;

let%test_unit "custom and unknown presets honor generic Fit without rewriting geometry" =
  let ok = function
    | Ok value -> value
    | Error error -> raise_s [%sexp (error : V1.Error.t)]
  in
  List.iter [ None; Some "future-preset" ] ~f:(fun preset ->
    let initial = W.initial ~session_id:(W.Session_id.of_string "custom-fit") in
    let template =
      { Workspace_template.generic with
        preset
      ; views =
          List.mapi Workspace_template.generic.views ~f:(fun i view ->
            { view with
              hidden = i = 1
            ; geometry = { x = i * 100; y = 300; width = 400; height = 200 }
            })
      }
    in
    let registry =
      W.apply
        initial
        (Mutate
           { expected_revision = initial.revision
           ; mutation =
               Instantiate_template
                 { window = (List.hd_exn initial.windows).id; template }
           })
      |> ok
    in
    let workspace = List.last_exn registry.workspaces in
    let host = H.switch (H.receive H.empty registry) workspace.id in
    let host = { host with layout_mode = H.Fit; chrome = false } in
    assert (Option.is_none (H.definition workspace));
    List.iter
      [ 90, 28; 120, 40; 25, 6; 1, 1 ]
      ~f:(fun (width, height) ->
        let _, compact, cells = tile_layout host { Dimensions.width; height } in
        assert (List.length cells = if compact then 1 else 3);
        assert (Bool.equal compact (width = 1 || width = 25));
        List.iteri cells ~f:(fun i (tile, (g : W.Geometry.t)) ->
          assert (not tile.W.Tile.hidden);
          assert (g.x >= 0 && g.y >= 0 && g.width > 0 && g.height > 0);
          assert (g.x + g.width <= width && g.y + g.height <= height);
          List.iter
            (List.drop cells (i + 1))
            ~f:(fun (_, (other : W.Geometry.t)) ->
              assert (
                g.x + g.width <= other.x
                || other.x + other.width <= g.x
                || g.y + g.height <= other.y
                || other.y + other.height <= g.y))));
    assert (W.Snapshot.equal registry (Option.value_exn host.registry));
    assert (
      Workspace_template.equal template (W.export_template registry workspace.id |> ok)))
;;

(* WB-054: contextual actions, breadcrumbs and explicit inspector close. *)

(* Built through sexp so optional index fields keep their declared defaults. *)
let wb054_index rows =
  let field name value = Sexp.List [ Atom name; value ] in
  let index =
    Asic_inspection.Index.t_of_sexp
      (Sexp.List
         [ field "run" (Run_ref.sexp_of_t Asic_snapshot_fixture.run_a)
         ; field "execution_file" (Atom "/exact/execution")
         ; field "execution_sha256" (Atom "exact-sha")
         ; field "domain" (Atom "timing")
         ; field "stage" (Atom "signoff")
         ; field "source_digest" (Atom "exact-source-digest")
         ; field "rows" (List [])
         ; field "diagnostics" (List [])
         ; field "truncated" (Atom "false")
         ; field "cached_unverified" (Atom "true")
         ])
  in
  { index with
    rows =
      List.init rows ~f:(fun i ->
        { Asic_inspection.Row.id = Int.to_string i
        ; name = sprintf "path-%02d/endpoint/Q" i
        ; category = "path"
        ; producer = "sta"
        ; corner = Some "slow"
        ; group = Some "clk"
        ; value = Some (Float.of_int i -. 1.)
        ; unit_ = Some "ns"
        ; status = "violated"
        ; source = "/exact/report"
        ; fields = []
        })
  }
;;

(* Timing fixture with an opened, reconciled paths index whose row "2" is selected. *)
let wb054_timing () =
  let host, data, find = refinement_fixture P.Timing.definition in
  let snapshot = { (Option.value_exn data.asic) with inspections = [ wb054_index 3 ] } in
  let state =
    Inspection_view.reconcile
      (Timing_workspace.create ~generation:4 ~run:Asic_snapshot_fixture.run_a ~stage:"signoff")
      snapshot
  in
  let paths = find "timing-paths" in
  let host = { host with notice = ""; focus = Some paths.id } in
  { host with notice = "" }, { data with asic = Some snapshot }, find, state
;;

let wb054_without_run host =
  let registry = Option.value_exn host.H.registry in
  let workspace = Option.value_exn (H.active host) in
  let context = W.context registry workspace.context in
  W.apply
    registry
    (Mutate
       { expected_revision = registry.revision
       ; mutation =
           Select_run
             { workspace = workspace.id
             ; context = context.id
             ; expected_selection_revision = context.selection_revision
             ; run = None
             }
       })
  |> Result.ok
  |> Option.value_exn
  |> H.receive host
  |> fun cleared -> { cleared with H.focus = host.H.focus }
;;

let wb054_commands host = H.contextual host (H.catalog host ~project:None ~jobs:[])

let wb054_reason host id =
  (List.find_exn (wb054_commands host) ~f:(fun c -> String.equal c.H.id id)).unavailable
;;

let%test_unit "WB-054 Timing actions stay listed with availability reasons" =
  let host, _, find, state = wb054_timing () in
  let paths = find "timing-paths"
  and detail = find "timing-detail" in
  (* Contextual actions lead the palette; close explains that nothing is open. *)
  assert (String.equal (List.hd_exn (wb054_commands host)).id "inspector.close");
  assert (
    Option.equal String.equal (wb054_reason host "inspector.close") (Some H.no_inspector));
  (* No paths index opened for the selected run yet. *)
  let unopened = { host with focus = Some detail.id } in
  assert (
    String.is_substring
      (Option.value_exn (wb054_reason unopened "inspector.open-detail"))
      ~substring:"no timing paths opened for this run");
  assert (Option.is_none (wb054_reason unopened "context.inspect-timing"));
  (* No run selected: the same actions remain, with the typed reason. *)
  let cleared = wb054_without_run unopened in
  List.iter
    [ "inspector.open-detail"; "inspector.refresh"; "context.inspect-timing" ]
    ~f:(fun id ->
      assert (Option.equal String.equal (wb054_reason cleared id) (Some "no run selected")));
  (* Selection-appropriate actions on the loaded paths table. *)
  let loaded = H.set_timing host paths { state with selected = Some "2" } in
  assert (Option.is_none (wb054_reason loaded "inspector.open-detail"));
  assert (Option.is_none (wb054_reason loaded "inspector.near"));
  (match
     (List.find_exn (wb054_commands loaded) ~f:(fun c ->
        String.equal c.id "inspector.open-detail"))
       .action
   with
   | Inspector_input (id, Open) -> assert (W.Tile_id.equal id paths.id)
   | _ -> assert false);
  let filtered = H.set_timing host paths { state with filter = "NO_MATCH" } in
  assert (
    Option.equal
      String.equal
      (wb054_reason filtered "inspector.open-detail")
      (Some "no rows match the current filter"));
  let opened =
    H.set_timing
      host
      paths
      { state with selected = Some "2"; requested = Some ("exact-source-digest", "2") }
  in
  assert (Option.is_none (wb054_reason opened "inspector.close"));
  assert (
    String.is_substring
      (Option.value_exn (wb054_reason opened "inspector.open-detail"))
      ~substring:"Space c x");
  (* Help names the explicit close only while it applies, and never claims q exits. *)
  assert (String.is_substring (main_hint_text opened) ~substring:"j/k select");
  assert (not (String.is_substring (main_hint_text loaded) ~substring:"q exit"));
  assert (String.is_substring (main_hint_text cleared) ~substring:"q exit")
;;

let%test_unit "WB-054 Testing panes keep selection actions with reasons" =
  let host, _, find = refinement_fixture P.Testing.definition in
  let cases = find "simulation-cases"
  and artifacts = find "simulation-artifacts" in
  let on tile = { host with focus = Some tile.W.Tile.id } in
  assert (
    Option.equal
      String.equal
      (wb054_reason (on cases) "simulation.rerun-case")
      (Some "no attempt selected"));
  assert (
    Option.equal
      String.equal
      (wb054_reason (on artifacts) "testing.artifact.export")
      (Some "no attempt selected"));
  let selected =
    H.update_testing (on cases) cases.id (fun state ->
      Testing_workspace.select_attempt state "attempt-1")
  in
  assert (
    Option.equal
      String.equal
      (wb054_reason selected "simulation.rerun-failed")
      (Some "attempt detail not loaded"));
  (* Project-scoped Testing panes do not advertise run-scoped evidence actions. *)
  assert (
    not
      (List.exists
         (wb054_commands (on cases))
         ~f:(fun c -> String.equal c.id "context.inspect-timing")));
  (* Placeholders explain rather than act. *)
  match
    (List.find_exn
       (wb054_commands (on cases))
       ~f:(fun c -> String.equal c.id "simulation.rerun-case"))
      .action
  with
  | Unavailable reason -> assert (String.equal reason "no attempt selected")
  | _ -> assert false
;;

let%test_unit "WB-054 close inspector returns focus predictably and keeps selection" =
  let host, _, find, state = wb054_timing () in
  let paths = find "timing-paths"
  and detail = find "timing-detail" in
  let registry = Option.value_exn host.registry in
  (* Timing: Detail opened from the paths table; close returns to timing · paths. *)
  let opened =
    H.set_timing
      { host with focus = Some detail.id }
      paths
      { state with selected = Some "2"; requested = Some ("exact-source-digest", "2") }
  in
  let closed, notice = H.close_inspector opened |> Result.ok |> Option.value_exn in
  assert (Option.equal W.Tile_id.equal closed.focus (Some paths.id));
  assert (String.is_substring notice ~substring:"timing · paths");
  let view = Option.value_exn (H.timing closed paths) in
  assert (Option.equal String.equal view.selected (Some "2"));
  assert (not (Inspection_view.detail_mode view));
  assert (view.generation > (Option.value_exn (H.timing opened paths)).generation);
  assert (phys_equal (Option.value_exn closed.registry) registry);
  assert (Result.is_error (H.close_inspector closed));
  (* The Space c x chord routes through the captured command path. *)
  let step host event = fst (H.input host event ~commands:[]) in
  (match
     H.input
       (step (step opened (Character ' ')) (Character 'c'))
       (Character 'x')
       ~commands:[]
   with
   | after, Execute (_, Close_inspector) -> assert (after.prefix = 0)
   | _ -> assert false);
  (* Explorer and artifact browser belong to the focused tile: focus stays there. *)
  let overview, _, ofind = refinement_fixture P.Overview.definition in
  let tile =
    List.find_exn (H.tiles overview) ~f:(fun tile ->
      Option.is_some (tile_run overview tile) && not (H.project_scoped_kind tile.kind))
  in
  ignore (ofind : string -> W.Tile.t);
  let overview = { overview with focus = Some tile.id } in
  let scope = tile_run overview tile in
  let explorer =
    H.set_local
      overview
      tile.id
      { (H.local overview tile.id) with
        inspection =
          Some
            (Inspection_view.create
               ?scope
               ~generation:3
               ~run:Asic_snapshot_fixture.run_a
               ~domain:"clocks"
               ~stage:"signoff"
               ())
      }
  in
  assert (
    Option.equal
      String.equal
      (wb054_reason explorer "inspector.near")
      (Some "near/violated applies to timing paths only"));
  let closed, _ = H.close_inspector explorer |> Result.ok |> Option.value_exn in
  assert (Option.is_none (H.local closed tile.id).inspection);
  assert ((H.local closed tile.id).inspection_generation >= 3);
  assert (Option.equal W.Tile_id.equal closed.focus (Some tile.id));
  let browser =
    H.set_local
      overview
      tile.id
      { (H.local overview tile.id) with
        artifacts = Some (Artifact_view.create ?scope ~generation:2 Asic_snapshot_fixture.run_a)
      }
  in
  let closed, _ = H.close_inspector browser |> Result.ok |> Option.value_exn in
  assert (Option.is_none (H.local closed tile.id).artifacts);
  assert (Option.equal W.Tile_id.equal closed.focus (Some tile.id))
;;

let%test_unit "WB-054 breadcrumbs use typed context, fit or vanish, and follow icon modes"
  =
  let host, data, find, state = wb054_timing () in
  let paths = find "timing-paths" in
  let host = H.set_timing host paths { state with selected = Some "2" } in
  let workspace = Option.value_exn (H.active host) in
  let run = display_run Asic_snapshot_fixture.run_a in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    let sep =
      match icons with
      | Unicode -> " › "
      | Ascii | None_ -> " > "
    in
    let full = String.concat ~sep [ workspace.name; "timing paths"; run ^ " (signoff)" ]
    and short = String.concat ~sep [ "timing paths"; run ^ " (signoff)" ] in
    assert (List.equal String.equal (breadcrumbs host) [ full; short ]);
    let text = "Space c c commands" in
    let fits crumb = cell_width text + 2 + cell_width crumb in
    let check width expected =
      let row = with_breadcrumb host ~width text in
      assert (String.is_prefix row ~prefix:text);
      match expected with
      | None -> assert (String.equal row text)
      | Some crumb ->
        assert (String.is_suffix row ~suffix:crumb && cell_width row = width)
    in
    check (fits full) (Some full);
    check (fits full - 1) (Some short);
    check (fits short - 1) None;
    (match icons with
     | Unicode -> ()
     | Ascii | None_ -> assert (not (String.is_substring full ~substring:"›")));
    (* Wide and narrow rendered screens: the crumb appears only when the row fits. *)
    let screen width = plain_text (render host data { Dimensions.width; height = 40 }) in
    assert (String.is_substring (screen 200) ~substring:full);
    let narrow = screen 60 in
    assert (not (String.is_substring narrow ~substring:short)));
  (* Never invent context: without a selected run there is no run or stage segment. *)
  let cleared = wb054_without_run host in
  List.iter (breadcrumbs cleared) ~f:(fun crumb ->
    assert (not (String.is_substring crumb ~substring:"(signoff)"));
    assert (not (String.is_substring crumb ~substring:Asic_snapshot_fixture.run_a.id)));
  (* An open inspector names itself and its stage. *)
  let overview, _, _ = refinement_fixture P.Overview.definition in
  let tile =
    List.find_exn (H.tiles overview) ~f:(fun tile ->
      Option.is_some (tile_run overview tile) && not (H.project_scoped_kind tile.kind))
  in
  let overview = { overview with focus = Some tile.id } in
  let explorer =
    H.set_local
      overview
      tile.id
      { (H.local overview tile.id) with
        inspection =
          Some
            (Inspection_view.create
               ?scope:(tile_run overview tile)
               ~run:Asic_snapshot_fixture.run_a
               ~domain:"clocks"
               ~stage:"signoff"
               ())
      }
  in
  assert (
    String.is_substring
      (List.hd_exn (breadcrumbs explorer))
      ~substring:("inspect clocks › " ^ run ^ " (signoff)"))
;;

let%test_unit "WB-054 full-area inspector renders breadcrumbs without losing content" =
  let host, data, _ = refinement_fixture P.Overview.definition in
  let tile =
    List.find_exn (H.tiles host) ~f:(fun tile ->
      Option.is_some (tile_run host tile) && not (H.project_scoped_kind tile.kind))
  in
  let host = { host with focus = Some tile.id; notice = "" } in
  let scope = tile_run host tile in
  let explorer =
    Inspection_view.create
      ?scope
      ~run:Asic_snapshot_fixture.run_a
      ~domain:"clocks"
      ~stage:"signoff"
      ()
  in
  let browser = Artifact_view.create ?scope Asic_snapshot_fixture.run_a in
  List.iter Appearance.Icons.all ~f:(fun icons ->
    let host = { host with appearance = { host.appearance with icons } } in
    List.iter
      [ Some explorer, None, "Waiting for explicitly requested index"
      ; None, Some browser, "No catalog entries received for this exact run"
      ]
      ~f:(fun (inspection, artifacts, content) ->
        let host =
          H.set_local host tile.id { (H.local host tile.id) with inspection; artifacts }
        in
        let full = List.hd_exn (breadcrumbs host)
        and short = List.last_exn (breadcrumbs host) in
        let screen host width =
          plain_text (render host data { Dimensions.width; height = 12 })
        in
        let wide = screen host 240 in
        assert (String.is_substring wide ~substring:full);
        assert (String.is_substring wide ~substring:content);
        (* Only the heading changes: every evidence/help row stays in place. *)
        let hidden = screen { host with main_hints = false } 240 in
        assert (not (String.is_substring hidden ~substring:short));
        assert (
          List.equal
            String.equal
            (List.tl_exn (String.split_lines wide))
            (List.tl_exn (String.split_lines hidden)));
        List.iter
          [ { host with chrome = false }
          ; { host with notice = "a notice takes precedence" }
          ]
          ~f:(fun host ->
            assert (not (String.is_substring (screen host 240) ~substring:short)));
        assert (not (String.is_substring (screen host 60) ~substring:short))))
;;

let%test_unit "WB-054 Timing rendered footer follows Paths Detail and Context focus" =
  let host, data, find, view = wb054_timing () in
  let paths = find "timing-paths" in
  let opened =
    { view with selected = Some "1"; requested = Some ("exact-source-digest", "1") }
  in
  List.iter [ false; true ] ~f:(fun detail_open ->
    let view = if detail_open then opened else { view with selected = Some "1" } in
    let host = H.set_timing host paths view in
    List.iter
      [ "timing-paths", Timing_workspace.Paths, "j/k select"
      ; "timing-detail", Detail, "j/k scroll"
      ; "timing-context", Context, "j/k scroll"
      ]
      ~f:(fun (kind, pane, hint) ->
        let host = { host with focus = Some (find kind).id } in
        let screen =
          plain_text (render host data { Dimensions.width = 240; height = 40 })
        in
        let footer = List.last_exn (String.split_lines (String.strip screen)) in
        assert (String.is_substring footer ~substring:hint);
        if detail_open && not (Timing_workspace.equal_pane pane Paths)
        then assert (String.is_substring footer ~substring:"Space c x close detail");
        let next, scroll, _ =
          Timing_workspace.input ~pane ~scroll:0 ~width:80 ~height:1 view Down
        in
        match pane with
        | Paths ->
          assert (not (Option.equal String.equal next.selected view.selected));
          assert (not (Inspection_view.detail_mode next))
        | Detail | Context ->
          assert (Option.equal String.equal next.selected view.selected);
          assert (scroll > 0)))
;;

let%test_unit "WB-054 artifact keyboard seam dispatches unavailable selection reasons" =
  let host, _, find = refinement_fixture P.Testing.definition in
  let tile = find "simulation-artifacts" in
  let host = { host with focus = Some tile.id } in
  List.iter
    [ host, "no attempt selected"
    ; ( H.update_testing host tile.id (fun state ->
          Testing_workspace.select_attempt state "a")
      , "attempt detail not loaded" )
    ]
    ~f:(fun (host, expected) ->
      List.iter [ 'e'; 'w' ] ~f:(fun key ->
        let event : Bonsai_term.Event.t = Key_press { key = ASCII key; mods = [] } in
        let dispatch =
          match H.decode_event event with
          | Some (Character key) ->
            H.testing_dispatch host key ~commands:(wb054_commands host)
            |> Option.value_exn
          | _ -> assert false
        in
        match snd dispatch with
        | Unavailable reason ->
          if Char.equal key 'w'
          then assert (String.is_substring reason ~substring:"No available supported VCD")
          else assert (String.equal reason expected)
        | _ -> assert false))
;;

let%test_unit "WB-054 production selection catalog promotes original runnable identities" =
  let host, _, find = refinement_fixture P.Testing.definition in
  let tile = find "simulation-artifacts" in
  let artifact : Simulation.Artifact.t =
    { id = "exact-vcd"
    ; attempt_id = "attempt"
    ; case_id = Some "case"
    ; label = "waves"
    ; kind = "waveform"
    ; media_type = "text/vcd"
    ; size = Some 123
    ; sha256 = Some (String.make 64 'a')
    ; availability = Available
    }
  in
  let attempt : Simulation.Attempt.t =
    { id = "attempt"
    ; job = Job_id.of_string "job"
    ; project_root = "/fixture"
    ; created_at = "now"
    ; parent = None
    ; captured =
        { selection =
            { suite = "suite"
            ; cases = [ "case" ]
            ; seed = "42"
            ; parameters = []
            ; asic_inputs = []
            }
        ; discovery_digest = "digest"
        ; provider_executable = "/provider"
        ; provider_args = []
        ; environment = Inherit_daemon
        }
    ; lifecycle = Finished
    ; outcome = Failed
    ; exit_code = Some 1
    ; diagnostic = None
    ; progress = None
    ; cases = [ { case_id = "case"; status = Failed; message = None; progress = None } ]
    ; artifacts = [ artifact ]
    ; next_sequence = 0
    ; recent_events = []
    ; execution_timing = None
    }
  in
  let snapshot : Simulation.Snapshot.t =
    { configured = true
    ; discovery = None
    ; discovery_digest = None
    ; discovery_job = None
    ; discovery_error = None
    ; history_error = None
    ; next_before = None
    ; detail = Some attempt
    ; byte_page = None
    ; attempts = []
    }
  in
  let loaded =
    H.set_simulation
      { host with focus = Some tile.id }
      tile.id
      { Simulation_view.empty with
        snapshot = Some snapshot
      ; attempt = Some attempt.id
      ; case_id = Some "case"
      }
  in
  let selected =
    H.update_testing loaded tile.id (fun state ->
      Testing_workspace.select_artifact state artifact.id)
  in
  let allocations = ref 0 in
  let base =
    H.catalog selected ~project:None ~jobs:[]
    @ H.simulation_selection_commands selected tile ~submission_key:(fun _ ->
      incr allocations;
      "captured-" ^ Int.to_string !allocations)
  in
  assert (!allocations = 2);
  let commands = H.contextual selected base in
  let ids = List.map commands ~f:(fun c -> c.H.id) in
  assert (not (List.contains_dup ids ~compare:String.compare));
  let promoted =
    [ "simulation.rerun-case"
    ; "simulation.rerun-failed"
    ; "simulation.export.exact-vcd"
    ; "simulation.waveform.exact-vcd"
    ]
  in
  assert (List.equal String.equal (List.take ids 5) ("inspector.close" :: promoted));
  List.iter promoted ~f:(fun id ->
    let original = List.find_exn base ~f:(fun c -> String.equal c.id id) in
    let current = List.find_exn commands ~f:(fun c -> String.equal c.id id) in
    assert (phys_equal original current);
    assert (Option.is_none current.unavailable));
  assert (!allocations = 2);
  List.iter [ 'r'; 'f'; 'e'; 'w' ] ~f:(fun key ->
    let id = Option.value_exn (H.testing_shortcut selected key) in
    let original = List.find_exn base ~f:(fun c -> String.equal c.id id) in
    let _, action = Option.value_exn (H.testing_dispatch selected key ~commands) in
    assert (phys_equal action original.action));
  (* Loaded artifacts now select a default immediately. An attempt without artifacts still
     explains e/w through the same dispatch. *)
  assert (Option.is_some (Testing_workspace.artifact (H.testing_state loaded tile.id)));
  let empty_artifacts =
    H.set_simulation
      { host with focus = Some tile.id }
      tile.id
      { Simulation_view.empty with
        snapshot = Some { snapshot with detail = Some { attempt with artifacts = [] } }
      ; attempt = Some attempt.id
      ; case_id = Some "case"
      }
  in
  List.iter [ 'e'; 'w' ] ~f:(fun key ->
    let _, action =
      Option.value_exn
        (H.testing_dispatch
           empty_artifacts
           key
           ~commands:
             (H.contextual
                empty_artifacts
                (H.catalog empty_artifacts ~project:None ~jobs:[])))
    in
    match action with
    | Unavailable reason ->
      if Char.equal key 'w'
      then assert (String.is_substring reason ~substring:"No available supported VCD")
      else assert (String.equal reason "no artifact selected")
    | _ -> assert false)
;;
