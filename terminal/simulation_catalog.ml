open! Core
open Hardcaml_workbench_protocol
module S = Simulation

type overrides =
  { seed : string
  ; parameters : (string * string) list
  }

type t =
  { discovery : S.Discovery.t option
  ; digest : string option
  ; configured : bool
  ; blocked : string option
  ; refreshing : bool
  ; suite_id : string option
  ; case_id : string option
  ; selected : string list
  ; captured_suite : S.Suite.t option
  ; captured_digest : string option
  ; overrides : overrides option
  ; filter : string
  }

let empty =
  { discovery = None
  ; digest = None
  ; configured = false
  ; blocked = Some "Discover a simulation catalog first"
  ; refreshing = false
  ; suite_id = None
  ; case_id = None
  ; selected = []
  ; captured_suite = None
  ; captured_digest = None
  ; overrides = None
  ; filter = ""
  }
;;

let suites t = Option.value_map t.discovery ~default:[] ~f:(fun d -> d.suites)
let suite_id t = t.suite_id
let case_id t = t.case_id
let selected_cases t = t.selected
let filter t = t.filter
let set_filter t filter = { t with filter }

let suite t =
  List.find (suites t) ~f:(fun s -> Option.equal String.equal t.suite_id (Some s.id))
;;

let select_suite t id =
  match List.find (suites t) ~f:(fun s -> String.equal s.id id) with
  | None -> t
  | Some s ->
    { t with
      suite_id = Some id
    ; case_id = Option.map (List.hd s.cases) ~f:(fun c -> c.id)
    ; selected = List.map s.cases ~f:(fun c -> c.id)
    ; captured_suite = Some s
    ; captured_digest = t.digest
    ; overrides =
        (if Option.equal String.equal t.suite_id (Some id)
            && Option.equal S.Suite.equal t.captured_suite (Some s)
            && Option.equal String.equal t.captured_digest t.digest
         then t.overrides
         else None)
    }
;;

let pending_message = "Discovery in flight; retained catalog is browse-only"

let update t (s : S.Snapshot.t) =
  let previous_suite = suite t in
  let refreshing = Option.is_some s.discovery_job in
  let blocked =
    if not s.configured
    then Some "No simulation provider configured"
    else (
      match s.discovery_error, s.discovery, s.discovery_digest with
      | Some error, _, _ -> Some ("Discovery failed: " ^ error)
      | None, Some _, Some _ -> None
      | None, _, _ when refreshing -> Some pending_message
      | None, None, _ -> Some "No current discovery; retained catalog is browse-only"
      | None, Some _, None -> Some "Discovery digest unavailable; discover again")
  in
  let t =
    { t with
      discovery = Option.first_some s.discovery t.discovery
    ; digest = (if Option.is_none blocked then s.discovery_digest else None)
    ; configured = s.configured
    ; blocked
    ; refreshing
    }
  in
  let t =
    if Option.equal String.equal t.captured_digest t.digest
       && Option.equal S.Suite.equal previous_suite (suite t)
    then t
    else { t with overrides = None }
  in
  (* Only initial discovery selects a default. A missing selected suite/case stays
     selected, even if a newly discovered suite occupies its former position. *)
  match t.suite_id, List.hd (suites t) with
  | None, Some s -> select_suite t s.id
  | _ -> t
;;

let invalidate t = { t with blocked = Some "Reconnect: refresh discovery before launch" }

(* Wait for the discovery RPC to report whether the current catalog remains
   authoritative. Once it does, the background job is progress, not a launch fence. *)
let begin_discovery t = { t with blocked = Some pending_message }

let discovery_failed t error = { t with blocked = Some ("Discovery failed: " ^ error) }

let visible_cases t =
  let query = String.lowercase (String.strip t.filter) in
  Option.value_map (suite t) ~default:[] ~f:(fun s ->
    List.filter s.cases ~f:(fun c ->
      String.is_empty query
      || List.exists [ s.id; s.label; c.id; c.label ] ~f:(fun text ->
        String.is_substring (String.lowercase text) ~substring:query)))
;;

let move ids current delta =
  match ids with
  | [] -> current
  | _ ->
    let index =
      Option.bind current ~f:(fun id -> List.findi ids ~f:(fun _ x -> String.equal id x))
      |> Option.value_map ~default:(if delta < 0 then List.length ids else -1) ~f:fst
    in
    List.nth ids (Int.max 0 (Int.min (List.length ids - 1) (index + delta)))
;;

let move_suite t delta =
  match move (List.map (suites t) ~f:(fun s -> s.id)) t.suite_id delta with
  | Some id when not (Option.equal String.equal t.suite_id (Some id)) -> select_suite t id
  | _ -> t
;;

let select_case t id =
  if List.exists (visible_cases t) ~f:(fun c -> String.equal c.id id)
  then { t with case_id = Some id }
  else t
;;

let move_case t delta =
  { t with
    case_id = move (List.map (visible_cases t) ~f:(fun c -> c.id)) t.case_id delta
  }
;;

let toggle_case t id =
  if List.mem t.selected id ~equal:String.equal
  then { t with selected = List.filter t.selected ~f:(Fn.non (String.equal id)) }
  else if Option.exists (suite t) ~f:(fun s ->
            List.exists s.cases ~f:(fun c -> String.equal c.id id))
  then { t with selected = t.selected @ [ id ] }
  else t
;;

let toggle_current t = Option.value_map t.case_id ~default:t ~f:(toggle_case t)

let select_all t =
  Option.value_map (suite t) ~default:t ~f:(fun s ->
    { t with selected = List.map s.cases ~f:(fun c -> c.id) })
;;

let missing t s =
  List.filter t.selected ~f:(fun id ->
    not (List.exists s.S.Suite.cases ~f:(fun c -> String.equal c.id id)))
;;

let accept t =
  match suite t with
  | Some s when List.is_empty (missing t s) && Option.is_none t.blocked ->
    { t with captured_suite = Some s; captured_digest = t.digest }
  | _ -> t
;;

let disabled_reason t =
  match t.blocked with
  | Some _ as reason -> reason
  | None ->
    if not t.configured
    then Some "No simulation provider configured"
    else (
      match suite t with
      | None ->
        Some
          (Option.value_map t.suite_id ~default:"No suite selected" ~f:(fun id ->
             "Selected suite removed: " ^ id ^ "; explicitly choose a suite"))
      | Some s ->
        let removed = missing t s in
        if not (List.is_empty removed)
        then
          Some
            ("Selected cases removed: "
             ^ String.concat ~sep:", " removed
             ^ "; correct selection explicitly")
        else if List.is_empty t.selected
        then Some "Select at least one case"
        else if Option.is_none t.digest
        then Some "Discovery digest unavailable; discover again"
        else if (not (Option.equal String.equal t.digest t.captured_digest))
                || not (Option.equal S.Suite.equal (Some s) t.captured_suite)
        then Some "Catalog changed; explicitly accept refreshed discovery/defaults"
        else None)
;;

let current_selection t s =
  let defaults = Simulation_view.selection s in
  let selection =
    match t.overrides with
    | None -> defaults
    | Some { seed; parameters } -> { defaults with seed; parameters }
  in
  { selection with cases = t.selected }
;;

let save_configuration t (selection : S.Selection.t) =
  { t with
    selected = selection.cases
  ; overrides = Some { seed = selection.seed; parameters = selection.parameters }
  }
;;

let launch t =
  match disabled_reason t with
  | Some reason -> Or_error.error_string reason
  | None ->
    let s = Option.value_exn t.captured_suite in
    let selection = current_selection t s in
    Ok (s, selection, Option.value_exn t.captured_digest)
;;

let rows ?(string_compression = true) t =
  let row = Simulation_view.row in
  let reason = disabled_reason t in
  let readiness =
    match reason with
    | Some reason -> "Launch disabled: " ^ reason
    | None ->
      if t.refreshing
      then "Ready for explicit launch; discovery refresh in progress"
      else "Ready for explicit launch"
  in
  [ row
      ~spans:
        [ Simulation_view.span
            ~start:0
            (if Option.is_none reason then Success else Warning)
            readiness
        ]
      readiness
  ; row
      (Option.value_map (suite t) ~default:"Choose a suite" ~f:(fun s ->
         "Suite: " ^ s.id ^ " — " ^ s.label))
  ; row (sprintf "Selected: %d cases; filter: %s" (List.length t.selected) t.filter)
  ; row ~hint:true "R quick run with shown inputs; e save inputs; Enter edit one run"
  ]
  @ List.map (visible_cases t) ~f:(fun c ->
    row
      ~selected:(Option.equal String.equal t.case_id (Some c.id))
      ~target:(Catalog_case c.id)
      ((if Option.equal String.equal t.case_id (Some c.id) then "> " else "  ")
       ^ (if List.mem t.selected c.id ~equal:String.equal then "[x] " else "[ ] ")
       ^ c.id
       ^ " — "
       ^ c.label))
  @ [ row "SUITES" ]
  @ List.map (suites t) ~f:(fun s ->
    row
      ~target:(Catalog_suite s.id)
      ((if Option.equal String.equal t.suite_id (Some s.id) then "> " else "  ")
       ^ s.id
       ^ " — "
       ^ s.label))
  @ Option.value_map (suite t) ~default:[] ~f:(fun s ->
     let selection = current_selection t s in
     let seed_label = if Option.is_some t.overrides then "Saved seed: " else "Default seed: " in
     [ row ~indicator:Seed (seed_label ^ selection.seed) ]
    @ List.map s.parameters ~f:(fun p ->
      row
        ("Parameter "
         ^ p.key
         ^ " = "
         ^ List.Assoc.find_exn selection.parameters p.key ~equal:String.equal
         ^
         if List.is_empty p.choices
         then ""
         else " [" ^ String.concat ~sep:", " p.choices ^ "]")))
  @ [ row ("Selected cases: " ^ String.concat ~sep:", " t.selected)
    ; row
        ("Captured discovery: "
         ^ Option.value_map
             t.captured_digest
             ~default:"none"
             ~f:(Presentation.identifier ~compress:string_compression))
    ]
  |> List.concat_map ~f:(fun r ->
    String.split_lines r.Simulation_view.text
    |> List.mapi ~f:(fun i text ->
      { r with
        text = Artifact_view.safe text
      ; indicator = (if i = 0 then r.indicator else None)
      ; selected = i = 0 && r.selected
      ; spans = (if i = 0 then r.spans else [])
      }))
;;

module Test_data = struct
  let suite : S.Suite.t =
    { id = "fifo"
    ; label = "FIFO"
    ; cases =
        [ { id = "directed"; label = "Wrap around" }
        ; { id = "seeded"; label = "Random" }
        ]
    ; default_seed = "42"
    ; parameters = [ { key = "cycles"; label = "Cycles"; default = "100"; choices = [] } ]
    }
  ;;

  let snapshot ?(digest = "d1") suites : S.Snapshot.t =
    { configured = true
    ; discovery = Some { protocol_version = 1; suites }
    ; discovery_digest = Some digest
    ; discovery_job = None
    ; discovery_error = None
    ; attempts = []
    ; next_before = None
    ; detail = None
    ; byte_page = None
    ; history_error = None
    }
  ;;
end

let%test_unit "catalog captures exact subset defaults and digest; filter only browses" =
  let s = Test_data.suite in
  let exact_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" in
  let t = update empty (Test_data.snapshot ~digest:exact_digest [ s ]) in
  let t = toggle_case t "directed" |> fun t -> set_filter t "rAnDoM" in
  assert (
    List.equal String.equal (List.map (visible_cases t) ~f:(fun c -> c.id)) [ "seeded" ]);
  let _, selected, digest = launch t |> Or_error.ok_exn in
  assert (String.equal digest exact_digest);
  assert (Option.equal String.equal t.digest (Some exact_digest));
  assert (Option.equal String.equal t.captured_digest (Some exact_digest));
  assert (
    List.exists (rows t) ~f:(fun row ->
      String.equal row.Simulation_view.text "Captured discovery: 0123…cdef"));
  (* Even a refresh with the same condensed label must invalidate the capture. *)
  let changed_digest =
    String.prefix exact_digest 10 ^ "changed" ^ String.suffix exact_digest 10
  in
  let refreshed = update t (Test_data.snapshot ~digest:changed_digest [ s ]) in
  assert (
    String.equal
      (Overview_tiles.short_id changed_digest)
      (Overview_tiles.short_id exact_digest));
  assert (Or_error.is_error (launch refreshed));
  let _, _, accepted_digest = launch (accept refreshed) |> Or_error.ok_exn in
  assert (String.equal accepted_digest changed_digest);
  assert (List.equal String.equal selected.cases [ "seeded" ]);
  assert (String.equal selected.seed "42");
  assert (List.equal [%equal: string * string] selected.parameters [ "cycles", "100" ]);
  assert (List.is_empty selected.asic_inputs);
  let all = select_all t in
  assert (List.equal String.equal (selected_cases all) [ "directed"; "seeded" ]);
  let none = toggle_case t "seeded" in
  assert (Or_error.is_error (launch none));
  assert (Option.equal String.equal (case_id (move_case t 1)) (Some "seeded"))
;;

let%test_unit "per-launch form edits do not change the catalog's quick run inputs" =
  let t =
    update empty (Test_data.snapshot [ Test_data.suite ])
    |> fun t -> toggle_case t "directed"
  in
  let suite, defaults, digest = launch t |> Or_error.ok_exn in
  let saved = { defaults with seed = "91"; parameters = [ "cycles", "150" ] } in
  let t = save_configuration t saved in
  let _, effective, _ = launch t |> Or_error.ok_exn in
  let form = Simulation_view.Form.create ~selection:effective suite in
  let edit form value =
    match Simulation_view.Form.accept form value |> Or_error.ok_exn with
    | `Next form -> form
    | `Launch _ | `Save _ -> assert false
  in
  let form =
    edit form "directed" |> fun form -> edit form "1" |> fun form -> edit form "200"
  in
  (match Simulation_view.Form.accept form "launch" |> Or_error.ok_exn with
   | `Launch selection ->
     assert (List.equal String.equal selection.cases [ "directed" ]);
     assert (String.equal selection.seed "1");
     assert (List.equal [%equal: string * string] selection.parameters [ "cycles", "200" ])
   | `Next _ | `Save _ -> assert false);
  let _, current, current_digest = launch t |> Or_error.ok_exn in
  assert (S.Selection.equal saved current);
  assert (String.equal digest current_digest)
;;

let%test_unit "saved inputs follow the current subset and reset on suite or digest change" =
  let s = Test_data.suite in
  let other = { s with id = "other" } in
  let snapshot = Test_data.snapshot [ s; other ] in
  let t = update empty snapshot in
  let _, defaults, _ = launch t |> Or_error.ok_exn in
  let saved =
    { defaults with cases = [ "seeded" ]; seed = "91"; parameters = [ "cycles", "200" ] }
  in
  let t = save_configuration t saved in
  let selection t =
    let _, selection, _ = launch t |> Or_error.ok_exn in
    selection
  in
  assert (S.Selection.equal (selection (update t snapshot)) saved);
  let t = select_all t in
  assert (S.Selection.equal (selection t) { saved with cases = defaults.cases });
  assert (S.Selection.equal (selection (select_suite (select_suite t "other") s.id)) defaults);
  let refreshed = update t (Test_data.snapshot ~digest:"d2" [ s; other ]) in
  assert (Or_error.is_error (launch refreshed));
  assert (S.Selection.equal (selection (accept refreshed)) defaults);
  let changed = { s with default_seed = "70" } in
  assert (
    S.Selection.equal
      (selection (accept (update t (Test_data.snapshot [ changed; other ]))))
      (Simulation_view.selection changed))
;;

let%test_unit "refresh never retargets missing suite case or changed defaults" =
  let s = Test_data.suite in
  let t = update empty (Test_data.snapshot [ s ]) |> fun t -> select_case t "seeded" in
  let changed = { s with cases = [ List.hd_exn s.cases ]; default_seed = "99" } in
  let t = update t (Test_data.snapshot ~digest:"d2" [ changed ]) in
  assert (Option.equal String.equal (case_id t) (Some "seeded"));
  assert (List.mem (selected_cases t) "seeded" ~equal:String.equal);
  assert (Or_error.is_error (launch (accept t)));
  let t = toggle_case t "seeded" in
  assert (Or_error.is_error (launch t));
  let _, selected, digest = launch (accept t) |> Or_error.ok_exn in
  assert (List.equal String.equal selected.cases [ "directed" ]);
  assert (String.equal selected.seed "99" && String.equal digest "d2");
  let other = { s with id = "different" } in
  let t = update t (Test_data.snapshot ~digest:"d3" [ other ]) in
  assert (Option.equal String.equal (suite_id t) (Some "fifo"));
  assert (Option.is_none (suite t));
  assert (Or_error.is_error (launch (accept t)));
  assert (Or_error.is_ok (launch (select_suite t "different")))
;;

let%test_unit "authoritative discovery remains launchable during background refresh" =
  let snapshot = Test_data.snapshot [ Test_data.suite ] in
  let started = { snapshot with discovery_job = Some (Job_id.of_string "discovery") } in
  assert (Or_error.is_ok (launch (update empty started)));
  let t = update empty snapshot |> fun t -> toggle_case t "directed" in
  let _, defaults, _ = launch t |> Or_error.ok_exn in
  let selection = { defaults with seed = "91" } in
  let refreshing = update (begin_discovery (save_configuration t selection)) started in
  let suite, actual, digest = launch refreshing |> Or_error.ok_exn in
  assert (S.Suite.equal suite Test_data.suite);
  assert (S.Selection.equal actual selection);
  assert (String.equal digest "d1");
  assert (
    String.equal
      (List.hd_exn (rows refreshing)).text
      "Ready for explicit launch; discovery refresh in progress");
  let changed = update refreshing { started with discovery_digest = Some "d2" } in
  assert (Or_error.is_error (launch changed));
  let _, accepted, digest = launch (accept changed) |> Or_error.ok_exn in
  assert (S.Selection.equal accepted defaults);
  assert (String.equal digest "d2")
;;

let%test_unit "missing or invalid authority retains a browse-only catalog even during refresh" =
  let snapshot = Test_data.snapshot [ Test_data.suite ] in
  let t = update empty snapshot in
  let pending = { snapshot with discovery_job = Some (Job_id.of_string "discovery") } in
  List.iter
    [ begin_discovery t
    ; discovery_failed t "bad stream"
    ; invalidate t
    ; update t { pending with discovery = None }
    ; update t { pending with discovery_error = Some "invalid" }
    ; update t { pending with discovery_digest = None }
    ; update t { pending with configured = false }
    ; update t { snapshot with discovery = None; discovery_error = Some "invalid" }
    ; update t { snapshot with discovery = None }
    ; update t { snapshot with discovery_digest = None }
    ; update t { snapshot with configured = false }
    ]
    ~f:(fun t ->
      assert (List.length (visible_cases t) = 2);
      assert (Or_error.is_error (launch (accept t))));
  let changed_same_digest = { Test_data.suite with default_seed = "88" } in
  let t = update t (Test_data.snapshot [ changed_same_digest ]) in
  assert (Or_error.is_error (launch t));
  assert (Or_error.is_ok (launch (accept t)))
;;

let%test_unit "catalog cursor follows only first case line with metadata after navigation"
  =
  let cases =
    List.init 1024 ~f:(fun i : S.Case.t ->
      { id = sprintf "case-%04d" i; label = "Case label\ncontinuation" })
  in
  let suite = { Test_data.suite with cases } in
  let t =
    update empty (Test_data.snapshot [ suite ]) |> fun t -> select_case t "case-1023"
  in
  let rows = rows t in
  let selected = List.filter rows ~f:(fun r -> r.Simulation_view.selected) in
  assert (List.length selected = 1);
  assert (String.equal (List.hd_exn selected).text "> [x] case-1023 — Case label");
  assert (
    List.for_all rows ~f:(fun r ->
      (not (String.equal r.text "continuation")) || not r.selected));
  let index substring =
    List.findi rows ~f:(fun _ r -> String.is_substring r.Simulation_view.text ~substring)
    |> Option.value_exn
    |> fst
  in
  assert (index "Ready for explicit launch" < index "case-0000");
  assert (index "case-1023" < index "Default seed:");
  assert (index "Default seed:" < index "Captured discovery:")
;;
