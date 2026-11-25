open! Core

let marker = "dune-project"
let silver_marker = Hardcaml_workbench_project_integration.Silver_manifest.relative_path

(* Canonical absolute paths have far fewer components than this; the bound only guards
   against a pathological filesystem whose [dirname] never reaches [/]. *)
let max_levels = 4096

module Discovered = struct
  type t =
    { start : string
    ; root : string
    ; marker : string
    ; enclosing : string option
    }
  [@@deriving sexp_of]
end

let error_message error = Core_unix.Error.message error

let inspect_marker directory marker =
  let path = Filename.concat directory marker in
  match (Core_unix.stat path).st_kind with
  | S_REG -> Ok `Regular
  | _ -> Ok `Not_regular
  | exception Core_unix.Unix_error ((ENOENT | ENOTDIR), _, _) -> Ok `Absent
  | exception Core_unix.Unix_error (error, _, _) ->
    Error (sprintf "cannot inspect %s: %s" path (error_message error))
;;

let inspect directory =
  let rec loop ignored = function
    | [] -> Ok (`Absent (List.rev ignored))
    | marker :: rest ->
      (match inspect_marker directory marker with
       | Ok `Regular -> Ok (`Regular marker)
       | Ok `Absent -> loop ignored rest
       | Ok `Not_regular ->
         loop ((marker, Filename.concat directory marker) :: ignored) rest
       | Error _ as error -> error)
  in
  loop [] [ marker; silver_marker ]
;;

let parent directory =
  let parent = Filename.dirname directory in
  if String.equal parent directory then None else Some parent
;;

let rec enclosing_root directory ~levels =
  if levels >= max_levels
  then None
  else (
    match parent directory with
    | None -> None
    | Some parent ->
      (match inspect parent with
       | Ok (`Regular _) -> Some parent
       | Ok (`Absent _) -> enclosing_root parent ~levels:(levels + 1)
       (* The enclosing project is informational only; stop quietly. *)
       | Error _ -> None))
;;

let canonical_start start =
  match
    Or_error.try_with (fun () ->
      let start = Option.value_or_thunk start ~default:Sys_unix.getcwd in
      let canonical = Filename_unix.realpath start in
      canonical, (Core_unix.stat canonical).st_kind)
  with
  | Ok (canonical, S_DIR) -> Ok canonical
  | Ok (canonical, _) -> Error (sprintf "%s is not a directory" canonical)
  | Error error ->
    Error
      (sprintf
         "cannot resolve the starting directory %s: %s"
         (Option.value start ~default:"(current directory)")
         (Error.to_string_hum error))
;;

let search ?start ~explicit_flag () =
  let%bind.Result start =
    canonical_start start
    |> Result.map_error ~f:(fun message ->
      sprintf
        "project discovery failed: %s; pass %s DIR to name the project root explicitly"
        message
        explicit_flag)
  in
  let rec walk directory ~levels ~ignored =
    if levels >= max_levels
    then
      Error
        (sprintf
           "project discovery stopped after %d levels above %s; pass %s DIR"
           max_levels
           start
           explicit_flag)
    else (
      match inspect directory with
      | Error message ->
        Error
          (sprintf
             "project discovery stopped at %s while searching upward from %s: %s. An \
              unreadable ancestor is not skipped, because a nearer project could be \
              hidden there; pass %s DIR to name the project root explicitly"
             directory
             start
             message
             explicit_flag)
      | Ok (`Regular marker) ->
        Ok
          (`Found
            { Discovered.start
            ; root = directory
            ; marker
            ; enclosing = enclosing_root directory ~levels
            })
      | Ok (`Absent non_regular) ->
        let ignored = List.rev_append non_regular ignored in
        (match parent directory with
         | Some parent -> walk parent ~levels:(levels + 1) ~ignored
         | None ->
           let ignored =
             match List.rev ignored with
             | [] -> ""
             | entries ->
               entries
               |> List.map ~f:(fun (marker, path) ->
                 sprintf " (ignored non-regular %s: %s)" marker path)
               |> String.concat
           in
           Ok
             (`Missing
               ( start
               , sprintf
                   "no Dune project found and no Silver project found: neither %s nor \
                    any of its %d ancestor directories up to / contains a regular %s or \
                    %s file%s. A directory with only a dune file, or a VCS root, is not \
                    a project root. Run from inside a project or pass %s DIR"
                   start
                   levels
                   marker
                   silver_marker
                   ignored
                   explicit_flag ))))
  in
  walk start ~levels:0 ~ignored:[]
;;

let discover ?start ~explicit_flag () =
  let%bind.Result result = search ?start ~explicit_flag () in
  match result with
  | `Found root -> Ok root
  | `Missing (_, diagnostic) -> Error diagnostic
;;

let describe (discovered : Discovered.t) ~explicit_flag =
  let location =
    if String.equal discovered.start discovered.root
    then "the starting directory"
    else sprintf "nearest ancestor of %s" discovered.start
  in
  let nested =
    match discovered.enclosing with
    | None -> ""
    | Some outer ->
      sprintf
        "; it is nested inside the project at %s, which nearest-root selection did not \
         choose (pass %s %s to open that one)"
        outer
        explicit_flag
        outer
  in
  sprintf
    "discovered project root %s (%s containing a regular %s)%s"
    discovered.root
    location
    discovered.marker
    nested
;;

let explicit_root root =
  match
    Or_error.try_with (fun () ->
      if String.is_empty (String.strip root)
      then Error "root: must explicitly name an existing project directory"
      else (
        let root = Filename_unix.realpath root in
        match (Core_unix.stat root).st_kind with
        | S_DIR ->
          (match inspect root with
           | Ok (`Regular _) -> Ok root
           | Ok (`Absent _) ->
             Error
               (sprintf
                  "root: %s must directly contain a regular %s file or %s"
                  root
                  marker
                  silver_marker)
           | Error message -> Error ("root: " ^ message))
        | _ -> Error (sprintf "root: %s is not a directory" root)))
  with
  | Ok result -> result
  | Error error -> Error (Error.to_string_hum error)
;;

let resolve ~explicit ~discover:discover_requested ~explicit_flag ~discover_flag =
  match explicit, discover_requested with
  | Some _, true ->
    Error
      (sprintf
         "%s cannot be combined with %s; an explicit root bypasses upward discovery"
         discover_flag
         explicit_flag)
  | Some _, false -> Ok (explicit, None)
  | None, false -> Ok (None, None)
  | None, true ->
    let%map.Result discovered = discover ~explicit_flag () in
    Some discovered.root, Some (describe discovered ~explicit_flag)
;;
