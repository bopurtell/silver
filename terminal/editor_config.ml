open! Core
module Theme = Cobalt_hosted.Theme
module Layout = Cobalt_hosted.Layout

let default_layout = Or_error.ok_exn (Layout.create ~views:[ Problems, Band ] ())

type fields =
  { schema_version : int [@sexp.default 1]
  ; layout : Layout.t [@sexp.default default_layout]
  ; theme : string [@sexp.default "inherit"]
  }
[@@deriving of_sexp]

type t =
  { layout : Layout.t
  ; theme_override : Theme.t option
  }

let default_text =
  {|; Silver's embedded editor only. Restart Silver after editing this file.
; The source pane is always present. Band puts Problems below it.
; Use (layout ((views ()))) to start with the source pane alone.
; Use inherit for Silver's theme, or a Cobalt theme ID (for example abyss).
((schema_version 1)
 (layout ((views ((Problems Band)))))
 (theme inherit))
|}
;;

let max_bytes = 16 * 1024

let decode contents =
  Or_error.try_with (fun () ->
    if String.length contents > max_bytes then failwith "File exceeds 16 KiB";
    let { schema_version; layout; theme } = fields_of_sexp (Sexp.of_string contents) in
    if schema_version <> 1 then failwith "Unsupported editor configuration schema";
    let theme_override =
      if String.Caseless.equal (String.strip theme) "inherit"
      then None
      else (
        match Theme.find theme with
        | Some theme -> Some theme
        | None -> failwithf "Unknown embedded Cobalt theme %S" theme ())
    in
    { layout; theme_override })
;;

let default = Or_error.ok_exn (decode default_text)

let path ~getenv =
  let absolute variable =
    Option.filter (getenv variable) ~f:(fun path ->
      not (String.is_empty path || Filename.is_relative path))
  in
  Option.first_some
    (absolute "XDG_CONFIG_HOME")
    (Option.map (absolute "HOME") ~f:(fun home -> Filename.concat home ".config"))
  |> Option.map ~f:(fun root -> Filename.concat root "silver/editor.sexp")
;;

let read path =
  let fd = Core_unix.openfile path ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      (match (Core_unix.fstat fd).st_kind with
       | S_REG -> ()
       | _ -> failwith "Expected a regular file");
      let buf = Bytes.create (max_bytes + 1) in
      let rec loop pos =
        if pos > max_bytes then failwith "File exceeds 16 KiB";
        match Core_unix.read ~restart:true ~pos fd ~buf with
        | 0 -> Bytes.sub buf ~pos:0 ~len:pos |> Bytes.to_string
        | count -> loop (pos + count)
      in
      loop 0)
;;

let create_default path =
  Core_unix.mkdir_p (Filename.dirname path) ~perm:0o700;
  let temp, fd = Core_unix.mkstemp path in
  Exn.protect
    ~finally:(fun () -> Core_unix.unlink temp)
    ~f:(fun () ->
      Exn.protect
        ~finally:(fun () -> Core_unix.close fd)
        ~f:(fun () ->
          let rec write pos =
            if pos < String.length default_text
            then (
              let count =
                Core_unix.single_write_substring ~restart:true ~pos fd ~buf:default_text
              in
              if count = 0 then failwith "Unable to write default editor configuration";
              write (pos + count))
          in
          write 0);
      (* Publish only a complete file, and never clobber an existing file, even if another
         Silver instance has just created it. *)
      try Core_unix.link ~target:temp ~link_name:path () with
      | Core_unix.Unix_error (EEXIST, _, _) -> ())
;;

let load ~getenv =
  let loaded =
    match path ~getenv with
    | None ->
      Or_error.error_string "Silver editor config: no absolute XDG_CONFIG_HOME or HOME"
    | Some path ->
      Or_error.try_with (fun () ->
        let contents =
          try read path with
          | Core_unix.Unix_error (ENOENT, _, _) ->
            create_default path;
            read path
        in
        Or_error.ok_exn (decode contents))
      |> Or_error.tag ~tag:("Silver editor config: " ^ path)
  in
  match loaded with
  | Ok config -> config, None
  | Error error -> default, Some error
;;

let%test_unit "embedded editor config is strict and defaults to source and bottom \
               Problems"
  =
  assert (Layout.equal default.layout default_layout);
  assert (Option.is_none default.theme_override);
  let sparse = Or_error.ok_exn (decode "()") in
  assert (Layout.equal sparse.layout default_layout);
  assert (Option.is_none sparse.theme_override);
  let custom = Or_error.ok_exn (decode "((layout ((views ()))) (theme abyss))") in
  assert (Layout.equal custom.layout (Or_error.ok_exn (Layout.create ~views:[] ())));
  assert (String.equal "abyss" (Theme.id (Option.value_exn custom.theme_override)));
  List.iter
    [ "((schema_version 2))"
    ; "((layout ((views ((Problems Right))))))"
    ; "((layout ((views ((Problems Band) (Problems Tab))))))"
    ; "((layout ((views ((History Split) (Vcs Split))))))"
    ; "((theme silver-does-not-exist))"
    ; "((theme abyss) (theme inherit))"
    ; "((unknown field))"
    ; "() ((theme abyss))"
    ; "("
    ; String.make (max_bytes + 1) ' '
    ]
    ~f:(fun input -> assert (Result.is_error (decode input)))
;;

let%test_unit "the config path never inherits a relative root or project directory" =
  let path env =
    path ~getenv:(fun name -> List.Assoc.find env name ~equal:String.equal)
  in
  assert (
    Option.equal
      String.equal
      (path [ "XDG_CONFIG_HOME", "/xdg"; "HOME", "/home/user" ])
      (Some "/xdg/silver/editor.sexp"));
  List.iter [ ""; "relative" ] ~f:(fun xdg ->
    assert (
      Option.equal
        String.equal
        (path [ "XDG_CONFIG_HOME", xdg; "HOME", "/home/user" ])
        (Some "/home/user/.config/silver/editor.sexp")));
  assert (Option.is_none (path [ "HOME", "." ]))
;;

let%test_unit "first use creates editable defaults, never rewrites or trusts invalid \
               config"
  =
  let root =
    Core_unix.mkdtemp (Filename.concat Filename.temp_dir_name "silver-editor-")
  in
  let getenv = function
    | "XDG_CONFIG_HOME" -> Some root
    | _ -> None
  in
  let path = Option.value_exn (path ~getenv) in
  Exn.protect
    ~finally:(fun () ->
      Core_unix.unlink path;
      Core_unix.rmdir (Filename.dirname path);
      Core_unix.rmdir root)
    ~f:(fun () ->
      let config, warning = load ~getenv in
      assert (Option.is_none warning);
      assert (Layout.equal config.layout default_layout);
      assert (String.equal (In_channel.read_all path) default_text);
      let data = "((layout ((views ((History Band)))))(theme abyss))\n" in
      Out_channel.write_all path ~data;
      create_default path;
      let config, warning = load ~getenv in
      assert (Option.is_none warning);
      assert (
        Layout.equal
          config.layout
          (Or_error.ok_exn (Layout.create ~views:[ History, Band ] ())));
      assert (String.equal (In_channel.read_all path) data);
      Out_channel.write_all path ~data:"(";
      let config, warning = load ~getenv in
      assert (Layout.equal config.layout default_layout);
      assert (Option.is_none config.theme_override);
      assert (
        String.is_substring
          (Error.to_string_hum (Option.value_exn warning))
          ~substring:path);
      assert (String.equal (In_channel.read_all path) "(");
      Core_unix.unlink path;
      Core_unix.mkfifo path ~perm:0o600;
      let config, warning = load ~getenv in
      assert (Layout.equal config.layout default_layout);
      assert (Option.is_some warning))
;;
