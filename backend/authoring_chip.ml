open! Core
open Hardcaml_workbench_protocol.Authoring
module D = Authoring_destination

let fields keys = function
  | `Assoc pairs
    when List.equal
           String.equal
           (List.sort keys ~compare:String.compare)
           (List.sort (List.map pairs ~f:fst) ~compare:String.compare) ->
    fun key -> List.Assoc.find_exn pairs key ~equal:String.equal
  | _ -> failwith "Unrecognized fields"
;;

(* Yojson also accepts comments and bare field names. Decline to rewrite those extensions;
   enforce the shallow string/integer schema before building a tree. *)
let parse_object text =
  let quoted = ref false
  and escaped = ref false
  and depth = ref 0 in
  String.iter text ~f:(fun c ->
    if !quoted
    then (
      if !escaped
      then escaped := false
      else if Char.equal c '\\'
      then escaped := true
      else if Char.equal c '"'
      then quoted := false)
    else (
      match c with
      | '"' -> quoted := true
      | '{' | '[' ->
        Int.incr depth;
        if !depth > 3 then failwith "Nested object"
      | '}' | ']' -> Int.decr depth
      | '0' .. '9' | ':' | ',' | ' ' | '\n' | '\r' | '\t' -> ()
      | _ -> failwith "Expected JSON object"));
  Yojson.Basic.from_string text
;;

let valid_name s =
  (not (String.is_empty s))
  && Char.is_lowercase s.[0]
  && String.for_all s ~f:(function
    | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
    | _ -> false)
;;

(* Only the canonical wrapped, single-library WB-079 layout has a known source inventory.
   A chip-interface declaration is the IP author's explicit contract. *)
let library_arguments snapshot ~directory ~mapping =
  let error () =
    failwith
      "Expected declared WB-079 combinational Block.create library with \
       ui_in:uo_out:comb8 mapping"
  in
  let name =
    match D.module_directory directory with
    | [ "ip"; name ] when valid_name name && not (String.contains name '-') ->
      "ip_" ^ name
    | _ -> error ()
  in
  (match D.library_text snapshot with
   | dune :: declaration :: implementation :: interfaces ->
     let expected_dune = sprintf "(library (name %s) (libraries hardcaml))" name in
     if (not
           (List.equal
              Sexp.equal
              (Sexp.of_string_many dune)
              [ Sexp.of_string expected_dune ]))
        || String.is_empty (String.strip implementation)
        || not (String.equal mapping "ui_in:uo_out:comb8")
     then error ();
     let field =
       fields
         [ "schema_version"; "library"; "entrypoint"; "mapping"; "clock"; "reset" ]
         (parse_object declaration)
     in
     if not
          (Poly.equal (field "schema_version") (`Int 1)
           && List.for_all
                [ "library", name
                ; "entrypoint", "Block.create"
                ; "mapping", mapping
                ; "clock", "unused"
                ; "reset", "unused"
                ]
                ~f:(fun (key, value) -> Poly.equal (field key) (`String value)))
     then error ();
     (* Check the actual public OCaml type, not just the author's declaration. -i
        typechecks frozen text; it does not link, run the IP, or evaluate the selected
        project's Dune rules. The compilation unit is host-owned. *)
     let annotation =
       match interfaces with
       | [] -> ""
       | [ mli ] -> ": sig\n" ^ mli ^ "\nend"
       | _ -> error ()
     in
     let path = Filename_unix.temp_file "silver_chip_check_" ".ml" in
     Exn.protect
       ~finally:(fun () -> Core_unix.unlink path)
       ~f:(fun () ->
         Out_channel.write_all
           path
           ~data:
             ("module Block "
              ^ annotation
              ^ " = struct\n"
              ^ implementation
              ^ "\nend\nlet _ : Hardcaml.Signal.t -> Hardcaml.Signal.t = Block.create\n");
         ignore
           (Authoring_starter.run
              "ocamlfind"
              [ "ocamlc"; "-package"; "hardcaml"; "-i"; "-impl"; path ]
            : string))
   | _ -> error ());
  [ "--library"; name; "--mapping"; mapping ]
;;

let recognized_catalog text =
  let string = function
    | `String s -> s
    | _ -> failwith "Expected string"
  in
  Option.try_with (fun () ->
    let field =
      fields [ "schema_version"; "default_target"; "targets" ] (parse_object text)
    in
    if not (Poly.equal (field "schema_version") (`Int 1)) then failwith "version";
    let default = string (field "default_target") in
    let entries =
      match field "targets" with
      | `List xs -> xs
      | _ -> failwith "targets"
    in
    let ids =
      List.map entries ~f:(fun item ->
        let get = fields [ "id"; "executable" ] item in
        let id = string (get "id")
        and path = string (get "executable") in
        if not
             (valid_name id
              && String.is_suffix path ~suffix:".exe"
              && String.for_all path ~f:(fun c ->
                Char.to_int c >= 32 && Char.to_int c <> 127 && not (Char.equal c '\\'))
              && List.for_all (String.split path ~on:'/') ~f:(fun p ->
                not (List.mem [ ""; "."; ".."; "_build" ] p ~equal:String.equal)))
        then failwith "entry";
        id, path)
    in
    if List.contains_dup (List.map ids ~f:fst) ~compare:String.compare
       || not (List.Assoc.mem ids default ~equal:String.equal)
    then failwith "default/ids";
    default, entries, ids)
;;

let catalog_plan snapshot ~register ~name ~target =
  let entry = `Assoc [ "id", `String name; "executable", `String target ] in
  let state =
    match D.catalog_text snapshot with
    | None -> Some (name, [], [])
    | Some text -> recognized_catalog text
  in
  Option.iter state ~f:(fun (_, _, ids) ->
    if List.exists ids ~f:(fun (id, path) ->
         String.equal id name || String.equal path target)
    then raise (D.Invalid "Chip target name or executable already registered"));
  if not register
  then None, None
  else (
    let contents =
      Option.map state ~f:(fun (default, entries, _) ->
        Yojson.Basic.pretty_to_string
          (`Assoc
            [ "schema_version", `Int 1
            ; "default_target", `String default
            ; "targets", `List (entries @ [ entry ])
            ])
        ^ "\n")
    in
    ( Some
        { Registration.path = D.catalog
        ; snippet = Yojson.Basic.to_string entry
        ; manual = Option.is_none contents
        }
    , contents ))
;;
