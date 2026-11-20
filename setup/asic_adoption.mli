open! Core

(** Check that the open Dune project has no common or legacy ASIC configuration. *)
val check : root:string -> (unit, string) Result.t

(** Write the schema-1 ASIC configuration for an already-built design executable. Relative
    inputs are resolved against [root]. No executable is launched. *)
val adopt : root:string -> executable:string -> (unit, string) Result.t
