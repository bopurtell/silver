(** Format a byte count in decimal units. Bytes are exact; scaled values are rounded half
    up to two decimal places, promoting to the next unit if rounding reaches 1000. Missing
    or negative counts are [unknown]. *)
val format : int option -> string
