(** Read only the catalog-selected owner's compiled declaration. Neither the active launch
    nor a client-supplied source directory participates in authoring. *)
open! Core

open Hardcaml_workbench_protocol.Authoring
module D = Authoring_destination
module P = Asic_public
module S = Authoring_starter

exception Invalid_operation of string

let invalid text = raise (Invalid_operation text)
let required what = Option.value_or_thunk ~default:(fun () -> invalid what)
let strings j = List.map (P.list j) ~f:P.text

let scalar = function
  | `Bool b -> Bool.to_string b
  | `String s -> s
  | _ -> invalid "Expected an explicit enum or boolean value"
;;

let query_recipes () =
  let j = S.run S.program [ "describe-flow-authoring" ] |> P.decode in
  P.require
    (Poly.equal (P.field "schema_version" j) (`Int 1))
    "Unsupported recipe descriptor";
  List.map
    (P.list (P.field "recipes" j))
    ~f:(fun r -> P.text (P.field "id" r), strings (P.field "endpoints" r))
;;

let flow_info catalog =
  ignore (P.flow_catalog catalog : _ * _);
  let descriptors = P.list (P.field "parameter_descriptors" catalog) in
  let descriptor key =
    List.find descriptors ~f:(fun d -> String.equal key (P.text (P.field "key" d)))
    |> required ("Missing compiled parameter descriptor: " ^ key)
  in
  let flows = P.field "declaration" catalog |> P.field "entries" |> P.list in
  List.map flows ~f:(fun entry ->
    let methodology = P.field "methodology" entry in
    let parameters =
      strings (P.field "configurable" methodology)
      |> List.map ~f:(fun key ->
        key, List.map (P.list (P.field "allowed_values" (descriptor key))) ~f:scalar)
    in
    let profiles =
      List.map
        (P.list (P.field "profiles" entry))
        ~f:(fun p ->
          ( P.text (P.field "id" p)
          , List.map
              (P.list (P.field "assignments" p))
              ~f:(fun a -> P.text (P.field "key" a), scalar (P.field "value" a)) ))
    in
    { Flow_info.id = P.text (P.field "id" methodology); parameters; profiles })
;;

type context =
  { root : D.root
  ; components : string list
  ; owner : Owner.t
  ; project_identity : int * int
  ; home : string list
  ; standard : bool
  ; manifest : string
  ; catalog : Yojson.Safe.t
  ; recipes : (string * string list) list
  ; flows : Flow_info.t list
  ; recheck : unit -> unit
  }

let manifest_path = [ D.catalog ]

let load ~project_identity roots (owner : Owner.t) =
  let root, components = D.select roots owner.destination in
  let manifest =
    D.visit
      ~addition:(Flow { inputs = [ manifest_path ]; output = None })
      root
      components
      (fun _ s ->
        if not (D.matches_project s project_identity)
        then raise (D.Invalid "Open project directory was replaced");
        D.input_text s manifest_path
        |> required "Owner requires a registered chip catalog")
  in
  let _, _, entries =
    Authoring_chip.recognized_catalog manifest |> required "Invalid chip catalog"
  in
  let target =
    List.Assoc.find entries owner.chip ~equal:String.equal
    |> required ("Unknown owner: " ^ owner.chip)
  in
  let parts = D.module_directory target in
  let home, standard =
    match parts with
    | [ dir; "project.exe" ] when String.equal dir (D.design_dir owner.chip) ->
      [ dir ], true
    | [ "asics"; chip; "cli"; "chip.exe" ] when String.equal chip owner.chip ->
      [ "asics"; chip ], true
    | _ -> List.drop_last_exn parts, false
  in
  let exe = Filename.concat owner.destination ("_build/default/" ^ target) in
  let identity () =
    if not (String.equal (Filename_unix.realpath exe) exe)
    then invalid "Compiled owner path is not a plain build output";
    let s = Core_unix.Ns_precision.stat exe in
    if not (Poly.equal s.st_kind S_REG) then invalid "Expected compiled owner executable";
    s.st_dev, s.st_ino, s.st_ctime
  in
  let before =
    try identity () with
    | Core_unix.Unix_error (ENOENT, _, _) ->
      invalid ("Build owner '" ^ owner.chip ^ "' first: dune build " ^ target)
  in
  let recheck () =
    if not (Poly.equal before (identity ()))
    then raise (D.Changed "Compiled owner changed since preview")
  in
  let catalog =
    S.run
      ~working_dir:owner.destination
      exe
      [ "flow"; "list"; "--chip"; owner.chip; "--json" ]
    |> P.decode
  in
  recheck ();
  { root
  ; components
  ; owner
  ; project_identity
  ; home
  ; standard
  ; manifest
  ; catalog
  ; recipes = query_recipes ()
  ; flows = flow_info catalog
  ; recheck
  }
;;

let describe c =
  { Owner_description.flows = c.flows
  ; recipes = List.map c.recipes ~f:fst
  ; endpoints =
      List.concat_map c.recipes ~f:snd |> List.stable_dedup ~compare:String.compare
  }
;;

let check_id id =
  if (not (Authoring_chip.valid_name id)) || String.length id > 64
  then invalid "Invalid authoring ID"
;;

let renderer_text j =
  let text = P.text j in
  if String.contains text '\000' || not (Stdlib.String.is_valid_utf_8 text)
  then failwith "Expected UTF-8 text in the provider descriptor";
  text
;;

let plan c request =
  let owner_dir = if List.is_empty c.home then "." else String.concat ~sep:"/" c.home in
  let flows = c.home @ [ "flows" ] in
  let dune = flows @ [ "dune" ] in
  let command, recipe, flow, profile, extra, entry, source_input, output, name =
    match (request : Request.t) with
    | New_flow { name; recipe; endpoints; initial_profile; _ } ->
      if List.exists c.flows ~f:(fun f -> String.equal f.id name)
      then invalid ("Duplicate flow ID " ^ name);
      let supported =
        List.Assoc.find c.recipes recipe ~equal:String.equal
        |> required "Unknown provider recipe"
      in
      let endpoints = if List.is_empty endpoints then supported else endpoints in
      ( "render-flow"
      , new_flow_recipe
      , name
      , initial_profile
      , [ "recipe", `String recipe
        ; "endpoints", `List (List.map endpoints ~f:(fun e -> `String e))
        ]
      , None
      , None
      , flows @ [ "flow_" ^ name ^ ".ml" ]
      , name )
    | Duplicate_profile { name; source; edits; flow; _ } ->
      check_id source;
      let f =
        List.find c.flows ~f:(fun f -> String.equal f.id flow)
        |> required "Unknown compiled flow"
      in
      if not (List.Assoc.mem f.profiles source ~equal:String.equal)
      then invalid "Unknown compiled source profile";
      if List.Assoc.mem f.profiles name ~equal:String.equal
      then invalid ("Duplicate profile ID " ^ name);
      if List.contains_dup (List.map edits ~f:fst) ~compare:String.compare
      then invalid "Duplicate edit key";
      let edits =
        List.map edits ~f:(fun (key, value) ->
          let allowed =
            List.Assoc.find f.parameters key ~equal:String.equal
            |> required ("Parameter not configurable: " ^ key)
          in
          if String.is_empty value
          then key, `Null
          else (
            if not (List.mem allowed value ~equal:String.equal)
            then invalid ("Unsupported value for " ^ key);
            let desc =
              List.find_exn
                (P.list (P.field "parameter_descriptors" c.catalog))
                ~f:(fun d -> String.equal key (P.text (P.field "key" d)))
            in
            ( key
            , match P.text (P.field "type" desc) with
              | "boolean" -> `Bool (Bool.of_string value)
              | "enum" -> `String value
              | _ -> invalid "Unknown parameter type" )))
      in
      ( "render-profile"
      , duplicate_profile_recipe
      , flow
      , name
      , [ "source_profile", `String source; "edits", `Assoc edits ]
      , Some (flows @ [ "flow_" ^ flow ^ ".ml" ])
      , Some (flows @ [ flow; "profiles"; source ^ ".ml" ])
      , flows @ [ flow; "profiles"; name ^ ".ml" ]
      , name )
    | _ -> assert false
  in
  List.iter [ flow; profile ] ~f:check_id;
  let inputs =
    manifest_path
    ::
    (if c.standard
     then (dune :: Option.to_list entry) @ Option.to_list source_input
     else [])
  in
  let snapshot output =
    let addition = D.Flow { inputs; output } in
    let s = D.visit ~addition c.root c.components (fun _ s -> s) in
    if (not (D.matches_project s c.project_identity))
       || not (Option.equal String.equal (D.input_text s manifest_path) (Some c.manifest))
    then raise (D.Changed "Owner catalog changed");
    addition, s
  in
  let _, first = snapshot None in
  let registered s =
    let marked path marker =
      D.input_text s path
      |> Option.exists ~f:(fun text ->
        List.mem (String.split_lines text) marker ~equal:String.equal)
    in
    c.standard
    && marked dune "; hardcaml-asic flow collection v1"
    && Option.for_all entry ~f:(fun path ->
      marked path "(* hardcaml-asic profile directory v1 *)")
  in
  let registered = registered first in
  let addition, s = snapshot (Option.some_if registered output) in
  List.iter inputs ~f:(fun path ->
    if not (Option.equal String.equal (D.input_text first path) (D.input_text s path))
    then invalid "Owner sources changed");
  let payload =
    `Assoc
      ([ "owner", `String owner_dir
       ; "registered", `Bool registered
       ; "catalog", c.catalog
       ; "flow_id", `String flow
       ; "profile_id", `String profile
       ]
       @ extra)
  in
  let reply = S.run S.program [ command; Yojson.Safe.to_string payload ] |> P.decode in
  let manual =
    match P.field "manual_registration" reply with
    | `Bool b -> b
    | _ -> invalid "Missing registration mode"
  in
  if Bool.equal registered manual then invalid "Unexpected registration mode";
  let expected = String.concat ~sep:"/" output in
  let files =
    match P.list (P.field "files" reply) with
    | [] when manual -> []
    | [ f ] when registered && String.equal expected (P.text (P.field "path" f)) ->
      [ { File.path = expected; contents = renderer_text (P.field "contents" f) } ]
    | _ -> invalid "Unexpected flow renderer output path"
  in
  P.require
    (Poly.equal (P.field "schema_version" reply) (`Int 1))
    "Unsupported renderer version";
  let registration =
    { Registration.path = (if registered then String.concat ~sep:"/" dune else owner_dir)
    ; manual
    ; snippet =
        (if manual
         then renderer_text (P.field "snippet" reply)
         else "Creating the module registers it on the next successful owner build.")
    }
  in
  let op =
    { Operation.target =
        { destination = c.owner.destination
        ; project = Some c.owner.project
        ; object_id = Some c.owner.chip
        }
    ; recipe
    ; name
    }
  in
  c.recheck ();
  ( op
  , addition
  , s
  , files
  , registration
  , P.text (P.field "provider" reply)
  , P.text (P.field "version" reply) )
;;
