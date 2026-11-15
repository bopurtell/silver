open! Core

type key =
  | Backspace
  | Delete_word

let drop_character text =
  let rec start offset =
    if offset > 0 && Char.to_int text.[offset] land 0xc0 = 0x80
    then start (offset - 1)
    else offset
  in
  if String.is_empty text
  then text
  else String.prefix text (start (String.length text - 1))
;;

let delete_word text =
  let word c = Char.is_alphanum c || Char.equal c '_' || Char.to_int c >= 128 in
  let rec skip offset predicate =
    if offset > 0 && predicate text.[offset - 1]
    then skip (offset - 1) predicate
    else offset
  in
  let offset = skip (String.length text) (fun c -> not (word c)) in
  String.prefix text (skip offset word)
;;

(* Use the modifiers that the native decoder actually preserves. DEL without a modifier
   remains ordinary Backspace; it cannot identify a distinct gesture. Ctrl-W is available
   even when the terminal maps both gestures to plain DEL. *)
let edit_key (event : Bonsai_term.Event.t) =
  match event with
  | Key_press { key = Backspace; mods } ->
    Some
      (if List.exists mods ~f:(function
            | Ctrl | Meta -> true
            | _ -> false)
       then Delete_word
       else Backspace)
  | Key_press { key = ASCII ('w' | 'W' | 'h' | 'H' | '\008' | '\127'); mods }
    when List.exists mods ~f:(function
           | Ctrl -> true
           | _ -> false) -> Some Delete_word
  | Key_press { key = Uchar c; mods }
    when List.exists mods ~f:(function
           | Ctrl -> true
           | _ -> false)
         && List.exists [ 'w'; 'W'; 'h'; 'H'; '\008'; '\127' ] ~f:(fun x ->
           Uchar.equal c (Uchar.of_char x)) -> Some Delete_word
  | Key_press { key = ASCII '\023'; mods = [] } -> Some Delete_word
  | Key_press { key = ASCII ('\008' | '\127'); mods = [] } -> Some Backspace
  | _ -> None
;;

let apply key text =
  match key with
  | Backspace -> drop_character text
  | Delete_word -> delete_word text
;;
