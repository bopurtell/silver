open! Core
open Silver_protocol
module R = Asic_resources
module E = Evidence_style

(** Pure resource investigation. Only [input] returns read intents. Reconciliation,
    rendering and filtering consume published facts and never initiate provider work. *)
type mode =
  | Table
  | Detail
  | Sources
  | Text
  | Context
  | Compare
[@@deriving equal]

type captured =
  { source : R.Source.t
  ; index : R.Index.t
  }

type t =
  { explicit : R.Target.t option
  ; target : R.Target.t option
  ; source : R.Source.t option
  ; index : R.Index.t option
  ; selected : string option
  ; mode : mode
  ; raw : bool
  ; section : string
  ; offset : int
  ; history : int list
  ; catalog_offset : int
  ; catalog_history : int list
  ; artifact : string option
  ; byte_offset : int
  ; byte_history : int list
  ; scroll : int
  ; generation : int
  ; pending : string option
  ; request_floor : int option
  ; receipt_floor : int option
  ; loading_index : bool
  ; error : string option
  ; left : captured option
  ; right : captured option
  }

let empty =
  { explicit = None
  ; target = None
  ; source = None
  ; index = None
  ; selected = None
  ; mode = Table
  ; raw = false
  ; section = "inventory"
  ; offset = 0
  ; history = []
  ; catalog_offset = 0
  ; catalog_history = []
  ; artifact = None
  ; byte_offset = 0
  ; byte_history = []
  ; scroll = 0
  ; generation = 0
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; left = None
  ; right = None
  }
;;

let is_kind = function
  | "resources" | "resource-summary" -> true
  | _ -> false
;;

let sections =
  [ "inventory"; "synthesis"; "final"; "geometry"; "timing"; "electrical"; "provenance" ]
;;

let snapshot asic =
  Option.bind asic ~f:(fun s -> s.Asic.Snapshot.resources)
  |> Option.value ~default:R.Snapshot.empty
;;

let target_label = function
  | R.Target.Run run -> "Execution " ^ run.id
  | Workflow_bundle id -> "Workflow bundle " ^ id
  | Finalization { run; attempt } -> "Finalization " ^ run.id ^ " / " ^ attempt
  | Coarse_run path -> "Imported coarse evidence " ^ path
  | Bundle path -> "Emitted bundle " ^ path
;;

let freshness = function
  | R.Freshness.Validated -> E.Role.Validated, "Validated source"
  | Cached_unverified -> Pending, "CACHED UNVERIFIED"
  | Missing_source reason -> Stale, "Missing source: " ^ reason
  | Stale reason -> Stale, "STALE: " ^ reason
  | Refresh_failed reason -> Stale, "Refresh failed: " ^ reason
  | Unsupported reason -> Muted, "Unsupported: " ^ reason
;;

let source_for target snapshot =
  Option.bind target ~f:(fun target ->
    List.find snapshot.R.Snapshot.sources ~f:(fun s -> R.Target.equal s.target target))
;;

let clear_pages t =
  { t with
    mode = Table
  ; raw = false
  ; offset = 0
  ; history = []
  ; catalog_offset = 0
  ; catalog_history = []
  ; artifact = None
  ; byte_offset = 0
  ; byte_history = []
  ; scroll = 0
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; generation = t.generation + 1
  }
;;

let reconcile ?revision t ~run ~filter asic =
  let target =
    Option.first_some t.explicit (Option.map run ~f:(fun r -> R.Target.Run r))
  in
  let changed = not (Option.equal R.Target.equal t.target target) in
  let t =
    if changed
    then { (clear_pages t) with selected = None; source = None; index = None; target }
    else t
  in
  let published = snapshot asic in
  let source = source_for target published in
  let index =
    Option.bind source ~f:(fun s ->
      List.find published.indexes ~f:(fun i -> String.equal i.source_id s.id))
  in
  let changed_digest =
    match t.index, index with
    | Some a, Some b ->
      (not (R.Index.equal a b))
      || not
           (Option.equal
              String.equal
              (Option.map t.source ~f:(fun s -> s.R.Source.provider_identity))
              (Option.map source ~f:(fun s -> s.R.Source.provider_identity)))
    | Some _, None -> true
    | _ -> false
  in
  let t =
    if changed_digest
    then (
      let reset = clear_pages t in
      if t.loading_index && Option.is_some t.pending
      then
        { reset with
          generation = t.generation
        ; pending = t.pending
        ; request_floor = t.request_floor
        ; receipt_floor = t.receipt_floor
        ; loading_index = true
        }
      else reset)
    else t
  in
  let rows = Option.value_map index ~default:[] ~f:(fun i -> i.rows) in
  let selected =
    match t.selected with
    | Some id when List.exists rows ~f:(fun row -> String.equal row.id id) -> Some id
    | _ -> Option.map (List.hd rows) ~f:(fun row -> row.R.Row.id)
  in
  let error, pending =
    match t.pending, t.receipt_floor, revision, asic with
    | Some key, Some floor, Some revision, Some s
      when revision >= floor
           && Option.value_map t.request_floor ~default:false ~f:(fun issued ->
             revision >= issued) ->
      (match
         List.find s.Asic.Snapshot.operations ~f:(fun op -> String.equal op.key key)
       with
       | Some op when String.equal op.state "failed" || Option.is_some op.error ->
         Some (Option.value op.error ~default:"Resource read failed"), None
       | Some op when String.equal op.state "completed" -> None, None
       | _ -> t.error, t.pending)
    | _ -> t.error, t.pending
  in
  ignore (filter : string);
  { t with target; source; index; selected; error; pending }
;;

let select_target t explicit =
  { (clear_pages t) with
    explicit
  ; target = None
  ; source = None
  ; index = None
  ; selected = None
  }
;;

let reconnect t =
  let unverified (s : R.Source.t) = { s with freshness = Cached_unverified } in
  let captured =
    Option.map ~f:(fun (c : captured) -> { c with source = unverified c.source })
  in
  { t with
    generation = t.generation + 1
  ; pending = None
  ; request_floor = None
  ; receipt_floor = None
  ; loading_index = false
  ; error = None
  ; source = Option.map t.source ~f:unverified
  ; left = captured t.left
  ; right = captured t.right
  }
;;

let visible t ~filter =
  Option.value_map t.index ~default:[] ~f:(fun i ->
    List.filter i.rows ~f:(fun row ->
      String.is_substring
        (String.lowercase
           (String.concat
              ~sep:" "
              [ row.id
              ; row.contract
              ; row.policy
              ; row.implementation
              ; row.reason
              ; row.role
              ]))
        ~substring:(String.lowercase filter)))
;;

let selected_row t =
  Option.bind t.index ~f:(fun i ->
    List.find i.rows ~f:(fun row -> Option.equal String.equal t.selected (Some row.id)))
;;

let current_detail t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).details ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && Option.equal String.equal t.selected (Some p.resource_id)
      && String.equal p.section t.section
      && p.offset = t.offset))
;;

let current_catalog t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).artifacts ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && p.offset = t.catalog_offset))
;;

let current_bytes t asic =
  Option.bind t.index ~f:(fun index ->
    List.find (snapshot asic).bytes ~f:(fun p ->
      String.equal p.source_id index.source_id
      && String.equal p.digest index.digest
      && Option.equal String.equal t.artifact (Some p.artifact_id)
      && p.offset = t.byte_offset))
;;

let page_operation t =
  Option.bind t.index ~f:(fun i ->
    let source_id = i.source_id
    and expected_digest = i.digest in
    match t.mode with
    | Detail ->
      Option.map t.selected ~f:(fun resource_id ->
        R.Operation.Detail
          { source_id
          ; expected_digest
          ; resource_id
          ; section = t.section
          ; offset = t.offset
          ; limit = 8
          })
    | Sources ->
      Some
        (R.Operation.Artifacts
           { source_id; expected_digest; offset = t.catalog_offset; limit = 16 })
    | Text ->
      Option.map t.artifact ~f:(fun artifact_id ->
        R.Operation.Read_artifact
          { source_id
          ; expected_digest
          ; artifact_id
          ; offset = t.byte_offset
          ; limit = 4096
          })
    | Table | Context | Compare -> None)
;;

type input =
  | Move of int
  | Open
  | Back
  | Refresh
  | Show_table
  | Show_sources
  | Show_context
  | Section of string
  | Next_page
  | Previous_page
  | Capture_left
  | Capture_right
  | Show_compare
  | Swap_compare
  | Scroll of int

let begin_request t operation =
  ( { t with
      pending = Some (R.Operation.key operation)
    ; request_floor = None
    ; receipt_floor = None
    ; loading_index =
        (match operation with
         | Load _ -> true
         | _ -> false)
    ; error = None
    ; generation = t.generation + 1
    }
  , Some operation )
;;

let browse_resource t selected =
  { t with
    selected
  ; scroll = 0
  ; offset = 0
  ; history = []
  ; pending = None
  ; generation = t.generation + 1
  }
;;

let browse_source t artifact =
  { t with artifact; scroll = 0; pending = None; generation = t.generation + 1 }
;;

let input t ~filter ~asic event =
  let request t =
    match page_operation t with
    | None -> t, None
    | Some op -> begin_request t op
  in
  let move ids selected delta =
    let index =
      Option.bind selected ~f:(fun id ->
        List.findi ids ~f:(fun _ x -> String.equal id x) |> Option.map ~f:fst)
      |> Option.value ~default:(if delta > 0 then -1 else 1)
    in
    List.nth ids (Int.max 0 (Int.min (List.length ids - 1) (index + delta)))
  in
  match event with
  | Refresh ->
    (match t.target with
     | None ->
       ( { t with
           error = Some "No exact source selected; select a run, workflow or import"
         }
       , None )
     | Some target -> begin_request t (Load { target; refresh = true }))
  | Show_table ->
    ( { t with mode = Table; scroll = 0; pending = None; generation = t.generation + 1 }
    , None )
  | Show_context ->
    ( { t with
        mode = Context
      ; raw = false
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Show_sources -> request { t with mode = Sources; scroll = 0 }
  | Section section ->
    if List.mem sections section ~equal:String.equal
    then (
      let candidates = visible t ~filter in
      let selected =
        if List.exists candidates ~f:(fun r ->
             Option.equal String.equal t.selected (Some r.R.Row.id))
        then t.selected
        else Option.map (List.hd candidates) ~f:(fun r -> r.R.Row.id)
      in
      if Option.is_none selected
      then { t with error = Some "No resource matches the filter" }, None
      else
        request
          { t with
            mode = Detail
          ; raw = false
          ; selected
          ; section
          ; offset = 0
          ; history = []
          ; scroll = 0
          })
    else { t with error = Some "Unknown resource section" }, None
  | Back ->
    ( { t with
        mode = (if equal_mode t.mode Text then Sources else Table)
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Scroll delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
  | Move delta when equal_mode t.mode Table ->
    ( browse_resource
        t
        (move (List.map (visible t ~filter) ~f:(fun r -> r.R.Row.id)) t.selected delta)
    , None )
  | Move delta when equal_mode t.mode Sources ->
    let ids =
      Option.value_map (current_catalog t asic) ~default:[] ~f:(fun p ->
        List.map p.entries ~f:(fun a -> a.R.Artifact.id))
    in
    browse_source t (move ids (Option.first_some t.artifact (List.hd ids)) delta), None
  | Move delta -> { t with scroll = Int.max 0 (t.scroll + delta) }, None
  | Open when equal_mode t.mode Sources ->
    let artifact =
      Option.first_some
        t.artifact
        (Option.bind (current_catalog t asic) ~f:(fun p ->
           Option.map (List.hd p.entries) ~f:(fun a -> a.R.Artifact.id)))
    in
    request
      { t with mode = Text; artifact; byte_offset = 0; byte_history = []; scroll = 0 }
  | Open when equal_mode t.mode Table ->
    let rows = visible t ~filter in
    let selected =
      if List.exists rows ~f:(fun r -> Option.equal String.equal t.selected (Some r.id))
      then t.selected
      else Option.map (List.hd rows) ~f:(fun r -> r.R.Row.id)
    in
    if Option.is_none selected
    then { t with error = Some "No resource matches the filter" }, None
    else
      request
        { t with
          mode = Detail
        ; raw = false
        ; section = "inventory"
        ; selected
        ; offset = 0
        ; history = []
        ; scroll = 0
        }
  | Open when equal_mode t.mode Detail || equal_mode t.mode Context ->
    { t with raw = not t.raw; scroll = 0 }, None
  | Open -> t, None
  | Capture_left | Capture_right ->
    (match t.source, t.index with
     | Some source, Some index ->
       let captured = Some { source; index } in
       ( (match event with
          | Capture_left -> { t with left = captured }
          | _ -> { t with right = captured })
       , None )
     | _ ->
       { t with error = Some "Load an exact source before capturing comparison" }, None)
  | Show_compare ->
    ( { t with mode = Compare; scroll = 0; pending = None; generation = t.generation + 1 }
    , None )
  | Swap_compare ->
    ( { t with
        left = t.right
      ; right = t.left
      ; scroll = 0
      ; pending = None
      ; generation = t.generation + 1
      }
    , None )
  | Next_page | Previous_page ->
    let next offset history next total =
      match event with
      | Previous_page ->
        (match history with
         | [] -> offset, history
         | previous :: rest -> previous, rest)
      | _ ->
        if next < total && next > offset then next, offset :: history else offset, history
    in
    let t =
      match t.mode with
      | Detail ->
        Option.value_map (current_detail t asic) ~default:t ~f:(fun p ->
          let offset, history = next t.offset t.history p.next_offset p.total in
          { t with offset; history; scroll = 0 })
      | Sources ->
        Option.value_map (current_catalog t asic) ~default:t ~f:(fun p ->
          let catalog_offset, catalog_history =
            next t.catalog_offset t.catalog_history p.next_offset p.total
          in
          { t with catalog_offset; catalog_history; artifact = None; scroll = 0 })
      | Text ->
        Option.value_map (current_bytes t asic) ~default:t ~f:(fun p ->
          let byte_offset, byte_history =
            next t.byte_offset t.byte_history p.next_offset p.total
          in
          { t with byte_offset; byte_history; scroll = 0 })
      | Table | Context | Compare -> t
    in
    request t
;;

let admit t ~generation ~request_floor =
  if generation <> t.generation || Option.is_none t.pending
  then t
  else { t with request_floor = Some request_floor; receipt_floor = None }
;;

let receipt ?(floor = 0) t ~generation result =
  if generation <> t.generation
  then t
  else (
    match result with
    | Ok () -> { t with error = None; receipt_floor = Some floor }
    | Error error -> { t with pending = None; error = Some error })
;;

let fact label value = E.plain (label ^ ": " ^ value)
let missing text = [ { E.text; role = E.Role.Muted } ]
let number value = sprintf "%.12g" value
let words = String.tr ~target:'_' ~replacement:' '

let rec json_sexp : Yojson.Basic.t -> Sexp.t = function
  | `Assoc [ ("atom", `String s) ] -> Atom s
  | `Assoc [ ("list", `List xs) ] -> List (List.map xs ~f:json_sexp)
  | `Assoc xs -> List (List.map xs ~f:(fun (k, v) -> Sexp.List [ Atom k; json_sexp v ]))
  | `List xs ->
    List
      (List.mapi xs ~f:(fun i v ->
         Sexp.List [ Atom (Int.to_string (i + 1)); json_sexp v ]))
  | `String s -> Atom s
  | scalar -> Atom (Yojson.Basic.to_string scalar)
;;

let structured value =
  List.exists [ "{"; "["; "(" ] ~f:(fun prefix ->
    String.is_prefix (String.strip value) ~prefix)
;;

let contract_fields value =
  let describe kind sexp =
    let ram = String.equal kind "single_port_ram" in
    let rec fields path = function
      | Sexp.Atom s ->
        let value =
          match ram, path with
          | true, [ "width" ] -> s ^ if String.equal s "1" then " bit" else " bits"
          | true, [ "depth" ] -> s ^ if String.equal s "1" then " word" else " words"
          | true, [ "port" ] when String.equal s "1rw" -> "1 read/write port"
          | true, [ "read_latency" ] ->
            s ^ if String.equal s "1" then " cycle" else " cycles"
          | _ -> s
        in
        [ ( (if List.is_empty path
             then "Contract"
             else String.concat ~sep:" / " (List.map path ~f:words) |> String.capitalize)
          , value )
        ]
      | List [] -> fields path (Atom "none reported")
      | List xs ->
        List.concat_mapi xs ~f:(fun i -> function
          | Sexp.List [ Atom k; v ] -> fields (path @ [ k ]) v
          | other -> fields (path @ [ Int.to_string (i + 1) ]) other)
    in
    ("Kind", if ram then "Single-port RAM" else kind) :: fields [] sexp
  in
  let parsed =
    Or_error.try_with (fun () ->
      match Yojson.Basic.from_string value with
      | `Assoc fields ->
        let get key = List.Assoc.find_exn fields ~equal:String.equal key in
        let kind = Yojson.Basic.Util.to_string (get "kind") in
        let sexp =
          match get "contract" with
          | `String s -> Sexp.of_string s
          | j -> json_sexp j
        in
        describe kind sexp
      | _ -> failwith "not a request")
  in
  match parsed with
  | Ok text -> text
  | Error _ ->
    (match String.lsplit2 value ~on:' ' with
     | Some (kind, rest) when (not (structured kind)) && String.is_prefix rest ~prefix:"("
       ->
       (match Or_error.try_with (fun () -> describe kind (Sexp.of_string rest)) with
        | Ok text -> text
        | Error _ -> [ "Contract", "See raw metadata" ])
     | _ when structured value -> [ "Contract", "See raw metadata" ]
     | _ -> [ "Contract", value ])
;;

let contract value =
  contract_fields value
  |> List.map ~f:(fun (k, v) -> k ^ ": " ^ v)
  |> String.concat ~sep:" · "
;;

let decision reason =
  if structured reason
  then "See raw metadata"
  else (
    match String.lsplit2 reason ~on:' ' with
    | Some (key, qualifier) -> words key ^ " " ^ qualifier
    | None -> words reason)
;;

let decision_role reason : E.Role.t =
  match List.hd (String.split reason ~on:' ') with
  | Some "exact_mapping" -> Validated
  | Some ("budget_exhausted" | "flop_fallback") -> Pending
  | _ -> Plain
;;

let stage_role : string -> E.Role.t = function
  | "matched" | "pass" -> Passed
  | "fail" | "missing" | "unexpected" | "mismatched" -> Failed
  | "unresolved" -> Pending
  | "unavailable" | "not_applicable" -> Muted
  | _ -> Plain
;;

let verdict value = E.fact ~label:"Resource verdict: " Verdict value

let selection_fact (r : R.Row.t) =
  E.plain "Selection reason: "
  @ [ { E.text = decision r.reason; role = decision_role r.reason } ]
;;

let stage_fact (r : R.Row.t) =
  E.plain "Realized synthesis / final: "
  @ [ { E.text = words r.synthesis; role = stage_role r.synthesis }
    ; { E.text = " / "; role = Plain }
    ; { E.text = words r.final; role = stage_role r.final }
    ]
;;

(** Header and body use the same cell allocation. Prioritize the decision when a split
    pane has insufficient space for role or stage columns. *)
let table_line ~width ~selected (row : R.Row.t option) =
  let cell weight title get =
    weight, Option.value_map row ~default:(title, E.Role.Muted) ~f:get
  in
  let columns =
    [ cell 2 "Resource" (fun r -> r.id, Plain)
    ; cell
        (if width >= 60 then 4 else 3)
        "Decision"
        (fun r ->
          (* Keep the decision readable in a split pane. The full qualifier, including the
             macro name and exhausted limit, is in selection_fact. *)
          let label =
            List.hd_exn (String.split (decision r.reason) ~on:'(') |> String.rstrip
          in
          label, decision_role r.reason)
    ]
    @ (if width < 39
       then []
       else [ cell 3 "Implementation" (fun r -> r.implementation, Plain) ])
    @ (if width < 60
       then []
       else
         [ cell 2 "Synth" (fun r -> words r.synthesis, stage_role r.synthesis)
         ; cell 2 "Final" (fun r -> words r.final, stage_role r.final)
         ])
    @ if width < 99 then [] else [ cell 3 "Actual role" (fun r -> words r.role, Plain) ]
  in
  let available = Int.max 0 (width - 2 - List.length columns + 1) in
  let total = List.sum (module Int) columns ~f:fst in
  let _, cells =
    List.fold_map columns ~init:0 ~f:(fun used (weight, (text, role)) ->
      let last = used + weight in
      let size = (last * available / total) - (used * available / total) in
      let clipped = E.clip ~width:size (E.plain text) |> E.text in
      let pad =
        Int.max 0 (size - Bonsai_term.View.width (Bonsai_term.View.text clipped))
      in
      last, { E.text = clipped ^ String.make pad ' '; role })
  in
  E.plain (if selected then "> " else "  ")
  @ List.intersperse cells ~sep:{ E.text = " "; role = Plain }
;;

let field_rows ~raw (key, value) =
  let rec describe label : Yojson.Basic.t -> E.row list = function
    | `Assoc [] | `List [] -> [ fact label "none reported" ]
    | `Assoc fields ->
      List.concat_map fields ~f:(fun (k, v) -> describe (label ^ " / " ^ words k) v)
    | `List xs ->
      List.concat_mapi xs ~f:(fun i -> describe (sprintf "%s %d" label (i + 1)))
    | `Null -> [ missing (label ^ ": not reported") ]
    | `String s -> [ fact label (if structured s then "See raw metadata" else s) ]
    | scalar -> [ fact label (Yojson.Basic.to_string scalar) ]
  in
  if raw
  then [ fact key value ]
  else if String.equal key "requested_contract"
  then [ fact "Requested contract" (contract value) ]
  else if String.equal key "inventory_record"
  then [ missing "Original inventory record in raw metadata" ]
  else if structured value
  then (
    match Or_error.try_with (fun () -> Yojson.Basic.from_string value) with
    | Ok json -> describe (words key) json
    | Error _ -> [ fact (words key) "See raw metadata" ])
  else [ fact (words key) value ]
;;

let classification (m : R.Measurement.t) =
  match m.classification with
  | Observed -> "observed"
  | Derived -> "derived (source-qualified)"
  | Estimate -> "estimate"
  | Unknown -> "unknown classification"
;;

let measurement (m : R.Measurement.t) =
  fact
    m.name
    (Option.value_map
       m.value
       ~default:
         ("unavailable" ^ Option.value_map m.reason ~default:"" ~f:(fun s -> " — " ^ s))
       ~f:number
     ^ " "
     ^ m.unit_
     ^ " · stage="
     ^ m.stage
     ^ " · scope="
     ^ m.scope
     ^ " · "
     ^ m.definition
     ^ " · "
     ^ classification m)
;;

let inventory (i : R.Index.t) =
  match i.inventory_status with
  | Available ->
    if List.is_empty i.rows
    then "0 resources (verified empty inventory)"
    else sprintf "%d resources (available inventory)" (List.length i.rows)
  | Unavailable ->
    "inventory unavailable — "
    ^ Option.value i.inventory_reason ~default:"reason not supplied"
  | Unknown ->
    "inventory unknown — "
    ^ Option.value
        i.inventory_reason
        ~default:"legacy/incomplete availability information"
;;

let aligned_field ~width ?(role = E.Role.Plain) label value =
  let label = label ^ ":" in
  let size = Bonsai_term.View.width (Bonsai_term.View.text label) in
  let column = Int.min 22 (width / 2) in
  let indent = String.make (Int.max 0 column) ' ' in
  let values = E.wrap ~width:(Int.max 1 (width - column)) [ { E.text = value; role } ] in
  if size >= column
  then missing label :: List.map values ~f:(fun line -> E.plain indent @ line)
  else
    List.mapi values ~f:(fun i line ->
      (if i = 0 then missing (label ^ String.make (column - size) ' ') else E.plain indent)
      @ line)
;;

let row_facts ~width (r : R.Row.t) =
  let field = aligned_field ~width in
  let group name rows = E.plain name :: List.concat rows in
  List.concat
    (List.intersperse
       ~sep:[ E.plain " " ]
       [ group
           "Request & requirements"
           ([ field "Resource" r.id ]
            @ List.map (contract_fields r.contract) ~f:(fun (k, v) -> field k v)
            @ [ field
                  "Requirement"
                  (match r.requirement with
                   | "exact_or_flop_fallback" -> "Prefer an exact macro; allow flops"
                   | "exact" -> "Require an exact macro"
                   | "flops" -> "Require flops"
                   | other -> words other)
              ; field
                  "Policy"
                  (if structured r.policy then "See raw metadata" else r.policy)
              ])
       ; group
           "Selection results"
           [ field "Selected mapping" r.implementation
           ; field "Selection reason" ~role:(decision_role r.reason) (decision r.reason)
           ]
       ; group
           "Actual implementation"
           [ field "Actual role" (words r.role)
           ; field
               "Elaborated instances"
               (if List.is_empty r.instances
                then "none reported"
                else String.concat ~sep:", " r.instances)
           ]
       ; group
           "Realization / qualifications"
           [ field "Synthesis" ~role:(stage_role r.synthesis) (words r.synthesis)
           ; field "Final" ~role:(stage_role r.final) (words r.final)
           ; (if String.equal r.role "behavioral_model"
              then
                [ missing "Behavioral/simulation elaboration is not physical realization"
                ]
              else [])
           ]
       ])
;;

let capture_lines name (captured : captured option) =
  match captured with
  | None -> [ missing (name ^ ": not captured — capture an explicitly loaded source") ]
  | Some c ->
    let role, text = freshness c.source.freshness in
    [ fact name (target_label c.source.target)
    ; fact (name ^ " digest") c.index.digest
    ; fact (name ^ " source") c.source.path
    ; fact (name ^ " resource verdict") c.index.verdict
    ; fact (name ^ " inventory") (inventory c.index)
    ; fact
        (name ^ " coverage")
        (if c.index.truncated then "TRUNCATED" else "complete retained projection")
    ; [ { E.text = name ^ " " ^ text; role } ]
    ]
;;

let compare_measurements a b =
  let supplied side (m : R.Measurement.t) =
    side
    ^ "="
    ^
    match m.value with
    | None -> "unavailable — " ^ Option.value m.reason ~default:"not reported"
    | Some value when not (Float.is_finite value) -> "nonfinite"
    | Some value -> number value ^ " " ^ m.unit_
  in
  List.map a ~f:(fun (a : R.Measurement.t) ->
    match List.find b ~f:(R.Measurement.compatible a) with
    | None ->
      fact
        a.name
        (supplied "A" a
         ^ "; B missing or incompatible name/stage/unit/definition/scope/classification; \
            no delta")
    | Some b ->
      (match a.value, b.value with
       | None, _ | _, None ->
         fact
           a.name
           (supplied "A" a ^ "; " ^ supplied "B" b ^ "; unavailable measurement; no delta")
       | Some av, Some bv when not (Float.is_finite av && Float.is_finite bv) ->
         fact
           a.name
           (supplied "A" a ^ "; " ^ supplied "B" b ^ "; nonfinite measurement; no delta")
       | _ when not (R.Measurement.is_measured a && R.Measurement.is_measured b) ->
         fact
           a.name
           (supplied "A" a
            ^ "; "
            ^ supplied "B" b
            ^ " · "
            ^ classification a
            ^ "; no measured delta")
       | Some av, Some bv
         when Float.is_finite av && Float.is_finite bv && Float.is_finite (bv -. av) ->
         fact
           a.name
           (sprintf
              "A=%s B=%s Δ(B−A)=%s %s · %s · %s · %s · %s"
              (number av)
              (number bv)
              (number (bv -. av))
              a.unit_
              a.stage
              a.scope
              a.definition
              (classification a))
       | _ -> fact a.name "measurement subtraction overflow; no delta"))
  @ List.filter_map b ~f:(fun b ->
    if List.exists a ~f:(R.Measurement.compatible b)
    then None
    else
      Some
        (fact
           b.R.Measurement.name
           (supplied "B" b ^ "; A missing or incompatible measurement; no delta")))
;;

let compare_lines t =
  capture_lines "A" t.left
  @ capture_lines "B" t.right
  @
  match t.left, t.right with
  | Some a, Some b ->
    [ missing
        "Only finite observed or source-qualified derived measurements with identical \
         name/stage/unit/definition/scope/classification have deltas; no best-result \
         verdict"
    ]
    @ compare_measurements a.index.measurements b.index.measurements
    @ List.concat_map a.index.rows ~f:(fun row ->
      match List.find b.index.rows ~f:(fun r -> String.equal r.id row.id) with
      | None -> [ fact row.id "A-only resource; B unavailable" ]
      | Some other ->
        [ fact "Resource" row.id
        ; fact "Contract A / B" (contract row.contract ^ " / " ^ contract other.contract)
        ; fact "Requirement A / B" (row.requirement ^ " / " ^ other.requirement)
        ; fact "Policy A / B" (row.policy ^ " / " ^ other.policy)
        ; fact "Selection A / B" (row.implementation ^ " / " ^ other.implementation)
        ; fact "Reason A / B" (row.reason ^ " / " ^ other.reason)
        ; fact "Role A / B" (row.role ^ " / " ^ other.role)
        ; fact "Synthesis A / B" (row.synthesis ^ " / " ^ other.synthesis)
        ; fact "Final A / B" (row.final ^ " / " ^ other.final)
        ]
        @ compare_measurements row.measurements other.measurements)
    @ List.filter_map b.index.rows ~f:(fun row ->
      if List.exists a.index.rows ~f:(fun r -> String.equal r.id row.id)
      then None
      else Some (fact row.id "B-only resource; A unavailable"))
  | _ -> []
;;

let empty_table_rows t =
  match t.index with
  | None when Option.is_none t.target ->
    [ missing
        "No run selected. Choose Resources: Select execution in the command palette."
    ; missing "For mapping before synthesis, choose Resources: Select workflow bundle."
    ]
  | None -> [ missing "No loaded resource index — r loads the source shown in Scope." ]
  | Some i when not (R.Inventory_status.equal i.inventory_status Available) ->
    [ missing (inventory i) ]
  | Some i when List.is_empty i.rows ->
    [ E.plain
        "Verified empty resource inventory: this design registered no resource requests."
    ; missing "Ordinary RTL registers are not listed as resource requests."
    ]
  | Some _ -> [ missing "No resource matches this filter in the available inventory" ]
;;

let preview_label ~width label =
  let label = label ^ ":" in
  (* Leave most of the row for the value. On narrow tiles long labels can still
     run into the value column rather than consuming an extra physical row. *)
  let column = Int.min 14 (width / 2) in
  label ^ String.make (Int.max 1 (column - String.length label)) ' '
;;

let source_lines ?width ?preview_width t =
  let field ?(role = E.Role.Plain) label value =
    match width, preview_width with
    | Some width, _ -> aligned_field ~width ~role label value
    | None, Some width ->
      [ E.plain (preview_label ~width label) @ [ { E.text = value; role } ] ]
    | None, None -> [ [ { E.text = label ^ ": " ^ value; role } ] ]
  in
  let separate_source = Option.is_some width || Option.is_some preview_width in
  field
    "Scope"
    (Option.value_map
       t.target
       ~default:"No selected run or explicit source"
       ~f:target_label)
  @ field
      (if separate_source then "Binding" else "Source")
      (if Option.is_some t.explicit
       then "Explicit · independent of Main"
       else "Exact run · follow/pin")
  @ Option.value_map t.source ~default:[] ~f:(fun source ->
    let role, text = freshness source.freshness in
    (if separate_source
     then field "Source" source.label @ field ~role "Freshness" text
     else [ [ { E.text; role }; { E.text = " · " ^ source.label; role = Muted } ] ])
    @ Option.value_map source.error ~default:[] ~f:(field "Source error"))
  @ Option.value_map t.pending ~default:[] ~f:(fun _ ->
    [ missing "Read requested (retained evidence only)" ])
  @ Option.value_map t.error ~default:[] ~f:(fun text ->
    field ~role:Stale "Read error" text)
  @ Option.value_map t.index ~default:[] ~f:(fun i ->
    let bundle_design =
      match t.target with
      | Some (R.Target.Bundle _ | Workflow_bundle _) ->
        (match Or_error.try_with (fun () -> Yojson.Basic.from_string i.provenance) with
         | Ok (`Assoc fields) ->
           (match List.Assoc.find fields "project" ~equal:String.equal with
            | Some (`String project) ->
              let assignments =
                match
                  List.Assoc.find fields "hardware_assignments" ~equal:String.equal
                with
                | Some (`Assoc xs) ->
                  List.filter_map xs ~f:(fun (k, v) ->
                    match v with
                    | `String s -> Some (k ^ "=" ^ s)
                    | `Bool _ | `Int _ -> Some (k ^ "=" ^ Yojson.Basic.to_string v)
                    | _ -> None)
                | _ -> []
              in
              field
                "Inspecting design"
                (String.concat ~sep:" · " (project :: assignments))
            | _ -> [])
         | _ -> [])
      | _ -> []
    in
    bundle_design
    @ field "Inventory" (inventory i)
    @
    if i.truncated
    then
      field
        ~role:Stale
        "TRUNCATED index"
        "provider reports an incomplete projection; inspect original sources"
    else [])
;;

let execution_rows ~fact t asic =
  let chip (selection : Asic.Selection.t) =
    Option.value_map selection.chip_target ~default:[] ~f:(fun c ->
      [ fact "Source chip / variant" (c.chip ^ " / " ^ c.variant) ])
  in
  let run_status run =
    let exact =
      Option.bind asic ~f:(fun s ->
        List.find s.Asic.Snapshot.runs ~f:(fun r -> Run_ref.equal r.run run))
    in
    Option.value_map (Option.bind exact ~f:(fun r -> r.selection)) ~default:[] ~f:chip
    @ [ fact
          "Execution status"
          (exact
           |> Option.value_map
                ~default:"unavailable (no exact execution observation loaded)"
                ~f:(fun r -> r.status))
      ]
  in
  match t.target with
  | Some (R.Target.Run run) -> run_status run
  | Some (Finalization { run; attempt }) ->
    run_status run
    @ [ fact
          "Finalization status"
          (Option.bind asic ~f:(fun s ->
             List.find s.Asic.Snapshot.finalizations ~f:(fun f ->
               Run_ref.equal f.run run
               && Option.equal String.equal f.attempt (Some attempt)))
           |> Option.value_map
                ~default:"unavailable (inspect exact retained provenance)"
                ~f:(fun f -> f.state))
      ]
  | Some (Workflow_bundle id) ->
    let exact =
      Option.bind asic ~f:(fun s ->
        List.find s.Asic.Snapshot.workflows ~f:(fun w -> String.equal w.id id))
    in
    Option.value_map exact ~default:[] ~f:(fun w -> chip w.intent.selection)
    @ [ fact
          "Workflow elaboration status"
          (exact
           |> Option.value_map
                ~default:"unavailable (no exact workflow observation loaded)"
                ~f:(fun w -> w.elaboration_status))
      ]
  | Some (Bundle _) ->
    [ fact "Execution association" "bundle inventory only; no execution selected" ]
    @ Option.value_map
        (Option.bind asic ~f:(fun s -> s.Asic.Snapshot.chip_target))
        ~default:[]
        ~f:(fun c -> [ fact "Launch target" (c.chip ^ " / " ^ c.variant) ])
  | Some (Coarse_run _) ->
    [ fact
        "Execution status"
        "retained coarse source; original lifecycle in provenance (not a named run)"
    ]
  | None -> []
;;

let execution_lines = execution_rows ~fact

let summary_headline t ~width =
  let fits row = Bonsai_term.View.width (Bonsai_term.View.text (E.text row)) <= width in
  let first_fitting rows ~default = List.find rows ~f:fits |> Option.value ~default in
  Option.value_map
    t.index
    ~default:
      (if Option.is_none t.target
       then
         first_fitting
           [ missing "No run selected · Enter" ]
           ~default:(missing "No run · Enter")
       else
         first_fitting
           [ missing "No resource index · Enter" ]
           ~default:(missing "No index · Enter"))
    ~f:(fun i ->
      let role, _ =
        Option.value_map t.source ~default:(E.Role.Muted, "unavailable") ~f:(fun s ->
          freshness s.freshness)
      in
      let compact_status =
        match t.source with
        | None -> "source unavailable"
        | Some s ->
          (match s.freshness with
           | Validated -> "validated"
           | Cached_unverified -> "cached-unverified"
           | Missing_source _ -> "source missing"
           | Stale _ -> "stale"
           | Refresh_failed _ -> "refresh failed"
           | Unsupported _ -> "unsupported")
      in
      let count = List.length i.rows in
      let inventory_label =
        match i.inventory_status with
        | Available ->
          (match count with
           | 0 when i.truncated -> "0 retained"
           | 0 -> "0 (verified empty)"
           | 1 -> "1 resource"
           | count -> sprintf "%d resources" count)
        | Unavailable -> "inventory unavailable"
        | Unknown -> "inventory unknown"
      in
      let coverage =
        if i.truncated then [ { E.text = " · TRUNCATED"; role = Stale } ] else []
      in
      let status_value = [ { E.text = compact_status; role } ] in
      let status = E.plain " · " @ status_value in
      let inventory = E.plain inventory_label @ coverage in
      let short =
        match i.inventory_status with
        | Available -> E.plain (Int.to_string count) @ coverage
        | Unavailable -> E.plain "unavailable" @ coverage
        | Unknown -> E.plain "unknown" @ coverage
      in
      let alternatives =
        if i.truncated
           || not (R.Inventory_status.equal i.inventory_status Available)
           || (count = 0 && E.Role.equal role Validated)
        then [ inventory; short ]
        else [ short @ status; short @ E.plain " " @ status_value; inventory ]
      in
      first_fitting ((inventory @ status) :: alternatives) ~default:short)
;;

let summary_page ?(titled = true) t ~width ~height =
  let prefix = "Resources: " in
  let width_of text = Bonsai_term.View.width (Bonsai_term.View.text text) in
  let headline =
    if titled
    then summary_headline t ~width
    else (
      (* Saved stock layouts and explicit title overrides can leave the preview
         without a separate heading. Keep its first line self-identifying. *)
      let available = width - width_of prefix in
      let first = summary_headline t ~width:available in
      let first =
        if Option.is_none t.index
        then
          if width_of (E.text first) <= available then first else missing "Enter"
        else (
          let with_hint = first @ missing " · Enter" in
          if width_of (E.text with_hint) <= available then with_hint else first)
      in
      E.plain prefix @ first)
  in
  let details =
    if height <= 1
    then []
    else
      Option.value_map t.index ~default:[] ~f:(fun i ->
        if String.is_empty (String.strip i.verdict)
        then []
        else [ E.fact ~label:(preview_label ~width "Verdict") Verdict i.verdict ])
      @ source_lines ~preview_width:width t
  in
  (* Keep the verdict on the next physical row even when the status does not fit. *)
  List.take (headline :: details) (Int.max 0 height) |> List.map ~f:(E.clip ~width)
;;

let comparison_validation t asic =
  List.concat_map
    [ "A", t.left; "B", t.right ]
    ~f:(fun (side, captured) ->
      Option.value_map captured ~default:[] ~f:(fun (c : captured) ->
        match
          ( List.find (snapshot asic).sources ~f:(fun s -> String.equal s.id c.source.id)
          , List.find (snapshot asic).indexes ~f:(fun i ->
              String.equal i.source_id c.source.id) )
        with
        | Some source, Some index
          when R.Index.equal index c.index
               && String.equal source.provider_identity c.source.provider_identity
               && R.Target.equal source.target c.source.target
               && String.equal source.kind c.source.kind
               && String.equal source.path c.source.path ->
          let role, text = freshness source.freshness in
          [ [ { E.text = side ^ " current source: " ^ text; role } ] ]
        | _ ->
          [ missing
              (side
               ^ " captured provider/projection is no longer the loaded observation; \
                  retained capture only, not revalidated")
          ]))
;;

let qualifications ~width t =
  Option.value_map t.index ~default:[] ~f:(fun i ->
    aligned_field
      ~width
      ~role:(E.status_role (E.normalize Verdict i.verdict))
      "Resource verdict"
      i.verdict
    @ List.concat_map i.diagnostics ~f:(aligned_field ~width "Qualification"))
;;

let detail_hint ~hints ~raw =
  match hints, raw with
  | true, true -> [ missing "RAW METADATA · Enter for readable view" ]
  | true, false -> [ missing "Enter: raw metadata · j/k: scroll" ]
  | false, true -> [ missing "RAW METADATA" ]
  | false, false -> []
;;

let detail_navigation ~hints =
  if hints
  then [ missing "g/t/e sections · n/p pages · a sources · d provenance" ]
  else []
;;

let contents ?(width = 100) ?(hints = true) t ~filter ~asic =
  let field label value = aligned_field ~width label value in
  let group title rows =
    if List.is_empty rows then [] else [ E.plain " "; E.plain title ] @ rows
  in
  let ordinary = String.equal t.section "inventory" && not t.raw in
  let section_catalog () =
    Option.value_map (selected_row t) ~default:[] ~f:(fun r ->
      List.concat_map r.sections ~f:(fun s ->
        field (words s.R.Section.id) (sprintf "%s (%d)" (words s.status) s.count)))
  in
  let lines =
    match t.mode with
    | Compare -> comparison_validation t asic @ compare_lines t
    | Context ->
      [ E.plain "Provenance & execution" ]
      @ source_lines ~width t
      @ List.concat (execution_rows ~fact:field t asic)
      @ qualifications ~width t
      @ group
          "Provider metadata"
          (Option.value_map t.source ~default:[] ~f:(fun s ->
             field "Source ID" s.id
             @ field "Provider kind" s.kind
             @ field "Source path" s.path
             @ field "Provider identity" s.provider_identity)
           @ Option.value_map t.index ~default:[] ~f:(fun i ->
             field "Source digest" i.digest
             @ field
                 "Index coverage"
                 (if i.truncated then "TRUNCATED" else "Complete retained projection")
             @ field_rows ~raw:t.raw ("Provenance", i.provenance)
             @ List.map i.measurements ~f:measurement))
      @ group "Section catalog" (section_catalog ())
    | Table ->
      let rows = visible t ~filter in
      [ fact
          "Filter"
          (sprintf
             "%s · %d matches"
             (if String.is_empty filter then "(none)" else filter)
             (List.length rows))
      ; table_line ~width ~selected:false None
      ]
      @ List.map rows ~f:(fun r ->
        table_line
          ~width
          ~selected:(Option.equal String.equal t.selected (Some r.id))
          (Some r))
      @ if List.is_empty rows then empty_table_rows t else []
    | Detail ->
      Option.value_map
        (selected_row t)
        ~default:[ missing "No resource selected" ]
        ~f:(fun r ->
          if t.raw
          then
            [ fact "Raw contract" r.contract
            ; fact "Raw selection reason" r.reason
            ; fact "Raw policy" r.policy
            ]
          else if String.equal t.section "inventory"
          then row_facts ~width r
          else
            [ fact "Resource" r.id
            ; fact "Selected implementation" r.implementation
            ; selection_fact r
            ; fact "Actual role" (words r.role)
            ; stage_fact r
            ])
      @ qualifications ~width t
      @ (if ordinary
         then []
         else
           group
             "Section catalog"
             (field "Detail section" t.section
              @ Option.value_map
                  (current_detail t asic)
                  ~default:
                    (if String.equal t.section "inventory" && not t.raw
                     then []
                     else
                       [ missing
                           "Section page not loaded — choose section / n or p to read"
                       ])
                  ~f:(fun p ->
                    field
                      "Page items"
                      (sprintf "%d–%d / %d (n/p pages)" p.offset p.next_offset p.total)
                    @
                    if String.equal t.section "inventory" && not t.raw
                    then []
                    else
                      List.concat_map p.items ~f:(fun item ->
                        E.plain ("— " ^ item.R.Item.title)
                        :: List.concat_map item.fields ~f:(field_rows ~raw:t.raw)))
              @ section_catalog ()))
      @ Option.value_map (selected_row t) ~default:[] ~f:(fun r ->
        List.map r.measurements ~f:measurement)
    | Sources ->
      Option.value_map
        (current_catalog t asic)
        ~default:[ missing "Source catalog page not loaded — a loads authorized sources" ]
        ~f:(fun p ->
          [ fact
              "Source references"
              (sprintf
                 "%d–%d / %d · n/p pages; j/k select; Enter reads bytes"
                 p.offset
                 p.next_offset
                 p.total)
          ]
          @ List.map p.entries ~f:(fun a ->
            E.plain
              ((if Option.equal String.equal t.artifact (Some a.R.Artifact.id)
                then "> "
                else "  ")
               ^ a.label
               ^ " · "
               ^ a.format
               ^ " · "
               ^ a.id
               ^ " · sha256="
               ^ a.sha256)))
    | Text ->
      Option.value_map
        (current_bytes t asic)
        ~default:
          [ missing
              "Authorized source bytes unavailable or not retained; n/p reads exact pages"
          ]
        ~f:(fun p ->
          let text =
            Or_error.try_with (fun () ->
              Cryptokit.transform_string (Cryptokit.Hexa.decode ()) p.bytes_hex)
          in
          [ fact "Artifact" p.artifact_id
          ; fact "SHA256" p.sha256
          ; fact
              "Byte span"
              (sprintf
                 "%d–%d / %d (n/p pages; chunk boundaries may split text)"
                 p.offset
                 p.next_offset
                 p.total)
          ]
          @
          match text with
          | Error _ -> [ missing "Invalid byte transport" ]
          | Ok text ->
            List.map (String.split_lines text) ~f:(fun line ->
              E.plain (Artifact_view.safe line)))
  in
  if equal_mode t.mode Detail
  then
    detail_hint ~hints ~raw:t.raw
    @ lines
    @ (if ordinary
       then []
       else
         group
           "Provenance & execution"
           (source_lines ~width t @ List.concat (execution_rows ~fact:field t asic)))
    @ detail_navigation ~hints
  else
    (if hints && equal_mode t.mode Context
     then
       [ missing
           (if t.raw
            then "RAW METADATA · Enter for readable view"
            else "Enter: raw metadata · Esc: table")
       ]
     else [])
    @ (if hints && not (equal_mode t.mode Context)
       then
         [ missing
             "j/k browse/scroll · Enter detail/read · Esc back · / filter · Ctrl-U clear \
              · r refresh · a sources · d provenance · g/t/e geometry/timing/electrical \
              · n/p pages · c compare · Space c c commands"
         ]
       else [])
    @ (if equal_mode t.mode Compare || equal_mode t.mode Context
       then []
       else
         source_lines t
         @ execution_lines t asic
         @ Option.value_map t.index ~default:[] ~f:(fun i ->
           [ verdict i.verdict ] @ List.map i.diagnostics ~f:(fact "Qualification")))
    @ lines
;;

let investigation_page ?(linked = false) ~hints t ~filter ~asic ~width ~height =
  let plain rows = List.map rows ~f:(fun row -> None, row) in
  let lines =
    if equal_mode t.mode Table
    then (
      let candidates = visible t ~filter in
      let position =
        Option.bind t.selected ~f:(fun id ->
          List.findi candidates ~f:(fun _ r -> String.equal r.id id) |> Option.map ~f:fst)
      in
      let selected = Option.value position ~default:0 in
      let filter_line =
        fact
          "Filter"
          (sprintf
             "%s · %d matching retained rows"
             (if String.is_empty filter then "(none)" else filter)
             (List.length candidates))
      in
      let status =
        Option.value_map t.index ~default:[] ~f:(fun i -> [ verdict i.verdict ])
      in
      let top =
        let source = source_lines t in
        let execution = execution_lines t asic in
        let full = status @ source @ execution @ [ filter_line ] in
        if linked && List.length full > height / 3
        then
          List.take
            ((if String.is_empty filter then [] else [ filter_line ])
             @ List.take source 1
             @ status
             @ List.drop source 1
             @ execution)
            (height / 3)
        else full
      in
      let chrome = if hints then 2 else 1 in
      let top = List.take top (Int.max 0 (height - chrome - 1)) in
      let capacity = Int.max 1 (height - List.length top - chrome) in
      let start = Int.max 0 (selected - capacity + 1) in
      let entries = List.drop candidates start |> Fn.flip List.take capacity in
      plain (List.map top ~f:(E.clip ~width) @ [ table_line ~width ~selected:false None ])
      @ List.map entries ~f:(fun r ->
        ( Some (`Resource r.R.Row.id)
        , table_line
            ~width
            ~selected:(Option.equal String.equal t.selected (Some r.id))
            (Some r) ))
      @ plain
          ((if List.is_empty candidates then empty_table_rows t else [])
           @
           if hints
           then
             [ missing
                 (if Option.is_none position && not (List.is_empty candidates)
                  then "Enter selects first match · / filter · Ctrl-U clear"
                  else
                    "j/k browse · Enter detail · / filter · r refresh · a sources · d \
                     provenance · Space c c commands")
               |> E.clip ~width
             ]
           else []))
    else if equal_mode t.mode Sources
    then (
      let page = current_catalog t asic in
      let entries = Option.value_map page ~default:[] ~f:(fun p -> p.entries) in
      let position =
        Option.bind t.artifact ~f:(fun id ->
          List.findi entries ~f:(fun _ a -> String.equal id a.R.Artifact.id)
          |> Option.map ~f:fst)
        |> Option.value ~default:0
      in
      let capacity = Int.max 1 (height / 3) in
      let start = Int.max 0 (position - capacity + 1) in
      plain
        ((if hints
          then
            [ missing
                "j/k select · Enter read text · n/p catalog pages · Esc table · [/] \
                 scroll metadata"
            ]
          else [])
         @ List.map (source_lines t) ~f:(E.clip ~width)
         @ List.map (execution_lines t asic) ~f:(E.clip ~width)
         @ Option.value_map
             page
             ~default:[ missing "Catalog page unavailable — a loads authorized sources" ]
             ~f:(fun p ->
               [ fact
                   "Source references"
                   (sprintf "%d–%d / %d" p.offset p.next_offset p.total)
               ]))
      @ (List.drop entries start
         |> Fn.flip List.take capacity
         |> List.mapi ~f:(fun n a ->
           ( Some (`Source a.R.Artifact.id)
           , E.plain
               ((if start + n = position then "> " else "  ")
                ^ a.R.Artifact.label
                ^ " · "
                ^ a.format)
             |> E.clip ~width )))
      @ plain
          (Option.value_map (List.nth entries position) ~default:[] ~f:(fun artifact ->
             [ fact "Selected source" artifact.label
             ; fact "Opaque ID" artifact.id
             ; fact "Format" artifact.format
             ; fact "SHA256" artifact.sha256
             ])))
    else plain (contents ~width ~hints t ~filter ~asic)
  in
  let scroll = if equal_mode t.mode Table then 0 else t.scroll in
  E.page_with_targets ~width ~height ~offset:scroll lines
;;

let page_with_targets = investigation_page ~linked:false ~hints:true

let rows t ~filter ~asic ~width ~height =
  page_with_targets t ~filter ~asic ~width ~height |> List.map ~f:snd
;;

let list_page_with_targets ?(hints = true) t =
  investigation_page ~linked:true ~hints { t with mode = Table }
;;

let detail_page_with_targets ?(hints = true) t ~filter ~asic ~width ~height =
  if equal_mode t.mode Table
  then (
    let lines =
      Option.value_map
        (List.find (visible t ~filter) ~f:(fun r ->
           Option.equal String.equal t.selected (Some r.id)))
        ~default:[ missing "No visible resource selected" ]
        ~f:(fun r ->
          detail_hint ~hints ~raw:false
          @ row_facts ~width r
          @ qualifications ~width t
          @ List.map r.measurements ~f:measurement
          @ detail_navigation ~hints)
    in
    E.page ~width ~height ~offset:t.scroll lines |> List.map ~f:(fun row -> None, row))
  else investigation_page ~linked:true ~hints t ~filter ~asic ~width ~height
;;
