open! Core
module Theme = Cobalt_hosted.Theme
module Scheme = Terminal_presentation.Appearance.Scheme
module Palette = Terminal_presentation.Theme_catalog

let of_scheme scheme =
  let p = Scheme.palette scheme in
  let rgb = Palette.channels in
  let kind = if Scheme.is_light scheme then Theme.Kind.Light else Theme.Kind.Dark in
  let theme =
    Theme.of_base16
      ~id:(Scheme.key scheme)
      ~title:(Scheme.label scheme)
      ~kind
      ~palette:
        (Array.map
           ~f:rgb
           [| p.background
            ; p.surface
            ; p.border
            ; p.muted
            ; p.selective
            ; p.foreground
            ; p.heading
            ; p.heading
            ; p.failure
            ; p.metric
            ; p.warning
            ; p.success
            ; p.selective
            ; p.accent
            ; p.metric
            ; p.warning
           |])
  in
  Theme.with_colors
    theme
    (List.map
       ~f:(fun (role, color) -> role, rgb color)
       [ Theme.Role.Selection_foreground, p.foreground
       ; Selection_background, p.selection
       ; Search_foreground, p.metric
       ; Search_background, p.surface
       ; Search_current_foreground, p.background
       ; Search_current_background, p.accent
       ])
;;

let resolve (config : Editor_config.t) scheme =
  match config.theme_override with
  | Some theme -> theme
  | None -> of_scheme scheme
;;

let%test_unit "every Silver scheme preserves the shared semantic colors" =
  List.iter Scheme.all ~f:(fun scheme ->
    let p = Scheme.palette scheme in
    let theme = of_scheme scheme in
    assert (String.equal (Theme.id theme) (Scheme.key scheme));
    assert (
      Theme.Kind.equal (Theme.kind theme) (if Scheme.is_light scheme then Light else Dark));
    List.iter
      [ Theme.Role.Background, p.background
      ; Foreground, p.foreground
      ; Surface, p.surface
      ; Muted, p.muted
      ; Border, p.border
      ; Selection_background, p.selection
      ; Selection_foreground, p.foreground
      ; Warning, p.warning
      ; Error, p.failure
      ]
      ~f:(fun (role, expected) ->
        assert (Poly.equal (Theme.color theme role) (Palette.channels expected))))
;;

let%test_unit "embedded override ignores Silver previews and doesn't mutate either \
               catalog"
  =
  let dark = Scheme.silver_dark
  and light = Scheme.silver_light in
  let explicit = Or_error.ok_exn (Editor_config.decode "((theme abyss))") in
  let before = Option.value_exn (Theme.find "abyss") in
  let inherited = resolve Editor_config.default in
  assert (not (Theme.equal (inherited dark) (inherited light)));
  assert (Theme.equal before (resolve explicit dark));
  assert (Theme.equal before (resolve explicit light));
  assert (Theme.equal before (Option.value_exn (Theme.find "abyss")));
  assert (Theme.equal (inherited dark) (of_scheme dark))
;;
