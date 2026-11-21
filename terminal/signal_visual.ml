open! Core

type t = int

let valid ~row_count row = row >= 0 && row < row_count
let start ~row_count ~focus = Option.some_if (valid ~row_count focus) focus
let bounds anchor focus = Int.min anchor focus, Int.max anchor focus

let contains anchor ~focus ~row =
  let first, last = bounds anchor focus in
  first <= row && row <= last
;;

let length anchor ~focus =
  let first, last = bounds anchor focus in
  last - first + 1
;;

type toggle_result =
  | Toggled of Int.Set.t
  | Selection_limit
  | No_range

let toggle anchor ~focus ~rows ~id ~enabled ~limit =
  let row_count = List.length rows in
  if not (valid ~row_count anchor && valid ~row_count focus)
  then No_range
  else (
    let first, last = bounds anchor focus in
    let ids =
      List.sub rows ~pos:first ~len:(last - first + 1)
      |> List.map ~f:id
      |> Int.Set.of_list
    in
    let next =
      if Set.is_subset ids ~of_:enabled
      then Set.diff enabled ids
      else Set.union enabled ids
    in
    if Set.length next > limit then Selection_limit else Toggled next)
;;

let%test_unit "range reverses and shrinks across its anchor as the focus moves" =
  let anchor = start ~row_count:7 ~focus:3 |> Option.value_exn in
  let marked focus =
    List.init 7 ~f:Fn.id |> List.filter ~f:(fun row -> contains anchor ~focus ~row)
  in
  assert (List.equal Int.equal (marked 3) [ 3 ]);
  assert (List.equal Int.equal (marked 5) [ 3; 4; 5 ]);
  assert (List.equal Int.equal (marked 4) [ 3; 4 ]);
  assert (List.equal Int.equal (marked 1) [ 1; 2; 3 ]);
  assert (length anchor ~focus:1 = 3);
  assert (Option.is_none (start ~row_count:0 ~focus:0));
  assert (Option.is_none (start ~row_count:2 ~focus:2))
;;

let%test_unit "bulk toggle uses filtered ordinals, not IDs or viewport rows" =
  let rows = [ 8; 2; 7; 0; 9; 13 ] in
  let anchor = start ~row_count:(List.length rows) ~focus:4 |> Option.value_exn in
  let enabled = Int.Set.of_list [ 1; 5; 7; 9; 13 ] in
  let toggle ~focus enabled = toggle anchor ~focus ~rows ~id:Fn.id ~enabled ~limit:16 in
  let toggled = function
    | Toggled next -> next
    | _ -> failwith "expected a toggle"
  in
  let next = toggle ~focus:1 enabled |> toggled in
  (* Filtered-out 1/5 and rows outside the range remain unchanged. *)
  assert (Set.equal next (Int.Set.of_list [ 0; 1; 2; 5; 7; 9; 13 ]));
  assert (Set.equal (toggle ~focus:1 next |> toggled) (Int.Set.of_list [ 1; 5; 13 ]));
  assert (
    match toggle ~focus:6 enabled with
    | No_range -> true
    | _ -> false)
;;

let%test_unit "range enabling is atomic at the selection limit; disabling still works" =
  let anchor = start ~row_count:3 ~focus:0 |> Option.value_exn in
  let rows = [ 20; 21; 22 ] in
  let enabled = Int.Set.of_list (22 :: List.init 15 ~f:Fn.id) in
  assert (
    match toggle anchor ~focus:2 ~rows ~id:Fn.id ~enabled ~limit:16 with
    | Selection_limit -> true
    | _ -> false);
  let anchor = start ~row_count:3 ~focus:2 |> Option.value_exn in
  match toggle anchor ~focus:2 ~rows ~id:Fn.id ~enabled ~limit:16 with
  | Toggled next -> assert (Set.equal next (Int.Set.of_list (List.init 15 ~f:Fn.id)))
  | _ -> failwith "expected disabling at the selection limit to succeed"
;;
