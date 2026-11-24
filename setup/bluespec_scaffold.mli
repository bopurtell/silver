open! Core

(** Create editable Bluespec Classic starter sources and config at [destination]. Existing
    files are never replaced. Python is resolved from the caller's PATH, but neither
    Python nor any build tool is executed. *)
val create : destination:string -> (string, string) Result.t
