open! Core

exception Invalid of string
exception Changed of string

type root
type dir
type snapshot [@@deriving equal, sexp_of]

val root : string -> root
val select : root list -> string -> root * string list
val visit : root -> string list -> (dir -> snapshot -> 'a) -> 'a
val materialize : dir -> snapshot -> (dir -> 'a) -> 'a
val write : dir -> name:string -> contents:string -> on_create:(unit -> unit) -> unit
