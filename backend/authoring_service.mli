open! Core
module Authoring = Silver_protocol.Authoring

type t

(** Roots must already exist. An empty list denies every destination. *)
val create : permitted_roots:string list -> t

val controlled_recipe : string

(** Blocking and thread-safe. A session retains its most recent 128 outstanding previews;
    cancel and apply consume one preview, including failed applications. Output paths in
    previews and outcomes are relative to the destination. [bazel_project] selects the
    Bluespec recipe path for a bound preview and comes from the host's opened session,
    not from the client. Unbound IP and module previews resolve against the authorized
    destination instead. *)
val handle
  :  ?project_identity:int * int
  -> ?bazel_project:bool
  -> t
  -> Authoring.Request.t
  -> Authoring.Response.t
