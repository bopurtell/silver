open! Core

(** An anchor in the ordered, filtered Signals list. The current row focus is the other
    endpoint; the renderer's viewport is not part of the selection. Clear the anchor if
    the list changes or the tile loses focus. *)
type t

val start : row_count:int -> focus:int -> t option
val contains : t -> focus:int -> row:int -> bool
val length : t -> focus:int -> int

type toggle_result =
  | Toggled of Int.Set.t
  | Selection_limit
  | No_range

(** Enable the whole range unless all its signals are already enabled, in which case
    disable it. Preserve every signal outside the range. [rows] is the full filtered list
    (not just the rendered page); [id] gives the unique signal ID of each row. The final
    enabled set must fit [limit]; on failure, no change is returned. *)
val toggle
  :  t
  -> focus:int
  -> rows:'a list
  -> id:('a -> int)
  -> enabled:Int.Set.t
  -> limit:int
  -> toggle_result
