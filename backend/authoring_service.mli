open! Core
module Authoring = Hardcaml_workbench_protocol.Authoring

type t

(** Roots must already exist. An empty list denies every destination. *)
val create : permitted_roots:string list -> t

val controlled_recipe : string

(** Blocking and thread-safe. A session retains its most recent 128 outstanding previews;
    cancel and apply consume one preview, including failed applications. Output paths in
    previews and outcomes are relative to the destination. *)
val handle
  :  ?project_identity:int * int
  -> t
  -> Authoring.Request.t
  -> Authoring.Response.t
