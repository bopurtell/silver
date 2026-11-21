open! Core

(* A viewport tracks the first displayed row, independently of the selected
   row. Both arguments use display rows (including any group headings). *)
let last_top ~length ~capacity = Int.max 0 (length - Int.max 1 capacity)

let clamp ~top ~length ~capacity =
  Int.max 0 (Int.min top (last_top ~length ~capacity))
;;

let reveal ~top ~index ~length ~capacity =
  let top = clamp ~top ~length ~capacity in
  let capacity = Int.max 1 capacity in
  let index = Int.max 0 (Int.min index (length - 1)) in
  if index < top
  then index
  else if index - top >= capacity
  then index - capacity + 1
  else top
;;

let scroll ~top ~delta ~length ~capacity =
  let top = clamp ~top ~length ~capacity in
  top + Int.max (-top) (Int.min delta (last_top ~length ~capacity - top))
;;

let%test_unit "reverse motion preserves the bottom row until selection leaves the page" =
  let reveal = reveal ~length:12 ~capacity:4 in
  let top = reveal ~top:0 ~index:11 in
  assert (top = 8);
  assert (reveal ~top ~index:8 = 8);
  assert (reveal ~top ~index:7 = 7)
;;

let%test_unit "scroll clamps at both edges and resizing does not create blank tail rows" =
  let scroll = scroll ~length:9 ~capacity:4 in
  assert (scroll ~top:0 ~delta:1 = 1);
  assert (scroll ~top:1 ~delta:Int.max_value = 5);
  assert (scroll ~top:5 ~delta:Int.min_value = 0);
  assert (clamp ~top:5 ~length:9 ~capacity:8 = 1);
  assert (reveal ~top:5 ~index:3 ~length:0 ~capacity:0 = 0)
;;
