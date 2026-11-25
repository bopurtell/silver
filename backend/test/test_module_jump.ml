open! Core
open! Async
open Silver_protocol
module Jump = Silver_backend.Module_jump
open Jump.Resolution

let require condition message = if not condition then failwith message
let project = Project_id.of_string "symbols-project"
let other_project = Project_id.of_string "another-project"

let location project ?line ?column ?source_identity relative_path : Jump.Location.t =
  { project; relative_path; line; column; source_identity }
;;

module Symbol_index = struct
  type selection =
    | Alpha
    | Beta
    | Missing
  [@@deriving equal]

  let definition : Jump.Action.t = { id = "definition"; label = "Go to definition" }
  let references : Jump.Action.t = { id = "references"; label = "Find references" }
  let alpha = location project ~line:12 ~column:7 "src/alpha.ml"
  let beta = location project ~line:3 ~column:2 "src/beta.ml"
  let missing = "The index has no definition for this symbol"

  let provider ~lookup_references =
    Jump.Provider.create
      ~offer:(fun ~project:_ ~selection ->
        match selection with
        | Alpha | Beta -> [ definition; references ]
        | Missing -> [ definition ])
      ~resolve:(fun ~project ~selection ~action_id ->
        match action_id, selection with
        | "definition", Alpha -> Deferred.return (Direct { alpha with project })
        | "definition", Beta -> Deferred.return (Direct { beta with project })
        | "definition", Missing -> Deferred.return (Unavailable missing)
        | "references", (Alpha | Beta) -> lookup_references ~project ~selection
        | _ -> failwith "Resolver received an action that the module did not offer")
  ;;
end

let find_offer offers (action : Jump.Action.t) =
  List.find_exn offers ~f:(fun offer ->
    String.equal (Jump.Offer.action offer).id action.id)
;;

(* A headless frontend: no editor or filesystem, and ambiguity needs a separate choice. *)
module Recording_destination = struct
  let create () =
    let opened = ref [] in
    (fun () -> List.rev !opened), fun location -> opened := location :: !opened
  ;;

  let handle ~current ~open_location response =
    if Jump.Response.matches response current
    then (
      match Jump.Response.resolution response with
      | Direct location -> open_location location
      | Ambiguous _ | Unavailable _ -> ())
  ;;
end

let resolve_and_choose () =
  let open Deferred.Let_syntax in
  let from_live : Jump.Candidate.t =
    { label = "Working copy"; location = Symbol_index.alpha }
  in
  let from_retained : Jump.Candidate.t =
    { label = "Captured run"
    ; location =
        location
          project
          ~line:19
          ~column:5
          ~source_identity:"run-4:rtl:sha256:12ab"
          "evidence/run-4/alpha.ml"
    }
  in
  let provider =
    Symbol_index.provider ~lookup_references:(fun ~project:received ~selection ->
      require (Project_id.equal received project) "Lookup did not capture the project";
      require (Symbol_index.equal_selection selection Alpha) "Lookup got the wrong symbol";
      Deferred.return (Ambiguous [ from_live; from_retained ]))
  in
  let offers = Jump.offer provider ~project ~selection:Alpha in
  [%test_result: Jump.Action.t list]
    (List.map offers ~f:Jump.Offer.action)
    ~expect:[ Symbol_index.definition; Symbol_index.references ];
  let current = Jump.capture (find_offer offers Symbol_index.definition) in
  let known = Jump.resolve current in
  require (Deferred.is_determined known) "A known definition did not resolve immediately";
  let%bind response = known in
  let captured = Jump.Response.request response in
  [%test_result: Project_id.t] (Jump.Request.project captured) ~expect:project;
  [%test_result: Jump.Action.t]
    (Jump.Request.action captured)
    ~expect:Symbol_index.definition;
  [%test_result: Jump.Resolution.t]
    (Jump.Response.resolution response)
    ~expect:(Direct Symbol_index.alpha);
  let embedded, open_embedded = Recording_destination.create () in
  let main, open_main = Recording_destination.create () in
  Recording_destination.handle ~current ~open_location:open_embedded response;
  Recording_destination.handle ~current ~open_location:open_main response;
  [%test_result: Jump.Location.t list] (embedded ()) ~expect:[ Symbol_index.alpha ];
  [%test_result: Jump.Location.t list] (main ()) ~expect:(embedded ());
  let current = Jump.capture (find_offer offers Symbol_index.references) in
  let%bind response = Jump.resolve current in
  Recording_destination.handle ~current ~open_location:open_embedded response;
  Recording_destination.handle ~current ~open_location:open_main response;
  [%test_result: Jump.Location.t list] (embedded ()) ~expect:[ Symbol_index.alpha ];
  [%test_result: Jump.Location.t list] (main ()) ~expect:(embedded ());
  let candidates =
    match Jump.Response.resolution response with
    | Ambiguous candidates -> candidates
    | Direct _ | Unavailable _ -> failwith "References should require a candidate choice"
  in
  [%test_result: Jump.Candidate.t list] candidates ~expect:[ from_live; from_retained ];
  let chosen =
    List.find_exn candidates ~f:(fun candidate ->
      String.equal candidate.label "Captured run")
  in
  open_embedded chosen.location;
  open_main chosen.location;
  [%test_result: Jump.Location.t list]
    (embedded ())
    ~expect:[ Symbol_index.alpha; from_retained.location ];
  [%test_result: Jump.Location.t list] (main ()) ~expect:(embedded ());
  let missing = Jump.offer provider ~project ~selection:Missing in
  [%test_result: Jump.Action.t list]
    (List.map missing ~f:Jump.Offer.action)
    ~expect:[ Symbol_index.definition ];
  let current = Jump.capture (find_offer missing Symbol_index.definition) in
  let%map response = Jump.resolve current in
  Recording_destination.handle ~current ~open_location:open_embedded response;
  Recording_destination.handle ~current ~open_location:open_main response;
  [%test_result: Jump.Resolution.t]
    (Jump.Response.resolution response)
    ~expect:(Unavailable Symbol_index.missing);
  [%test_result: Jump.Location.t list]
    (embedded ())
    ~expect:[ Symbol_index.alpha; from_retained.location ];
  [%test_result: Jump.Location.t list] (main ()) ~expect:(embedded ())
;;

let overlapping_requests () =
  let open Deferred.Let_syntax in
  let alpha_started = Ivar.create () in
  let complete_alpha = Ivar.create () in
  let complete_beta = Ivar.create () in
  let provider =
    Symbol_index.provider ~lookup_references:(fun ~project:received ~selection ->
      match selection with
      | Alpha ->
        Ivar.fill_exn alpha_started received;
        let%map () = Ivar.read complete_alpha in
        Jump.Resolution.Direct { Symbol_index.alpha with project = received }
      | Beta ->
        let%map () = Ivar.read complete_beta in
        Direct { Symbol_index.beta with project = received }
      | Missing -> failwith "Missing symbols did not offer references")
  in
  let selection = ref Symbol_index.Alpha in
  let alpha_offer =
    Jump.offer provider ~project ~selection:!selection
    |> Fn.flip find_offer Symbol_index.references
  in
  let alpha_request = Jump.capture alpha_offer in
  require (not (Ivar.is_full alpha_started)) "Lookup started before resolve";
  let pending = Jump.resolve alpha_request in
  let%bind started_in = Ivar.read alpha_started in
  [%test_result: Project_id.t] started_in ~expect:project;
  require (not (Deferred.is_determined pending)) "Alpha did not wait for its evidence";
  selection := Beta;
  let beta_offer =
    Jump.offer provider ~project ~selection:!selection
    |> Fn.flip find_offer Symbol_index.references
  in
  let beta_request = Jump.capture beta_offer in
  let pending_beta = Jump.resolve beta_request in
  let opened, open_location = Recording_destination.create () in
  Ivar.fill_exn complete_alpha ();
  let%bind alpha_response = pending in
  [%test_result: Jump.Resolution.t]
    (Jump.Response.resolution alpha_response)
    ~expect:(Direct Symbol_index.alpha);
  require (Jump.Response.matches alpha_response alpha_request) "Alpha lost its request";
  require
    (not (Jump.Response.matches alpha_response beta_request))
    "Alpha matched Beta's newer invocation";
  require
    (not (Jump.Response.matches alpha_response (Jump.capture alpha_offer)))
    "Alpha matched a fresh invocation of the exact same offer";
  require (not (Deferred.is_determined pending_beta)) "Beta did not wait for its evidence";
  Recording_destination.handle ~current:beta_request ~open_location alpha_response;
  [%test_result: Jump.Location.t list] (opened ()) ~expect:[];
  Ivar.fill_exn complete_beta ();
  let%map beta_response = pending_beta in
  [%test_result: Jump.Resolution.t]
    (Jump.Response.resolution beta_response)
    ~expect:(Direct Symbol_index.beta);
  Recording_destination.handle ~current:beta_request ~open_location beta_response;
  [%test_result: Jump.Location.t list] (opened ()) ~expect:[ Symbol_index.beta ]
;;

let independent_provider () =
  let open Deferred.Let_syntax in
  (* Different selection type and the same action ID: dispatch must use this module. *)
  let resolve ~project ~selection ~action_id =
    require (String.equal action_id Symbol_index.definition.id) "Wrong action ID";
    Deferred.return
      (Jump.Resolution.Direct (location project ~line:selection "notes/guide.md"))
  in
  let provider =
    Jump.Provider.create
      ~offer:(fun ~project:_ ~selection:_ -> [ Symbol_index.definition ])
      ~resolve
  in
  let request =
    Jump.offer provider ~project:other_project ~selection:9
    |> Fn.flip find_offer Symbol_index.definition
    |> Jump.capture
  in
  let%map response = Jump.resolve request in
  [%test_result: Jump.Resolution.t]
    (Jump.Response.resolution response)
    ~expect:(Direct (location other_project ~line:9 "notes/guide.md"))
;;

let () =
  Thread_safe.block_on_async_exn (fun () ->
    let open Deferred.Let_syntax in
    let tests =
      let%bind () = resolve_and_choose () in
      let%bind () = overlapping_requests () in
      independent_provider ()
    in
    match%map Clock.with_timeout (Time_float.Span.of_sec 5.) tests with
    | `Result () -> ()
    | `Timeout -> failwith "The headless module jump tests did not complete")
;;
