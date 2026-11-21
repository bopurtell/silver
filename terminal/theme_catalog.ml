open! Core

type rgb = int

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

type t =
  { key : string
  ; label : string
  ; is_light : bool
  ; palette : palette
  }

let key t = t.key
let label t = t.label
let is_light t = t.is_light
let palette t = t.palette

let normalize s =
  String.lowercase (String.strip s)
  |> String.map ~f:(function
    | ' ' | '_' -> '-'
    | c -> c)
;;

let channels n = (n lsr 16) land 255, (n lsr 8) land 255, n land 255

let mix a b amount =
  let ar, ag, ab = channels a in
  let br, bg, bb = channels b in
  let channel a b = ((a * (100 - amount)) + (b * amount) + 50) / 100 in
  (channel ar br lsl 16) lor (channel ag bg lsl 8) lor channel ab bb
;;

let luminance rgb =
  let linear n =
    let c = Float.of_int n /. 255. in
    if Float.(c <= 0.04045) then c /. 12.92 else ((c +. 0.055) /. 1.055) ** 2.4
  in
  let r, g, b = channels rgb in
  (0.2126 *. linear r) +. (0.7152 *. linear g) +. (0.0722 *. linear b)
;;

let contrast a b =
  let a = luminance a
  and b = luminance b in
  (Float.max a b +. 0.05) /. (Float.min a b +. 0.05)
;;

let legible ~is_light ~against ~target color =
  let ink = if is_light then 0x000000 else 0xffffff in
  let rec loop amount =
    let candidate = mix color ink amount in
    if amount = 100
       || List.for_all against ~f:(fun bg -> Float.(contrast candidate bg >= target))
    then candidate
    else loop (amount + 1)
  in
  loop 0
;;

let text_ink ~is_light ~background ~card ~surface ~selection =
  legible ~is_light ~against:[ selection; background; card; surface ] ~target:4.5
;;

let make
  ~key
  ~label
  ~is_light
  ~background
  ~foreground
  ~surface
  ~card
  ~selection
  ~muted
  ~border
  ~accent
  ~metric
  ~success
  ~warning
  ~failure
  =
  (* Selected text sometimes reuses ordinary row attributes. Keep every text ink readable
     on all four grounds, including when a search match is selected. Leave decorative
     borders softer; do not use them for secondary text. *)
  let grounds = [ background; card; surface ] in
  let text = text_ink ~is_light ~background ~card ~surface ~selection in
  let foreground = text foreground in
  { key
  ; label
  ; is_light
  ; palette =
      { background
      ; foreground
      ; surface
      ; card
      ; selection
      ; muted = text muted
      ; border = legible ~is_light ~against:grounds ~target:3. border
      ; accent = text accent
      ; selective = text (mix accent foreground 42)
      ; metric = text metric
      ; success = text success
      ; warning = text warning
      ; failure = text failure
      ; heading = foreground
      ; monitor = None
      }
  }
;;

(* Silver's original four palettes are intentionally exact, including their borders and
   white headings. Their saved values must keep painting as they did before. *)
let legacy
  key
  label
  background
  foreground
  surface
  card
  selection
  muted
  border
  accent
  selective
  metric
  success
  warning
  failure
  =
  { key
  ; label
  ; is_light = false
  ; palette =
      { background
      ; foreground
      ; surface
      ; card
      ; selection
      ; muted
      ; border
      ; accent
      ; selective
      ; metric
      ; success
      ; warning
      ; failure
      ; heading = 0xffffff
      ; monitor = None
      }
  }
;;

let carbon =
  legacy "carbon" "Carbon" 0x000000 0xd8d8dc 0x232323 0x111111 0x303038
    0x9999a3 0x5b5b68 0x97b1e2 0x97a9c6 0xdcc493 0x97c697 0xe1b974 0xeb8b97
[@@ocamlformat "disable"]

let slate =
  legacy "slate" "Slate" 0x1c1f24 0xdadde2 0x313740 0x22262c 0x404b58
    0x9da5b1 0x647080 0x99b8d5 0x9db2c3 0xd6c59d 0x9bc5a8 0xe0bc82 0xe2909a
[@@ocamlformat "disable"]

let crimson =
  legacy "crimson" "Crimson" 0x0c0a0a 0xe0d2d2 0x352328 0x131010 0x4c2731
    0xa78b91 0x70535c 0xe85d75 0xd08c9a 0xffcb6b 0x9ece6a 0xffb86c 0xff7088
[@@ocamlformat "disable"]

let neon =
  legacy "neon" "Neon" 0x111623 0xe0e9f9 0x2b3753 0x192235 0x2b3753
    0x99adca 0x8497ec 0x63daff 0x75cadd 0xffcf66 0x73e7a7 0xffca69 0xff7490
[@@ocamlformat "disable"]

let silver_dark =
  make ~key:"silver-dark" ~label:"Silver Dark" ~is_light:false ~background:0x191d22
    ~foreground:0xe0e5e9 ~surface:0x272e35 ~card:0x20262c ~selection:0x334352
    ~muted:0xa6b2bd ~border:0x687b8b ~accent:0xaec9df ~metric:0xccc0e3
    ~success:0xa7ccba ~warning:0xe4c48f ~failure:0xe7a6b0
[@@ocamlformat "disable"]

let silver_light =
  make ~key:"silver-light" ~label:"Silver Light" ~is_light:true ~background:0xf5f7f9
    ~foreground:0x293540 ~surface:0xe7edf1 ~card:0xeff3f6 ~selection:0xd4e1ed
    ~muted:0x546471 ~border:0x7b8995 ~accent:0x305e82 ~metric:0x5e487a
    ~success:0x326650 ~warning:0x775321 ~failure:0x963d50
[@@ocamlformat "disable"]

let silver_variants =
  [ make ~key:"silver-blue" ~label:"Silver Blue" ~is_light:false ~background:0x141e2c
      ~foreground:0xdce7f0 ~surface:0x24344a ~card:0x1b2a3b ~selection:0x314867
      ~muted:0xa6bbce ~border:0x6985a2 ~accent:0xa8cff2 ~metric:0xd2bbe9
      ~success:0xa1ccb9 ~warning:0xe1c292 ~failure:0xe6a3b1
  ; make ~key:"silver-dusk" ~label:"Silver Dusk" ~is_light:false ~background:0x221d2a
      ~foreground:0xe7e0ed ~surface:0x332c3e ~card:0x292332 ~selection:0x483952
      ~muted:0xbbadca ~border:0x867194 ~accent:0xd2b7e9 ~metric:0xa8ccdf
      ~success:0xadccaf ~warning:0xe7c29a ~failure:0xeba6b8
  ; make ~key:"silver-patina" ~label:"Silver Patina" ~is_light:false ~background:0x192221
      ~foreground:0xdce7e3 ~surface:0x293734 ~card:0x222d2a ~selection:0x365049
      ~muted:0xa7bbb4 ~border:0x66877f ~accent:0xa4cec2 ~metric:0xbacae3
      ~success:0xb1d2a6 ~warning:0xe2c58c ~failure:0xe5a6a4
  ; make ~key:"silver-pearl" ~label:"Silver Pearl" ~is_light:true ~background:0xf8f5f0
      ~foreground:0x39343c ~surface:0xeee7e8 ~card:0xf3edeb ~selection:0xe3d8e4
      ~muted:0x665966 ~border:0x918098 ~accent:0x654c78 ~metric:0x355d74
      ~success:0x3d654f ~warning:0x764e28 ~failure:0x923e55
  ]
[@@ocamlformat "disable"]

(* Palette data adapted from Cobalt's theme/theme.ml at 98e6ed7 (Cobalt declares MIT).
   Preserve the neutral ramps and accent families; selection is a restrained tint rather
   than an editor search highlight. *)
let base16 key label is_light colors =
  let c = Array.of_list colors in
  assert (Array.length c = 16);
  make
    ~key
    ~label
    ~is_light
    ~background:c.(0)
    ~foreground:c.(5)
    ~surface:c.(1)
    ~card:(mix c.(0) c.(1) 55)
    ~selection:(mix c.(1) c.(2) 70)
    ~muted:c.(3)
    ~border:c.(2)
    ~accent:c.(13)
    ~metric:c.(14)
    ~success:c.(11)
    ~warning:c.(10)
    ~failure:c.(8)
;;

let cobalt =
  let early key label bg fg surface muted border accent special success warning failure =
    make ~key ~label ~is_light:false ~background:bg ~foreground:fg ~surface
      ~card:(mix bg surface 55) ~selection:(mix surface accent 20) ~muted ~border
      ~accent ~metric:special ~success ~warning ~failure
  in
  [ early "midnight" "Midnight" 0x0b0b0c 0xd0d0d0 0x1c1c1f 0x5a5a60 0x3a3a40
      0x7aa2f7 0xbb9af7 0x9ece6a 0xe0af68 0xf7768e
  ; early "cobalt-crimson" "Cobalt Crimson" 0x0c0a0a 0xe0d2d2 0x201a1b 0x665558
      0x443639 0xe85d75 0xc9a0ff 0x9ece6a 0xffb86c 0xff3355
  ; early "ember" "Ember" 0x141412 0xebdbb2 0x282828 0x665c54 0x504945
      0x83a598 0xd3869b 0xb8bb26 0xfabd2f 0xfb4934
  ; early "glacier" "Glacier" 0x090c10 0xc8d3e0 0x171e26 0x4e5a68 0x2e3a48
      0x5cc8ff 0xf08fc0 0x7fe0c0 0xe6c384 0xff6b7f
  ; base16 "vim-classic" "Vim Classic" false
      [ 0x000000; 0x101010; 0x404040; 0x707070; 0xb0b0b0; 0xd3d3d3; 0xffffff; 0xffffff;
        0xff6060; 0xff80ff; 0xffff00; 0x00ff00; 0x80a0ff; 0x00ffff; 0xffff00; 0xffa500 ]
  ; base16 "solarized-light" "Solarized Light" true
      [ 0xfdf6e3; 0xeee8d5; 0x93a1a1; 0x839496; 0x586e75; 0x657b83; 0x073642; 0x002b36;
        0xdc322f; 0xcb4b16; 0xb58900; 0x859900; 0x2aa198; 0x268bd2; 0x6c71c4; 0xd33682 ]
  ; base16 "linen-solar" "Linen Solar" true
      [ 0xfcf5e9; 0xeee5d5; 0xc7bba6; 0x7b8b89; 0x52666b; 0x425b63; 0x27434c; 0x17313a;
        0xc43b38; 0xb95720; 0xb18a16; 0x6f8500; 0x168b83; 0x207aba; 0x7063b5; 0xbc3176 ]
  ; base16 "sandstone-solar" "Sandstone Solar" true
      [ 0xf5e6c4; 0xe8d6ad; 0xc4ad80; 0x827c65; 0x595b4b; 0x394b4d; 0x253a3d; 0x142b30;
        0xba332b; 0xb34a13; 0xa17b00; 0x657900; 0x087f78; 0x196eaa; 0x6555a6; 0xaf296d ]
  ; base16 "orokin-light" "Orokin Light" true
      [ 0xfafaf7; 0xeff1ef; 0xcdd2cf; 0x737d80; 0x505d64; 0x293740; 0x192830; 0x101b23;
        0xb33e4b; 0x92582d; 0x85651f; 0x396f60; 0x197780; 0x85651f; 0x66518c; 0x896c43 ]
  ; base16 "orokin-dark" "Orokin Dark" false
      [ 0x101820; 0x1b2630; 0x394752; 0x879599; 0xb9c3c1; 0xeeeade; 0xf9f6eb; 0xfffdf5;
        0xed8790; 0xd9a478; 0xe4c77b; 0x99c6ae; 0x79d4db; 0xe4c77b; 0xbaabd8; 0xbea17a ]
  ; base16 "abyss" "Abyss" false
      [ 0x08121c; 0x102232; 0x253b4d; 0x688499; 0x93adbf; 0xc5dce8; 0xe0edf4; 0xf4faff;
        0xf07888; 0xe9a36b; 0xe5cc84; 0x92cda8; 0x76d5d0; 0x78b7ee; 0xb3a0e5; 0xb88e77 ]
  ; base16 "moss" "Moss" false
      [ 0x121a14; 0x1e2a20; 0x354b38; 0x789479; 0x9eb39a; 0xd3dfc7; 0xe5eddb; 0xf5f8ec;
        0xd98776; 0xd4a16a; 0xd8c97d; 0x9cbd78; 0x77b5a1; 0x86aabe; 0xb39bbd; 0xb39978 ]
  ; base16 "orchid" "Orchid" false
      [ 0x201426; 0x302039; 0x4c3656; 0x96799f; 0xbca2c4; 0xe4cee9; 0xf0e0f4; 0xfcf3ff;
        0xf18cae; 0xe8ad89; 0xe5d08b; 0xa9d39b; 0x8bd1c8; 0xa5b8f2; 0xd29cf0; 0xc394ad ]
  ; base16 "copper" "Copper" false
      [ 0x211711; 0x30231a; 0x50392b; 0x9b7b62; 0xbfa48b; 0xe5d3b8; 0xf2e4ce; 0xfff4e3;
        0xe48473; 0xefad73; 0xe4c888; 0xb4c08b; 0x88beb3; 0x92b4cf; 0xc5a0c3; 0xc19265 ]
  ; base16 "silver" "Silver" false
      [ 0x171d26; 0x242e3a; 0x405063; 0x8b9bad; 0xb1bfcd; 0xdce5ee; 0xebf2f8; 0xf8fcff;
        0xe68f9c; 0xdcb18b; 0xe0ce99; 0xa4c9b2; 0x8cced1; 0xb0c8e8; 0xc3ade0; 0xb69c90 ]
  ; base16 "silver-frost" "Silver Frost" true
      [ 0xf3f8fc; 0xe2ecf4; 0xc2d2e0; 0x65798a; 0x4b6174; 0x283e51; 0x1a2d3e; 0x0d1e2d;
        0xae405d; 0x985d2b; 0x796319; 0x37734f; 0x1b737d; 0x3c6491; 0x72559b; 0x826351 ]
  ; base16 "silver-tarnish" "Silver Tarnish" false
      [ 0x1b211f; 0x29322e; 0x45534b; 0x909e92; 0xb3c1b5; 0xd8e2d7; 0xe9f0e5; 0xf7fcf2;
        0xd9958d; 0xd5ac7e; 0xd5cc94; 0xa9c68c; 0x83bfb0; 0xa8c6c8; 0xbca7cd; 0xb39b7f ]
  ; base16 "gold" "Gold" false
      [ 0x211b10; 0x332a18; 0x55462a; 0xa49470; 0xc6b78e; 0xeadcb7; 0xf6ebce; 0xfff7e3;
        0xeb8c7c; 0xeeb06e; 0xf2dc99; 0xb6cb8a; 0x8bc9bc; 0xe7bf63; 0xc9a2d1; 0xc59868 ]
  ; base16 "gold-antique" "Gold Antique" false
      [ 0x202016; 0x303022; 0x4e4d32; 0x999776; 0xbdbb94; 0xe0ddbb; 0xeeebd0; 0xfaf7e3;
        0xd28e78; 0xd3a66d; 0xdbd39a; 0xa8bb7d; 0x88b5a5; 0xc6b265; 0xbba1bf; 0xb29366 ]
  ; base16 "gold-champagne" "Gold Champagne" true
      [ 0xfcf5e7; 0xefe3cc; 0xd8c5a1; 0x827258; 0x66553e; 0x423526; 0x30251a; 0x21180f;
        0xa63f48; 0x9a5728; 0x78631b; 0x526f3b; 0x2e7470; 0x876320; 0x80558b; 0x8f6544 ]
  ; base16 "platinum" "Platinum" true
      [ 0xf7f6fa; 0xe9e7ef; 0xcecbd9; 0x777182; 0x5c5669; 0x383343; 0x282332; 0x191521;
        0xad435d; 0x9b6035; 0x7b682c; 0x487355; 0x317780; 0x586b91; 0x795b9c; 0x89695d ]
  ; base16 "iron" "Iron" false
      [ 0x191c1f; 0x292e33; 0x454e57; 0x919ba3; 0xb2bdc5; 0xd8dfe3; 0xe9eef0; 0xf8fafb;
        0xe68a76; 0xdca16d; 0xd9c28a; 0xa4bf93; 0x7eb8bc; 0x92b5d3; 0xb8a1cc; 0xb78c75 ]
  ; base16 "inkwell" "Inkwell" false
      [ 0x131627; 0x20253a; 0x353e58; 0x7b87aa; 0xa1aecb; 0xd1d9ed; 0xe6ebf7; 0xf8faff;
        0xf18c9e; 0xe6ae88; 0xe7d49c; 0xa7d0b0; 0x86d0d1; 0x8caaf1; 0xbca3ed; 0xba9d9a ]
  ; base16 "desert-night" "Desert Night" false
      [ 0x211d1a; 0x302a24; 0x4d4337; 0x988a74; 0xb9ac94; 0xe3d8ba; 0xf0e7cf; 0xfff7e3;
        0xe08c78; 0xe6b17d; 0xe8cc8d; 0xb7c28c; 0x8bc3b5; 0x95b7ce; 0xc6a0bc; 0xbd9474 ]
  ; base16 "tidepool" "Tidepool" false
      [ 0x0c2020; 0x173132; 0x2c4c4a; 0x6e9a96; 0x9cbdb7; 0xcde5d9; 0xe2f2e7; 0xf4fff6;
        0xea9087; 0xe6b085; 0xe0d399; 0xa7d2a0; 0x73d7c4; 0x83badf; 0xb4a9dd; 0xbc9a7d ]
  ; base16 "plum-smoke" "Plum Smoke" false
      [ 0x211b24; 0x302936; 0x493e51; 0x92839c; 0xb5a6bd; 0xded2e5; 0xeee4f2; 0xfcf4ff;
        0xe594ac; 0xdbad91; 0xd8cc9e; 0xaacaab; 0x91c8c8; 0x9eb8de; 0xc7a6dc; 0xbca095 ]
  ; base16 "signal" "Signal" false
      [ 0x111518; 0x20282d; 0x39464e; 0x7b929e; 0xa4b9c4; 0xdbe8ee; 0xedf6fa; 0xffffff;
        0xff6978; 0xffab62; 0xffdc70; 0x9ce57d; 0x6be3cc; 0x6ebaff; 0xc09bff; 0xc69678 ]
  ; base16 "deep-olive" "Deep Olive" false
      [ 0x1a1c12; 0x292d1d; 0x444a30; 0x899267; 0xaeb58b; 0xdde1ba; 0xecf0d0; 0xfaffdf;
        0xdb8d78; 0xd6ab72; 0xd5cd76; 0xa8c777; 0x85b9a2; 0x94aeca; 0xbda0c5; 0xb49b6b ]
  ; base16 "cobalt-room" "Cobalt Room" false
      [ 0x101b38; 0x192b4c; 0x2c466a; 0x728fb6; 0x9db7d8; 0xd0e0f5; 0xe4edfb; 0xf5f9ff;
        0xf18a9f; 0xf0ad7c; 0xeed58a; 0x9ed8af; 0x7ed8db; 0x79b1ff; 0xb3a3f4; 0xb99c9c ]
  ; base16 "cobalt-midnight" "Cobalt Midnight" false
      [ 0x080f24; 0x111e38; 0x263b5b; 0x7b91b5; 0x9fb6d6; 0xd5e2f7; 0xe8f0ff; 0xf7faff;
        0xf28b9d; 0xefb078; 0xf2d58a; 0x9dd6ac; 0x79d2da; 0x82b5ff; 0xb9a5f5; 0xb79b91 ]
  ; base16 "cobalt-electric" "Cobalt Electric" false
      [ 0x092044; 0x123059; 0x2b4c78; 0x87a2ca; 0xadc6ea; 0xe4efff; 0xf1f7ff; 0xffffff;
        0xff8097; 0xffb66e; 0xffdf80; 0xa4eb91; 0x6de5ed; 0x79bdff; 0xc5a1ff; 0xd1a18b ]
  ; base16 "cobalt-mist" "Cobalt Mist" false
      [ 0x1b2539; 0x27344a; 0x40516b; 0x8d9db7; 0xafbed3; 0xd8e2f0; 0xe8eff8; 0xf7faff;
        0xe29aa8; 0xdeb58f; 0xe2d29f; 0xa9cdb4; 0x95ced4; 0x9cbce9; 0xbbaee0; 0xbda79d ]
  ; base16 "cobalt-frost" "Cobalt Frost" true
      [ 0xf1f6ff; 0xe2ebfa; 0xc1cfe5; 0x627595; 0x455c7f; 0x253c60; 0x182d4c; 0x0d1e38;
        0xb43c59; 0x9d5726; 0x80641e; 0x35734f; 0x18737f; 0x285fa8; 0x7153a2; 0x88604d ]
  ; base16 "rosewood" "Rosewood" false
      [ 0x251619; 0x362126; 0x57363f; 0xa47b86; 0xc29ca5; 0xe9cdd0; 0xf6e1e0; 0xfff1eb;
        0xf08b92; 0xe8ab88; 0xe4cb94; 0xb5cd9a; 0x95c8bc; 0xa0b9d6; 0xcca4d4; 0xc19586 ]
  ; base16 "volcanic" "Volcanic" false
      [ 0x181719; 0x292529; 0x463d44; 0x98838e; 0xbda3af; 0xe4cdd5; 0xf1e0e6; 0xfff3f4;
        0xff776b; 0xf4a162; 0xf2cf78; 0xb6d28a; 0x8dd2c4; 0x9bbce6; 0xd1a1e8; 0xc28d75 ]
  ; base16 "aurora-field" "Aurora Field" false
      [ 0x10211b; 0x1b332b; 0x314e42; 0x739a88; 0x9dc3ad; 0xcce7d6; 0xe0f4e6; 0xf2fff4;
        0xf192ac; 0xebae85; 0xe6d68e; 0x91dfaa; 0x74e2d0; 0x92bdf4; 0xc9a0f0; 0xb99e82 ]
  ; base16 "mulberry" "Mulberry" false
      [ 0x291422; 0x3a2031; 0x5b354e; 0xa17592; 0xc69ab6; 0xeacbe0; 0xf6dfed; 0xfff1f9;
        0xf18dbb; 0xe6aa94; 0xe2ce9a; 0xb4d39e; 0x93d2c6; 0xa3bcef; 0xd5a0ed; 0xc299a5 ]
  ; base16 "storm-slate" "Storm Slate" false
      [ 0x1b242c; 0x29353f; 0x41535e; 0x8299a6; 0xa6bac4; 0xd4e1e5; 0xe5eff1; 0xf6fcfc;
        0xe79898; 0xe1b28a; 0xdccd9c; 0xa7c8a4; 0x8cc7c6; 0x95b7d7; 0xb9abce; 0xb79f8b ]
  ; base16 "saffron-night" "Saffron Night" false
      [ 0x241e0e; 0x352d18; 0x554829; 0xa18c58; 0xc2ad78; 0xe8d8a6; 0xf5e8bf; 0xfff5d9;
        0xe99171; 0xf0b263; 0xf1d36f; 0xb7ca83; 0x90c7b4; 0x9eb7d8; 0xc7a5d4; 0xbd985f ]
  ; base16 "electric-violet" "Electric Violet" false
      [ 0x17112c; 0x261b43; 0x423160; 0x8b77b1; 0xb19cd4; 0xddcef3; 0xeee2ff; 0xfcf5ff;
        0xff87b0; 0xffb28b; 0xf5d98e; 0xb6e09a; 0x85e0dc; 0x96b7ff; 0xce9aff; 0xc69aa8 ]
  ; base16 "paper" "Paper" true
      [ 0xf8f6ef; 0xeeeae0; 0xd7d2c5; 0x827d70; 0x615e56; 0x343630; 0x242720; 0x171b15;
        0xa93845; 0xa45d21; 0x826c18; 0x47733b; 0x287b78; 0x356a9c; 0x7758a0; 0x875d42 ]
  ; base16 "porcelain" "Porcelain" true
      [ 0xf5f9fc; 0xe7eff5; 0xcbdbe7; 0x748b9b; 0x526b7b; 0x293f50; 0x1c3040; 0x102130;
        0xb64058; 0xa76228; 0x826b1a; 0x3b7851; 0x187c86; 0x2e68a8; 0x7953a5; 0x8b604a ]
  ; base16 "linen" "Linen" true
      [ 0xf7efdf; 0xebe0cb; 0xd3c3a8; 0x92836c; 0x6e604e; 0x40392f; 0x30291f; 0x211c14;
        0xa8463c; 0xa4672c; 0x877020; 0x58743a; 0x387b70; 0x476d93; 0x825c91; 0x8d6541 ]
  ; base16 "mint-paper" "Mint Paper" true
      [ 0xeff8ef; 0xdfeee1; 0xbfd7c4; 0x759780; 0x51765d; 0x2c4938; 0x1c3627; 0x10261a;
        0xb13f55; 0xa36530; 0x807322; 0x347541; 0x217f75; 0x376aa2; 0x79569c; 0x8b654c ]
  ; base16 "lavender-page" "Lavender Page" true
      [ 0xf8f2fc; 0xede2f4; 0xd6c6e2; 0x9781a6; 0x725d82; 0x44324f; 0x33223f; 0x241430;
        0xb23b62; 0xa96135; 0x87701f; 0x4b784c; 0x2a7c82; 0x4266a8; 0x8051ae; 0x92604f ]
  ; base16 "peach-page" "Peach Page" true
      [ 0xfff2e9; 0xf4e2d5; 0xe1c6b4; 0xa58670; 0x80634f; 0x503b2e; 0x3c291e; 0x2b1b12;
        0xb13d42; 0xae6027; 0x89701b; 0x58783d; 0x2c7d78; 0x436c9d; 0x8657a0; 0x96603e ]
  ; base16 "blueprint-day" "Blueprint Day" true
      [ 0xedf4ff; 0xdce9fa; 0xb9cfea; 0x718cb2; 0x4b6890; 0x263f64; 0x172d4e; 0x0b1c37;
        0xb33655; 0xa45c29; 0x856b15; 0x3c744c; 0x167986; 0x235fae; 0x7450a5; 0x865c48 ]
  ; base16 "sandstone" "Sandstone" true
      [ 0xf3e8d2; 0xe5d7ba; 0xcbb994; 0x97815b; 0x735f3f; 0x493b27; 0x372b1a; 0x271e10;
        0xa83d32; 0xa66120; 0x826816; 0x597136; 0x37756a; 0x42658b; 0x7a548a; 0x8b5a32 ]
  ; base16 "sea-glass" "Sea Glass" true
      [ 0xedf9f7; 0xdaeeeb; 0xb9d7d3; 0x719991; 0x4c786f; 0x284c45; 0x19392f; 0x0c281f;
        0xb13f59; 0xa26532; 0x81721f; 0x3d794a; 0x167e7c; 0x356c9d; 0x795b9c; 0x8c6549 ]
  ; base16 "rose-quartz" "Rose Quartz" true
      [ 0xfcf1f4; 0xf1dfe6; 0xdec0cf; 0xa47e93; 0x805b71; 0x503449; 0x3c2335; 0x2a1524;
        0xb33862; 0xa75f36; 0x857020; 0x4e784c; 0x2d7c7b; 0x4768a0; 0x8250a2; 0x93604f ]
  ; base16 "chalkboard" "Chalkboard" false
      [ 0x17201d; 0x26332d; 0x3d5147; 0x819b8b; 0xacc2b0; 0xdfe9d5; 0xeef5e4; 0xfcffef;
        0xe99b94; 0xe7bc8e; 0xe6d79d; 0xb6d5a0; 0x99d5c9; 0xa0bfe2; 0xc5b0df; 0xbea488 ]
  ; base16 "terminal-amber" "Terminal Amber" false
      [ 0x170f00; 0x2b1c00; 0x4c3305; 0x997126; 0xc29139; 0xe7b958; 0xf4ce7a; 0xffe4a6;
        0xf5ad42; 0xe8a746; 0xffd16a; 0xd4a954; 0xe6b960; 0xf5c56c; 0xdbad61; 0xc49646 ]
  ; base16 "terminal-green" "Terminal Green" false
      [ 0x061307; 0x102712; 0x214a25; 0x4d8b51; 0x72b574; 0x9fdb98; 0xbbedad; 0xddffd0;
        0x9fdb98; 0x84c682; 0xc0eeae; 0xa5df9b; 0x8fd58a; 0xb0e8a5; 0x9bd894; 0x79be78 ]
  ; base16 "graphite" "Graphite" false
      [ 0x141414; 0x242424; 0x404040; 0x808080; 0xababab; 0xd4d4d4; 0xe8e8e8; 0xffffff;
        0xbdbdbd; 0xc8c8c8; 0xe0e0e0; 0xc4c4c4; 0xb8b8b8; 0xeeeeee; 0xd0d0d0; 0xa8a8a8 ]
  ; base16 "newsprint" "Newsprint" true
      [ 0xf5f5f5; 0xe7e7e7; 0xcdcdcd; 0x858585; 0x606060; 0x333333; 0x222222; 0x111111;
        0x444444; 0x505050; 0x585858; 0x484848; 0x5b5b5b; 0x292929; 0x3d3d3d; 0x626262 ]
  ; base16 "silver-night" "Silver Night" false
      [ 0x080808; 0x181818; 0x383838; 0x777777; 0xaaaaaa; 0xe2e2e2; 0xf2f2f2; 0xffffff;
        0xd8d8d8; 0xbebebe; 0xeeeeee; 0xcacaca; 0xb4b4b4; 0xf4f4f4; 0xd0d0d0; 0xa0a0a0 ]
  ; base16 "ivory-ink" "Ivory Ink" true
      [ 0xffffff; 0xf0f0f0; 0xd5d5d5; 0x888888; 0x555555; 0x181818; 0x0c0c0c; 0x000000;
        0x303030; 0x444444; 0x484848; 0x383838; 0x525252; 0x202020; 0x282828; 0x606060 ]
  ; base16 "ochre-study" "Ochre Study" false
      [ 0x201b13; 0x312b1d; 0x50462e; 0x99875a; 0xc0ac7c; 0xe8d7a9; 0xf4e6c3; 0xfff6df;
        0xd7ad73; 0xe5b979; 0xf1d394; 0xc7bb83; 0xbcba91; 0xe3cb9a; 0xd2b58b; 0xb99b6b ]
  ]
[@@ocamlformat "disable"]

(* Adapted from btop at 5d03929 (Apache-2.0; https://github.com/aristocratos/btop). Btop's
   distinct meter/graph hues become Silver's metric, activity and search inks. Silver adds
   neutral card and surface steps, and adjusts inks for text contrast rather than
   reproducing the meter gradients. *)
let btop_theme
  ~key
  ~label
  ~is_light
  ~background
  ~foreground
  ~selection
  ~muted
  ~border
  ~accent
  ~metric
  ~success
  ~warning
  ~failure
  ~heading
  ~monitor
  =
  let card = mix background foreground 5 in
  let surface = mix background foreground 9 in
  let theme =
    make
      ~key
      ~label
      ~is_light
      ~background
      ~foreground
      ~surface
      ~card
      ~selection
      ~muted
      ~border
      ~accent
      ~metric
      ~success
      ~warning
      ~failure
  in
  let text = text_ink ~is_light ~background ~card ~surface ~selection in
  { theme with
    palette =
      { theme.palette with
        heading = text heading
      ; monitor =
          Some
            { selected = text monitor.selected
            ; running = text monitor.running
            ; search_match = text monitor.search_match
            }
      }
  }
;;

let btop =
  [ (* src/btop_theme.cpp: Default_theme, Aristocratos *)
    btop_theme ~key:"btop-default" ~label:"btop Default" ~is_light:false
      ~background:0x000000 ~foreground:0xcccccc ~selection:0x6a2f2f ~muted:0x606060
      ~border:0x556d59 ~accent:0xb54040 ~metric:0xb0a9de ~success:0xb5e685
      ~warning:0xffd77a ~failure:0xff4769 ~heading:0xeeeeee
      ~monitor:{ selected = 0xeeeeee; running = 0x74e6fc; search_match = 0xdcafde }
  ; (* themes/kanagawa-wave.theme, philikarus *)
    btop_theme ~key:"btop-kanagawa-wave" ~label:"btop Kanagawa Wave" ~is_light:false
      ~background:0x16161d ~foreground:0xdcd7ba ~selection:0x223249 ~muted:0x727169
      ~border:0x727169 ~accent:0x7e9cdb ~metric:0x957fbb ~success:0x98bb6c
      ~warning:0xe6c384 ~failure:0xff5d62 ~heading:0xdcd7ba
      ~monitor:{ selected = 0xdca561; running = 0x7aa89f; search_match = 0x7fb4ca }
  ; (* themes/flexoki-light.theme, Steph Ango *)
    btop_theme ~key:"btop-flexoki-light" ~label:"btop Flexoki Light" ~is_light:true
      ~background:0xfffcf0 ~foreground:0x343331 ~selection:0xe6e4d9 ~muted:0x6f6e69
      ~border:0xcecdc3 ~accent:0xbc5215 ~metric:0x5e409d ~success:0x66800b
      ~warning:0xad8301 ~failure:0xaf3029 ~heading:0x100f0f
      ~monitor:{ selected = 0x100f0f; running = 0x24837b; search_match = 0xa02f6f }
  ]
[@@ocamlformat "disable"]

let all =
  [ silver_dark; silver_light ]
  @ silver_variants
  @ btop
  @ [ carbon; slate; crimson; neon ]
  @ cobalt
;;

let by_key = List.map all ~f:(fun t -> t.key, t) |> String.Map.of_alist_exn
let find key = Map.find by_key (normalize key)

let%test_unit "all Cobalt themes are present, including the disambiguated Crimson" =
  assert (List.length cobalt = 58);
  assert (List.count cobalt ~f:is_light = 20);
  assert (String.equal (List.hd_exn all).key "silver-dark");
  assert (is_light silver_light);
  let port = Option.value_exn (find "  COBALT_Crimson  ") in
  assert (String.equal port.label "Cobalt Crimson");
  assert (not (Poly.equal port.palette crimson.palette));
  assert (not (List.contains_dup (List.map all ~f:palette) ~compare:Poly.compare))
;;

let%test_unit "new palettes keep text readable on every ground, with quieter borders" =
  List.iter
    ([ silver_dark; silver_light ] @ silver_variants @ btop @ cobalt)
    ~f:(fun theme ->
      let p = theme.palette in
      let grounds = [ p.background; p.surface; p.card ] in
      let text =
        [ p.foreground
        ; p.heading
        ; p.muted
        ; p.accent
        ; p.selective
        ; p.metric
        ; p.success
        ; p.warning
        ; p.failure
        ]
        @ Option.value_map p.monitor ~default:[] ~f:(fun m ->
          [ m.selected; m.running; m.search_match ])
      in
      assert (
        Bool.equal theme.is_light Float.(luminance p.background > luminance p.foreground));
      List.iter grounds ~f:(fun bg -> assert (Float.(contrast p.border bg >= 3.)));
      List.iter (p.selection :: grounds) ~f:(fun bg ->
        List.iter text ~f:(fun fg ->
          if Float.(contrast fg bg < 4.5)
          then failwithf "%s: #%06x on #%06x is below 4.5:1" theme.key fg bg ()));
      assert (Float.(contrast p.selection p.background >= 1.2)))
;;

let%test_unit "btop monitor inks distinguish focus, selection, activity, search and \
               metrics"
  =
  assert (List.length btop = 3);
  List.iter btop ~f:(fun theme ->
    let p = theme.palette in
    let m = Option.value_exn p.monitor in
    assert (
      not
        (List.contains_dup
           [ p.accent; m.selected; m.running; m.search_match; p.metric ]
           ~compare:Int.compare)))
;;
