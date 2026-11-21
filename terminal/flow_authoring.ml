open! Core
open Hardcaml_workbench_protocol

(* The owner is data carried by the wizard, independent of launch selection. *)
type intent =
  | Create
  | Copy of (string * string) option

type methodology =
  { chip : string
  ; recipe : string
  ; offered : string list
  ; endpoints : string list
  }

type profile =
  { chip : string
  ; flow : Authoring.Flow_info.t
  ; source : string
  ; edits : (string * string) list
  }

type draft =
  | Methodology of methodology * string
  | Profile of profile

type field =
  | Owner of intent
  | Initial of methodology
  | Value of profile * string

type step =
  | Describe of string * intent
  | Recipes of string * Authoring.Owner_description.t
  | Sources of string * Authoring.Owner_description.t
  | Endpoints of methodology
  | Assignments of profile
  | Values of profile * string * string list
  | Input of field
  | Name of draft

let owner = function
  | Methodology (m, _) -> m.chip
  | Profile p -> p.chip
;;

let kind = function
  | Methodology _ -> "New Flow"
  | Profile _ -> "Duplicate Profile"
;;

let summary = function
  | Methodology (m, initial) ->
    [ "Methodology recipe: " ^ m.recipe
    ; "Endpoints: " ^ String.concat ~sep:", " m.endpoints
    ; "Initial profile: " ^ initial
    ]
  | Profile p ->
    [ "Copy explicit assignments from: " ^ p.flow.id ^ "/" ^ p.source ]
    @ List.map p.edits ~f:(fun (key, v) ->
      key ^ " = " ^ if String.is_empty v then "(methodology default)" else v)
;;

let field_prompt = function
  | Owner _ -> "Enter owner chip ID"
  | Initial m -> "Initial profile ID · owner: " ^ m.chip
  | Value (p, key) -> key ^ " · " ^ p.chip ^ "/" ^ p.flow.id
;;

let set p key value =
  Assignments { p with edits = List.Assoc.add p.edits ~equal:String.equal key value }
;;

let accept field text =
  let text = String.strip text in
  if String.is_empty text then failwith "Enter a value";
  match field with
  | Owner intent -> Describe (text, intent)
  | Initial m -> Name (Methodology (m, text))
  | Value (p, key) -> set p key text
;;

let after_describe chip intent (d : Authoring.Owner_description.t) =
  match intent with
  | Create -> Ok (Recipes (chip, d))
  | Copy None -> Ok (Sources (chip, d))
  | Copy (Some (id, source)) ->
    (match List.find d.flows ~f:(fun f -> String.equal f.id id) with
     | Some flow when List.Assoc.mem flow.profiles source ~equal:String.equal ->
       Ok (Assignments { chip; flow; source; edits = [] })
     | _ ->
       Error ("Source profile unavailable: " ^ String.concat ~sep:"/" [ chip; id; source ]))
;;

let owner_choices ~chips ~preferred intent =
  let chips =
    Option.to_list preferred
    @ List.filter chips ~f:(fun c -> not (Option.exists preferred ~f:(String.equal c)))
  in
  ( ("Choose owner chip · "
     ^
     match intent with
     | Create -> "New Flow"
     | Copy _ -> "Duplicate Profile")
  , List.map chips ~f:(fun chip -> "Owner: " ^ chip, Describe (chip, intent))
    @ [ "Enter another chip ID…", Input (Owner intent) ] )
;;

let choices = function
  | Recipes (chip, d) ->
    ( "Choose methodology recipe · owner: " ^ chip
    , List.map d.recipes ~f:(fun recipe ->
        recipe, Endpoints { chip; recipe; offered = d.endpoints; endpoints = d.endpoints })
    )
  | Sources (chip, d) ->
    ( "Choose source profile · owner: " ^ chip
    , List.concat_map d.flows ~f:(fun flow ->
        List.map flow.profiles ~f:(fun (source, _) ->
          flow.id ^ "/" ^ source, Assignments { chip; flow; source; edits = [] })) )
  | Endpoints m ->
    ( "Choose endpoints · owner: " ^ m.chip
    , (if List.is_empty m.endpoints
       then []
       else [ "Next: initial profile…", Input (Initial m) ])
      @ List.map m.offered ~f:(fun endpoint ->
        let included = List.mem m.endpoints endpoint ~equal:String.equal in
        ( (if included then "[x] " else "[ ] ") ^ endpoint
        , Endpoints
            { m with
              endpoints =
                List.filter m.offered ~f:(fun e ->
                  if String.equal e endpoint
                  then not included
                  else List.mem m.endpoints e ~equal:String.equal)
            } )) )
  | Assignments p ->
    let copied = List.Assoc.find_exn p.flow.profiles ~equal:String.equal p.source in
    ( "Copy explicit settings · " ^ String.concat ~sep:"/" [ p.chip; p.flow.id; p.source ]
    , ("Next: new profile ID…", Name (Profile p))
      :: List.map p.flow.parameters ~f:(fun (key, values) ->
        let value =
          Option.first_some
            (List.Assoc.find p.edits key ~equal:String.equal)
            (List.Assoc.find copied key ~equal:String.equal)
        in
        ( (key
           ^ " = "
           ^
           match value with
           | None | Some "" -> "(methodology default)"
           | Some v -> v)
        , Values (p, key, values) )) )
  | Values (p, key, values) ->
    ( "Choose " ^ key ^ " · owner: " ^ p.chip
    , ("Use methodology default", set p key "")
      ::
      (if List.is_empty values
       then [ "Enter value…", Input (Value (p, key)) ]
       else List.map values ~f:(fun v -> v, set p key v)) )
  | Input _ | Describe _ | Name _ -> invalid_arg "Not a choice page"
;;

let request draft ~project ~destination ~name : Authoring.Request.t =
  let owner : Authoring.Owner.t = { project; destination; chip = owner draft } in
  match draft with
  | Methodology (m, initial_profile) ->
    New_flow { owner; name; recipe = m.recipe; endpoints = m.endpoints; initial_profile }
  | Profile p ->
    Duplicate_profile
      { owner; name; flow = p.flow.id; source = p.source; edits = p.edits }
;;

let%test_unit "contextual duplication is bound to its exact owner and copies only edit \
               deltas"
  =
  let flow : Authoring.Flow_info.t =
    { id = "standard"
    ; profiles = [ "balanced", [ "SYNTH", "area" ] ]
    ; parameters = [ "SYNTH", [ "area"; "delay" ]; "CLOCK", [ "on"; "off" ] ]
    }
  in
  let d : Authoring.Owner_description.t =
    { recipes = []; endpoints = []; flows = [ flow ] }
  in
  assert (Result.is_error (after_describe "memory" (Copy (Some ("standard", "absent"))) d));
  let step =
    after_describe "memory" (Copy (Some ("standard", "balanced"))) d
    |> Result.ok_or_failwith
  in
  let take step title =
    List.Assoc.find_exn (snd (choices step)) ~equal:String.equal title
  in
  let draft =
    match
      take
        (take (take step "SYNTH = area") "Use methodology default")
        "Next: new profile ID…"
    with
    | Name d -> d
    | _ -> assert false
  in
  match
    request
      draft
      ~name:"trial"
      ~project:(Project_id.of_string "project")
      ~destination:"/root"
  with
  | Duplicate_profile { owner; name; flow; source; edits } ->
    assert (
      String.equal owner.chip "memory"
      && String.equal flow "standard"
      && String.equal name "trial"
      && String.equal source "balanced");
    assert ([%equal: (string * string) list] edits [ "SYNTH", "" ])
  | _ -> assert false
;;
