open! Core

module Preset = struct
  type t =
    | Instrument
    | Structured
    | Minimal
    | Studio
    | Structured_studio
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Instrument -> "A - Instrument"
    | Structured -> "B - Structured"
    | Minimal -> "C - Minimal"
    | Studio -> "D - Studio"
    | Structured_studio -> "E - Structured studio"
  ;;

  let key = function
    | Instrument -> "instrument"
    | Structured -> "structured"
    | Minimal -> "minimal"
    | Studio -> "studio"
    | Structured_studio -> "structured-studio"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Color = struct
  type t =
    | Vivid
    | Selective
    | Restrained
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Vivid -> "Vivid"
    | Selective -> "Selective"
    | Restrained -> "Restrained"
  ;;

  let key = function
    | Vivid -> "vivid"
    | Selective -> "selective"
    | Restrained -> "restrained"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Scheme = struct
  type t =
    | Carbon
    | Slate
    | Crimson
    | Neon
    | Catalog of Theme_catalog.t

  let entry = function
    | Carbon -> Theme_catalog.carbon
    | Slate -> Theme_catalog.slate
    | Crimson -> Theme_catalog.crimson
    | Neon -> Theme_catalog.neon
    | Catalog entry -> entry
  ;;

  let of_entry entry =
    match Theme_catalog.key entry with
    | "carbon" -> Carbon
    | "slate" -> Slate
    | "crimson" -> Crimson
    | "neon" -> Neon
    | _ -> Catalog entry
  ;;

  let all = List.map Theme_catalog.all ~f:of_entry
  let key t = Theme_catalog.key (entry t)
  let label t = Theme_catalog.label (entry t)
  let is_light t = Theme_catalog.is_light (entry t)
  let palette t = Theme_catalog.palette (entry t)
  let equal a b = String.equal (key a) (key b)
  let of_key key = Option.map (Theme_catalog.find key) ~f:of_entry
  let silver_dark = of_entry Theme_catalog.silver_dark
  let silver_light = of_entry Theme_catalog.silver_light

  (* Keep the original atom spellings; new palettes persist stable IDs, not labels or RGB
     values. A missing field still decodes as Carbon in old files. *)
  let sexp_of_t t =
    Sexp.Atom
      (match t with
       | Carbon | Slate | Crimson | Neon -> label t
       | Catalog _ -> key t)
  ;;

  let t_of_sexp sexp =
    match sexp with
    | Sexp.Atom key ->
      (match of_key key with
       | Some t -> t
       | None -> Sexplib0.Sexp_conv.of_sexp_error "Unknown color scheme" sexp)
    | Sexp.List _ -> Sexplib0.Sexp_conv.of_sexp_error "Expected a color scheme ID" sexp
  ;;
end

module Icons = struct
  type t =
    | None_
    | Ascii
    | Unicode
  [@@deriving enumerate, equal, sexp]

  let label = function
    | None_ -> "Off"
    | Ascii -> "ASCII"
    | Unicode -> "Unicode"
  ;;

  let key = function
    | None_ -> "none"
    | Ascii -> "ascii"
    | Unicode -> "unicode"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

module Density = struct
  type t =
    | Compact
    | Comfortable
  [@@deriving enumerate, equal, sexp]

  let label = function
    | Compact -> "Compact"
    | Comfortable -> "Comfortable"
  ;;

  let key = function
    | Compact -> "compact"
    | Comfortable -> "comfortable"
  ;;

  let of_key key_ = List.find all ~f:(fun t -> String.equal (key t) key_)
end

type t =
  { preset : Preset.t
  ; color : Color.t
  ; scheme : Scheme.t [@sexp.default Scheme.Carbon]
  ; icons : Icons.t
  ; density : Density.t
  }
[@@deriving equal, sexp]

(* Provisional presentation default; independent of persisted workspace state. *)
let default =
  { preset = Instrument
  ; color = Vivid
  ; scheme = Scheme.silver_dark
  ; icons = Unicode
  ; density = Comfortable
  }
;;

let%test_unit "appearance keys are stable and round trip" =
  List.iter Preset.all ~f:(fun t ->
    assert (Option.equal Preset.equal (Preset.of_key (Preset.key t)) (Some t)));
  List.iter Color.all ~f:(fun t ->
    assert (Option.equal Color.equal (Color.of_key (Color.key t)) (Some t)));
  List.iter Scheme.all ~f:(fun t ->
    assert (Option.equal Scheme.equal (Scheme.of_key (Scheme.key t)) (Some t)));
  List.iter Icons.all ~f:(fun t ->
    assert (Option.equal Icons.equal (Icons.of_key (Icons.key t)) (Some t)));
  List.iter Density.all ~f:(fun t ->
    assert (Option.equal Density.equal (Density.of_key (Density.key t)) (Some t)));
  assert (Option.is_none (Preset.of_key "unknown"))
;;

let%test_unit "fresh appearance is Silver Dark; legacy preferences retain Carbon and old \
               atoms"
  =
  let legacy =
    t_of_sexp
      (Sexp.of_string "((preset Studio)(color Restrained)(icons Ascii)(density Compact))")
  in
  assert (String.equal (Scheme.key default.scheme) "silver-dark");
  assert (Scheme.equal legacy.scheme Carbon);
  assert (
    equal
      legacy
      { preset = Studio
      ; color = Restrained
      ; scheme = Carbon
      ; icons = Ascii
      ; density = Compact
      });
  List.iter Scheme.all ~f:(fun scheme ->
    let appearance = { legacy with scheme } in
    assert (equal appearance (t_of_sexp (sexp_of_t appearance))));
  List.iter
    [ "Carbon", Scheme.Carbon; "Slate", Slate; "Crimson", Crimson; "Neon", Neon ]
    ~f:(fun (atom, scheme) ->
      let explicit =
        t_of_sexp
          (Sexp.of_string
             (sprintf
                "((preset Studio)(color Restrained)(scheme %s)(icons Ascii)(density \
                 Compact))"
                atom))
      in
      assert (equal explicit { legacy with scheme });
      assert (Sexp.equal (Scheme.sexp_of_t scheme) (Atom atom)));
  let light = Option.value_exn (Scheme.of_key " Silver_Light ") in
  assert (Scheme.equal light Scheme.silver_light);
  assert (Scheme.is_light light);
  assert (Sexp.equal (Scheme.sexp_of_t light) (Atom "silver-light"));
  assert (Option.is_none (Scheme.of_key "unknown"))
;;
