open! Core

exception Invalid of string
exception Changed of string

type root
type dir
type snapshot [@@deriving equal, sexp_of]

val root : string -> root
val select : root list -> string -> root * string list
val visit : ?existing:string -> root -> string list -> (dir -> snapshot -> 'a) -> 'a
val catalog : string
val design_dir : string -> string
val catalog_exists : snapshot -> bool
val materialize : on_mkdir:(string -> unit) -> dir -> snapshot -> (dir -> 'a) -> 'a

(** Publish a plan whose destination-relative paths were validated during preview. Only
    creates entries, with exclusive creation for every file and directory. Callbacks
    record creations immediately, including a partially written file. *)
val publish
  :  dir
  -> snapshot
  -> Hardcaml_workbench_protocol.Authoring.File.t list
  -> on_mkdir:(string -> unit)
  -> on_create:(string -> unit)
  -> unit
