open! Core

exception Invalid of string
exception Changed of string
exception Unsupported_bluespec_project

type root
type dir
type snapshot [@@deriving equal, sexp_of]

val root : string -> root
val select : root list -> string -> root * string list
val source_project : root -> string list -> (int * int) * bool

type addition =
  | Ip of string
  | Module of string list * string
  | Bazel_ip of string
  | Bazel_module of string list * string
  | Flow of
      { inputs : string list list
      ; output : string list option
      }

val input_text : snapshot -> string list -> string option
val module_directory : string -> string list
val manual_modules : snapshot -> bool
val bazel_library : snapshot -> string list -> string * string

val visit
  :  ?existing:string
  -> ?addition:addition
  -> ?library:string list
  -> ?configs_required:bool
  -> root
  -> string list
  -> (dir -> snapshot -> 'a)
  -> 'a

val catalog : string
val design_dir : string -> string
val catalog_text : snapshot -> string option
val configs_absent : snapshot -> bool
val matches_project : snapshot -> int * int -> bool
val project_identity : snapshot -> int * int
val library_text : snapshot -> string list
val publish_catalog : dir -> snapshot -> string -> on_create:(string -> unit) -> unit
val materialize : on_mkdir:(string -> unit) -> dir -> snapshot -> (dir -> 'a) -> 'a

(** Publish a plan whose destination-relative paths were validated during preview. Only
    creates entries, with exclusive creation for every file and directory. Callbacks
    record creations immediately, including a partially written file. *)
val publish
  :  dir
  -> snapshot
  -> Silver_protocol.Authoring.File.t list
  -> on_mkdir:(string -> unit)
  -> on_create:(string -> unit)
  -> unit
