open! Core
open Bonsai_term

module Model = Cobalt_terminal_pool.Model

let color : Model.color -> Attr.Color.t = function
  | Default -> Attr.Color.Expert.default
  | Indexed n -> Attr.Color.xterm_256 (Int.max 0 (Int.min 255 n))
  | Rgb (r, g, b) -> Attr.Color.rgb ~r ~g ~b
;;

let attributes (style : Model.style) ~cursor =
  [ Attr.fg (color style.fg); Attr.bg (color style.bg) ]
  @ List.filter_map
      [ style.bold, Attr.bold
      ; style.italic, Attr.italic
      ; style.underline, Attr.underline
      ; not (Bool.equal style.reverse cursor), Attr.invert
      ]
      ~f:(fun (set, attr) -> Option.some_if set attr)
;;

let blank ?attrs width = View.rectangle ?attrs ~width ~height:1 ()

let fit ?attrs width view =
  let actual = View.width view in
  if actual > width
  then View.crop ~r:(actual - width) view
  else if actual < width
  then View.hcat [ view; blank ?attrs (width - actual) ]
  else view
;;

let render_row (snapshot : Model.snapshot) ~width ~cursor row_number =
  if row_number >= Array.length snapshot.rows
  then blank width
  else (
    let row = snapshot.rows.(row_number) in
    let stop = Int.min width (Array.length row) in
    let bytes = Buffer.create stop in
    (* Group equal-style ASCII cells. Fit non-ASCII cells individually so a
       disagreement between Notty and libvterm on a glyph's width doesn't
       shift the rest of the row. *)
    let flush acc run =
      match run with
      | None -> acc
      | Some (style, cursor, columns) ->
        let attrs = attributes style ~cursor in
        let view = fit ~attrs columns (View.text ~attrs (Buffer.contents bytes)) in
        Buffer.clear bytes;
        view :: acc
    in
    let rec loop col acc run =
      if col >= stop
      then (
        let acc = flush acc run in
        let acc = if stop < width then blank (width - stop) :: acc else acc in
        View.hcat (List.rev acc))
      else (
        let cell = row.(col) in
        let columns = if cell.width = 2 && col + 1 < stop then 2 else 1 in
        let text =
          if cell.width = columns && not (String.is_empty cell.text) then cell.text else " "
        in
        let cursor =
          cursor && snapshot.cursor_col >= col && snapshot.cursor_col < col + columns
        in
        if columns = 1 && String.length text = 1 && Char.to_int text.[0] < 128
        then (
          let acc, run_width =
            match run with
            | Some (style, inverted, run_width)
              when Bool.equal cursor inverted && Model.equal_style style cell.style ->
              acc, run_width
            | _ -> flush acc run, 0
          in
          Buffer.add_string bytes text;
          loop (col + columns) acc (Some (cell.style, cursor, run_width + columns)))
        else (
          let acc = flush acc run in
          let attrs = attributes cell.style ~cursor in
          let view = fit ~attrs columns (View.text ~attrs text) in
          loop (col + columns) (view :: acc) None))
    in
    loop 0 [] None)
;;

let render ~number ~cwd ~status ~(snapshot : Model.snapshot option)
  ~dimensions:({ width; height } : Dimensions.t)
  =
  if width <= 0 || height <= 0
  then View.none
  else (
    let attrs = [ Attr.bold; Attr.invert ] in
    let header =
      sprintf " Terminal %d (local) | %s | %s " number status cwd
      |> View.text ~attrs
      |> fit ~attrs width
    in
    let body =
      match snapshot with
      | None -> View.rectangle ~width ~height:(height - 1) ()
      | Some snapshot ->
        View.vcat
          (List.init (height - 1) ~f:(fun row ->
             let cursor =
               Option.is_none snapshot.exited
               && snapshot.cursor_visible
               && snapshot.cursor_row = row
             in
             render_row snapshot ~width ~cursor row))
    in
    View.vcat [ header; body ])
;;
