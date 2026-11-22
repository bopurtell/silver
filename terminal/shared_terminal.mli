open! Core

type t

type placement =
  [ `Bottom
  | `Center
  ]

type geometry =
  { x : int
  ; y : int
  ; dimensions : Bonsai_term.Dimensions.t
  }

(** One owner per Silver frontend, used on the Async scheduler. All PTYs run on
    the local frontend host. The default placement is [`Bottom]. *)
val create : unit -> t

(** A Bonsai invalidation dependency for [render]. Updates are drained and
    retained even when the overlay is hidden. *)
val revision : t -> int Bonsai.t

val placement : t -> placement

(** Move the overlay and resize the selected live PTY against the last viewport
    passed to [toggle] or [resize]. Does not change selection, focus, or process
    lifetime. If hidden, the new placement applies on the next open. *)
val set_placement : t -> placement -> unit

(** Compute the tile rectangle from the full frontend viewport, independently
    of visibility. [x] and [y] are zero-based viewport coordinates. The first
    tile row is the title; the remaining rows form the PTY grid, limited to
    Cobalt's supported size. The PTY always gets at least one row and column
    even if the viewport cannot show them. *)
val geometry : t -> dimensions:Bonsai_term.Dimensions.t -> geometry

(** Test a viewport coordinate against the whole rectangle, including its
    title row. *)
val contains : geometry -> x:int -> y:int -> bool

(** [project_root] is the absolute local working directory, not a run endpoint.
    [None] selects the project's most recent number (initially 1); toggling the
    selected number hides it. Invalid numbers leave the overlay unchanged.
    [dimensions] is the full viewport. The caller owns workspace/tile focus. *)
val toggle
  :  t
  -> project_root:string
  -> number:int option
  -> dimensions:Bonsai_term.Dimensions.t
  -> unit

val is_visible : t -> bool
val hide : t -> unit

(** Record the full viewport and resize the selected live PTY to the new
    interior. Reopening a hidden shell applies the current size to it. *)
val resize : t -> dimensions:Bonsai_term.Dimensions.t -> unit

(** Start the selected number again only after exit or failure. *)
val restart : t -> unit

(** Forward keyboard and paste events to the selected live shell; the caller
    handles overlay and frontend shortcuts before calling this, except while
    [is_pasting] is true: route every event here until the paste ends. *)
val input : t -> Bonsai_term.Event.t -> unit
val is_pasting : t -> bool

(** Render a tile-local opaque overlay using [geometry] for the given full
    viewport. Does not resize the PTY or position the tile. To retain the
    workspace around it, compute [geometry] with the same viewport and
    composite [View.zcat [View.pad ~l:x ~t:y overlay; background]]. *)
val render : t -> dimensions:Bonsai_term.Dimensions.t -> Bonsai_term.View.t option

val shutdown : t -> unit Async.Deferred.t
