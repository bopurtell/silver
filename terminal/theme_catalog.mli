(** Packed 24-bit terminal color, [0xRRGGBB]. *)
type rgb = int

(** Extra role-specific text colors for monitor-inspired themes in Vivid mode. *)
type monitor_inks =
  { selected : rgb
  ; running : rgb
  ; search_match : rgb
  }

type palette =
  { background : rgb
  ; foreground : rgb
  ; surface : rgb
  ; card : rgb
  ; selection : rgb
  ; muted : rgb
  ; border : rgb
  ; accent : rgb
  ; selective : rgb
  ; metric : rgb
  ; success : rgb
  ; warning : rgb
  ; failure : rgb
  ; heading : rgb
  ; monitor : monitor_inks option
  }

type t

val key : t -> string
val label : t -> string
val is_light : t -> bool
val palette : t -> palette
val channels : rgb -> int * int * int
val carbon : t
val slate : t
val crimson : t
val neon : t
val silver_dark : t
val silver_light : t

(** Silver themes first, followed by btop, legacy Silver and Cobalt themes. *)
val all : t list

(** Case-insensitive stable ID lookup. Spaces and underscores become hyphens. *)
val find : string -> t option
