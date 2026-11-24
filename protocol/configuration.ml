(** One build configuration a project offers for a target.

    Configurations are discovered through the project, which decides what is valid; the
    Workbench selects among them and records which one produced a job or artifact. The
    configuration's settings belong to the versioned project-driver contract. This type
    identifies and describes the configuration without reproducing its contents. *)

open! Core

type t =
  { id : Configuration_id.t
  ; target : Target_id.t
  ; name : string
  ; description : string option
  }
[@@deriving bin_io, compare, equal, sexp]
