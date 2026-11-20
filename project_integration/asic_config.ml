open! Core

(** Resolved opt-in config. Paths are retained verbatim, including symlink-parent/.. . *)
type t =
  { schema_version : int
  ; project_executable : string
  ; provider_executable : string
  ; results_root : string
  ; toolchain : string
  ; python : string option
  ; support_tools : string option
  ; pdk_root : string option
  ; stage_timeout_seconds : int option
  }
[@@deriving compare, equal, sexp]

let filename = "hardcaml-workbench-asic.sexp"

let validate t =
  if t.schema_version <> 1 then failwith "Unsupported ASIC configuration schema";
  List.iter
    ([ t.project_executable; t.provider_executable; t.results_root; t.toolchain ]
     @ List.filter_opt [ t.python; t.support_tools; t.pdk_root ])
    ~f:(fun path ->
      if (not (Filename.is_absolute path)) || String.contains path '\000'
      then failwith "ASIC executable and resource paths must be absolute");
  Option.iter t.stage_timeout_seconds ~f:(fun n ->
    if n <= 0 then failwith "stage_timeout_seconds must be positive");
  t
;;

let parse_string text =
  Or_error.try_with (fun () -> t_of_sexp (Sexp.of_string text) |> validate)
;;

(* Only an absent field opts in to discovery; malformed or duplicate fields
   still go through the normal record decoder. *)
let parse_project text =
  Or_error.try_with (fun () ->
    match Sexp.of_string text with
    | List fields
      when not (List.exists fields ~f:(function
        | Sexp.List (Atom "provider_executable" :: _) -> true
        | _ -> false)) ->
      let resolve path =
        Sexp.List (Sexp.List [ Atom "provider_executable"; Atom path ] :: fields)
        |> t_of_sexp |> validate
      in
      `Discover resolve
    | sexp -> `Explicit (t_of_sexp sexp |> validate))
;;
