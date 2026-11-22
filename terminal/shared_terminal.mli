open! Core

type t

(** One owner per Silver frontend, used on the Async scheduler. All PTYs run on
    the local frontend host. *)
val create : unit -> t

(** A Bonsai invalidation dependency for [render]. Updates are drained and
    retained even when the overlay is hidden. *)
val revision : t -> int Bonsai.t

(** [project_root] is the absolute local working directory, not a run endpoint.
    [None] selects the project's most recent number (initially 1); toggling the
    selected number hides it. Invalid numbers leave the overlay unchanged.
    The caller owns workspace/tile focus. *)
val toggle
  :  t
  -> project_root:string
  -> number:int option
  -> dimensions:Bonsai_term.Dimensions.t
  -> unit

val is_visible : t -> bool
val hide : t -> unit
val resize : t -> dimensions:Bonsai_term.Dimensions.t -> unit

(** Start the selected number again only after exit or failure. *)
val restart : t -> unit

(** Forward keyboard and paste events to the selected live shell; the caller
    handles overlay and frontend shortcuts before calling this, except while
    [is_pasting] is true: route every event here until the paste ends. *)
val input : t -> Bonsai_term.Event.t -> unit
val is_pasting : t -> bool

(** Render an opaque overlay of the given size. Does not resize the PTY. *)
val render : t -> dimensions:Bonsai_term.Dimensions.t -> Bonsai_term.View.t option

val shutdown : t -> unit Async.Deferred.t
