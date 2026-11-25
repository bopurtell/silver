open! Core
open Silver_protocol

module Location = Silver_backend.Module_jump.Location

let parse ~project text =
  let number text =
    if not (String.is_empty text) && String.for_all text ~f:Char.is_digit
    then Some (Or_error.try_with (fun () -> Int.of_string text))
    else None
  in
  let suffix text =
    Option.bind (String.rsplit2 text ~on:':') ~f:(fun (prefix, field) ->
      Option.map (number field) ~f:(fun field -> prefix, field))
  in
  let open Or_error.Let_syntax in
  let%bind relative_path, line, column =
    match suffix text with
    | None -> Ok (text, None, None)
    | Some (prefix, field) ->
      let%bind field = field in
      (match suffix prefix with
       | None -> Ok (prefix, Some field, None)
       | Some (path, line) ->
         let%map line = line in
         path, Some line, Some field)
  in
  if String.is_empty relative_path
     || not (Filename.is_relative relative_path)
     || List.mem (String.split relative_path ~on:'/') ".." ~equal:String.equal
  then Or_error.error_string "Enter a project-relative file path"
  else if List.exists (List.filter_opt [ line; column ]) ~f:(fun n -> n < 1)
  then Or_error.error_string "Line and column must be one-based"
  else Ok { Location.project; relative_path; line; column; source_identity = None }
;;

let%test_unit "path, line-only, and positioned editor actions" =
  let project = Project_id.of_string "local-project" in
  let parse raw = parse ~project raw |> Or_error.ok_exn in
  let path = parse "src/long name.ml" in
  assert (String.equal path.relative_path "src/long name.ml");
  assert (Option.is_none path.line);
  assert (Option.equal Int.equal (parse "src/a.ml:12").line (Some 12));
  let position = parse "src/a:b.ml:12:4" in
  assert (String.equal position.relative_path "src/a:b.ml");
  assert (Option.equal Int.equal position.line (Some 12));
  assert (Option.equal Int.equal position.column (Some 4))
;;

let%test_unit "reject invalid paths and coordinates" =
  let project = Project_id.of_string "local-project" in
  List.iter [ "/etc/passwd"; "../outside"; "a:1:0"; "a:0"; ":1" ] ~f:(fun raw ->
    assert (Result.is_error (parse ~project raw)))
;;
