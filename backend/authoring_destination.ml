open! Core

(* All mutation paths are relative to an open directory via Linux procfs, as in
   Asic_workloads_storage. Never follow a client-selected symlink, including the final
   destination; O_EXCL also protects individual outputs at creation time. *)
exception Invalid of string
exception Changed of string
exception Unsupported_bluespec_project

let invalid msg = raise (Invalid msg)
let changed msg = raise (Changed msg)
let id (s : Core_unix.stats) = s.st_dev, s.st_ino

type root =
  { path : string
  ; identity : int * int
  }

let root requested =
  let path = Filename_unix.realpath requested in
  let s = Core_unix.stat path in
  if not (Poly.equal s.st_kind S_DIR) then invalid "Permitted root is not a directory";
  { path; identity = id s }
;;

let components path =
  if String.length path > 4096
     || String.contains path '\000'
     || not (Filename.is_absolute path)
  then invalid "Destination must be an absolute service-host path";
  let parts = String.split path ~on:'/' |> List.filter ~f:(Fn.non String.is_empty) in
  if List.length parts > 128 || List.exists parts ~f:(fun p -> String.length p > 255)
  then invalid "Destination exceeds component limits";
  if List.exists parts ~f:(fun p -> String.equal p "." || String.equal p "..")
  then invalid "Destination cannot contain . or ..";
  parts
;;

let select roots path =
  let parts = components path in
  List.find_map roots ~f:(fun root ->
    let prefix = components root.path in
    if List.is_prefix parts ~prefix ~equal:String.equal
    then Some (root, List.drop parts (List.length prefix))
    else None)
  |> Option.value_or_thunk ~default:(fun () ->
    invalid "Destination outside permitted roots")
;;

type dir =
  { path : string
  ; via : string
  ; identity : int * int
  }

let check_location dir =
  if not (String.equal (Core_unix.readlink dir.via) dir.path)
  then changed "Directory moved during authoring"
;;

let with_dir ~path ~via ~identity f =
  let dh = Core_unix.opendir via in
  Exn.protect
    ~finally:(fun () -> Core_unix.closedir dh)
    ~f:(fun () ->
      let fd = Core_unix.dirfd dh in
      let via = "/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd) in
      if not (Poly.equal (id (Core_unix.fstat fd)) identity)
      then changed "Directory identity changed";
      let dir = { path; via; identity } in
      check_location dir;
      f dir dh)
;;

let child dir name = Filename.concat dir.path name, Filename.concat dir.via name

let inspect path =
  try Some (Core_unix.lstat path) with
  | Core_unix.Unix_error (ENOENT, _, _) -> None
;;

let require_empty dh =
  let rec loop () =
    match Core_unix.readdir_opt dh with
    | None -> ()
    | Some ("." | "..") -> loop ()
    | Some _ -> changed "Destination is occupied"
  in
  loop ()
;;

(* The nearest existing ancestor and the entire missing suffix are preconditions. A new
   empty directory at a previously absent destination is a collision too. *)
type snapshot =
  { ancestor : int * int
  ; destination_ctime : Time_ns.t option
  ; missing : string list
  ; marker : (int * int) option
  ; common : (int * int) option
  ; catalog_state : ((int * int) * Time_ns.t * string) option
  ; configs_absent : bool
  ; library_inputs : ((int * int) * Time_ns.t * string) list
  ; directories : (string * (int * int)) list
  ; dune : ((int * int) * Time_ns.t * string) option
  ; inputs : (string list * ((int * int) * Time_ns.t * string) option) list
  }
[@@deriving equal, sexp_of]

module Integration = Silver_project_integration

let catalog = "hardcaml-asic-targets.json"
let catalog_text s = Option.map s.catalog_state ~f:(fun (_, _, text) -> text)
let configs_absent s = s.configs_absent
let matches_project s identity = List.is_empty s.missing && Poly.equal s.ancestor identity
let project_identity s = s.ancestor
let design_dir name = "asic_" ^ name

(* Open only bounded regular files beneath the pinned directory and bind the bytes (not
   just the pathname or size) to the authoring receipt. *)
let read_regular ?(limit = 262144) ?(opaque_if_large = false) dir name =
  let path, via = child dir name in
  let expected =
    match inspect via with
    | Some s when Poly.equal s.st_kind S_REG -> id s
    | _ -> invalid ("Expected regular file: " ^ path)
  in
  let fd = Core_unix.openfile via ~mode:[ O_RDONLY; O_NONBLOCK; O_CLOEXEC ] in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      let stat = Core_unix.fstat fd in
      if not
           (Poly.equal expected (id stat)
            && Poly.equal stat.st_kind S_REG
            && (opaque_if_large || Int64.(stat.st_size <= of_int limit))
            && String.equal
                 path
                 (Core_unix.readlink
                    ("/proc/self/fd/" ^ Int.to_string (Core_unix.File_descr.to_int fd))))
      then invalid ("File moved or exceeds authoring limit: " ^ path);
      let ctime () = (Core_unix.Ns_precision.fstat fd).st_ctime in
      let before = ctime () in
      (* An oversized catalog is opaque/manual. Still bind the identity and ctime so apply
         cannot turn it into an automatic registration. *)
      let size =
        if Int64.(stat.st_size > of_int limit) then 0 else Int64.to_int_exn stat.st_size
      in
      let buf = Bytes.create size in
      let rec loop pos =
        if pos < Bytes.length buf
        then (
          let n = Core_unix.read fd ~buf ~pos ~len:(Bytes.length buf - pos) in
          if n = 0 then changed ("File changed: " ^ path);
          loop (pos + n))
      in
      loop 0;
      if not (Time_ns.equal before (ctime ())) then changed ("File changed: " ^ path);
      expected, before, Bytes.to_string buf)
;;

let existing_project dir name ~configs_required =
  let stat dir name = inspect (snd (child dir name)) in
  let absent dir name =
    if Option.is_some (stat dir name) then changed ("Conflict: " ^ fst (child dir name))
  in
  let regular name =
    match stat dir name with
    | None -> None
    | Some s when Poly.equal s.st_kind S_REG -> Some (id s)
    | Some _ -> invalid ("Expected regular file: " ^ name)
  in
  let marker = regular "dune-project" in
  if Option.is_none marker then invalid "Expected existing dune-project at destination";
  absent dir (design_dir name);
  let configs =
    [ Integration.Asic_config.filename; Integration.Preparation_config.filename
    ; "hardcaml-workbench-asic.sexp"; "hardcaml-workbench-preparation.sexp" ]
  in
  let configs_absent = ref true in
  let check_configs dir =
    List.iter configs ~f:(fun name ->
      if Option.is_some (stat dir name)
      then (
        configs_absent := false;
        if configs_required then absent dir name))
  in
  check_configs dir;
  let check_directory name =
    match stat dir name with
    | None -> None
    | Some s when Poly.equal s.st_kind S_DIR ->
      let path, via = child dir name in
      with_dir ~path ~via ~identity:(id s) (fun d _ -> check_configs d);
      Some (id s)
    | Some _ -> invalid ("Expected plain directory: " ^ name)
  in
  let common = check_directory ".silver" in
  ignore (check_directory ".workbench");
  ( marker
  , common
  , Option.map (regular catalog) ~f:(fun _ ->
      read_regular ~opaque_if_large:true dir catalog)
  , !configs_absent )
;;

type addition =
  | Ip of string
  | Module of string list * string
  | Bazel_ip of string
  | Bazel_module of string list * string
  | Flow of
      { inputs : string list list
      ; output : string list option
      }

let module_directory path =
  if String.equal path "."
  then []
  else (
    let parts = String.split path ~on:'/' in
    if String.length path > 1024
       || List.length parts > 32
       || List.exists parts ~f:(fun p ->
         String.is_empty p
         || String.length p > 255
         || List.mem [ "."; ".."; ".git"; "_build" ] p ~equal:String.Caseless.equal
         || not
              (String.for_all p ~f:(function
                | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
                | _ -> false)))
    then invalid "Expected a project-relative library directory";
    parts)
;;

let read_bazel_manifest dir =
  let module Manifest = Integration.Silver_manifest in
  let directory = Filename.dirname Manifest.relative_path in
  let filename = Filename.basename Manifest.relative_path in
  let path, via = child dir directory in
  match inspect via with
  | None -> None
  | Some s when Poly.equal s.st_kind S_DIR ->
    let identity = id s in
    with_dir ~path ~via ~identity (fun dir _ ->
      Option.map (inspect (snd (child dir filename))) ~f:(fun _ ->
        let entry =
          read_regular ~limit:Integration.Config_location.max_config_bytes dir filename
        in
        identity, [ directory; filename ], entry))
  | Some _ -> invalid ("Expected plain directory: " ^ path)
;;

let addition_project dir addition =
  let bazel =
    match addition with
    | Bazel_ip _ | Bazel_module _ -> true
    | Ip _ | Module _ | Flow _ -> false
  in
  let regular dir name =
    match inspect (snd (child dir name)) with
    | Some s when Poly.equal s.st_kind S_REG -> id s
    | _ -> invalid ("Expected regular file: " ^ name)
  in
  let absent dir name =
    if Option.is_some (inspect (snd (child dir name)))
    then changed ("Conflict: " ^ fst (child dir name))
  in
  let rec walk dir dirs rel parts finish =
    match parts with
    | [] -> finish dir dirs
    | p :: rest ->
      let path, via = child dir p in
      (match inspect via with
       | Some s when Poly.equal s.st_kind S_DIR ->
          let rel = rel @ [ p ] in
          with_dir ~path ~via ~identity:(id s) (fun d _ ->
            if bazel
               && List.exists
                    [ "MODULE.bazel"; "REPO.bazel"; "WORKSPACE.bazel"; "WORKSPACE" ]
                    ~f:(fun marker -> Option.is_some (inspect (snd (child d marker))))
            then invalid ("Authoring cannot cross a nested Bazel repository: " ^ path);
            walk d ((String.concat ~sep:"/" rel, id s) :: dirs) rel rest finish)
       | _ -> invalid ("Expected plain directory: " ^ path))
  in
  let captured_inputs = ref [] in
  let marker =
    if not bazel
    then (
      (match addition with
       | Ip _ | Module _ when Option.is_some (read_bazel_manifest dir) ->
         changed "Project build system changed"
       | _ -> ());
      regular dir "dune-project")
    else (
      let module Manifest = Integration.Silver_manifest in
      let manifest_identity, path, entry =
        match read_bazel_manifest dir with
        | Some manifest -> manifest
        | None -> invalid ("Expected " ^ Manifest.relative_path)
      in
      let _, _, text = entry in
      let manifest =
        match Manifest.parse_string text with
        | Ok manifest -> manifest
        | Error reason -> invalid (Manifest.relative_path ^ ": " ^ reason)
      in
      let has_starter_layout () =
        List.for_all Manifest.bluespec_starter_files ~f:(fun name ->
          match inspect (snd (child dir name)) with
          | Some s -> Poly.equal s.st_kind S_REG
          | None -> false)
      in
      if not (Manifest.is_bluespec_classic manifest ~has_starter_layout)
      then raise Unsupported_bluespec_project;
      captured_inputs := (path, Some entry) :: !captured_inputs;
      manifest_identity)
  in
  let directories, dune =
    match addition with
    | Flow { inputs; output } ->
      let dirs = String.Table.create () in
      let rec probe dir prefix parts finish =
        match parts with
        | [] -> invalid "Empty flow path"
        | [ name ] -> finish dir name
        | p :: rest ->
          let path, via = child dir p in
          (match inspect via with
           | None -> None
           | Some s when Poly.equal s.st_kind S_DIR ->
             let prefix = prefix @ [ p ] in
             Hashtbl.set dirs ~key:(String.concat ~sep:"/" prefix) ~data:(id s);
             with_dir ~path ~via ~identity:(id s) (fun d _ -> probe d prefix rest finish)
           | _ -> invalid ("Expected plain directory: " ^ path))
      in
       captured_inputs
      := List.map inputs ~f:(fun parts ->
           ( parts
           , probe dir [] parts (fun d n ->
               Option.map (inspect (snd (child d n))) ~f:(fun _ -> read_regular d n)) ));
      Option.iter output ~f:(fun parts ->
        ignore
          (probe dir [] parts (fun d n ->
             absent d n;
             None)
           : unit option));
      ( List.sort (Hashtbl.to_alist dirs) ~compare:(Comparable.lift String.compare ~f:fst)
      , None )
    | Ip name | Bazel_ip name ->
      if Option.is_none (inspect (snd (child dir "ip")))
      then [], None
      else
        walk dir [] [] [ "ip" ] (fun d dirs ->
          absent d name;
          dirs, None)
    | Module (parts, name) ->
      walk dir [] [] parts (fun d dirs ->
        absent d (name ^ ".ml");
        dirs, Some (read_regular ~limit:65536 d "dune"))
    | Bazel_module (parts, name) ->
      walk dir [] [] parts (fun d dirs ->
        absent d (Authoring_bluespec.filename name);
        absent d (Authoring_bluespec.package_name name ^ ".bsv");
        let build =
          if Option.is_some (inspect (snd (child d "BUILD.bazel")))
          then "BUILD.bazel"
          else (
             captured_inputs := (parts @ [ "BUILD.bazel" ], None) :: !captured_inputs;
            "BUILD")
        in
        let entry = read_regular ~opaque_if_large:true d build in
         captured_inputs := (parts @ [ build ], Some entry) :: !captured_inputs;
        dirs, None)
  in
  Some marker, directories, dune, !captured_inputs
;;

let input_text s parts =
  List.Assoc.find_exn s.inputs parts ~equal:(List.equal String.equal)
  |> Option.map ~f:(fun (_, _, text) -> text)
;;

let bazel_library s parts =
  List.find_map [ "BUILD.bazel"; "BUILD" ] ~f:(fun name ->
    List.find_map s.inputs ~f:(fun (path, entry) ->
      if List.equal String.equal path (parts @ [ name ])
      then Option.map entry ~f:(fun (_, _, text) -> String.concat ~sep:"/" path, text)
      else None))
  |> Option.value_exn
;;

let manual_modules snapshot =
  let _, _, text = Option.value_exn snapshot.dune in
  let stanzas =
    try Sexp.of_string_many text with
    | _ -> invalid "Cannot parse library dune file"
  in
  match
    List.filter_map stanzas ~f:(function
      | Sexp.List (Atom "library" :: fields) -> Some fields
      | _ -> None)
  with
  | [ fields ] ->
    if not
         (List.exists fields ~f:(function
           | Sexp.List [ Atom ("name" | "public_name"); Atom _ ] -> true
           | _ -> false))
    then invalid "Expected named Dune library";
    List.exists fields ~f:(function
      | Sexp.List (Atom "modules" :: _) -> true
      | _ -> false)
  | _ -> invalid "Expected exactly one explicit library in selected dune file"
;;

let library_inputs dir parts =
  let rec walk dir = function
    | [] ->
      List.map [ "dune"; "chip-interface.json"; "block.ml" ] ~f:(read_regular dir)
      @
        (match inspect (snd (child dir "block.mli")) with
        | Some _ -> [ read_regular dir "block.mli" ]
        | None -> [])
    | part :: rest ->
      let path, via = child dir part in
      (match inspect via with
       | Some s when Poly.equal s.st_kind S_DIR ->
         with_dir ~path ~via ~identity:(id s) (fun dir _ -> walk dir rest)
       | _ -> invalid ("Expected library directory: " ^ path))
  in
  walk dir parts
;;

let library_text s = List.map s.library_inputs ~f:(fun (_, _, text) -> text)

let walk_destination (root : root) parts ~found ~missing =
  let rec walk dir dh = function
    | [] -> found dir dh
    | name :: rest as parts ->
      let path, via = child dir name in
      (match inspect via with
       | None -> missing dir parts
       | Some s when Poly.equal s.st_kind S_DIR ->
         with_dir ~path ~via ~identity:(id s) (fun d h -> walk d h rest)
       | Some _ -> invalid "Destination component is not a plain directory")
  in
  with_dir ~path:root.path ~via:root.path ~identity:root.identity (fun d h ->
    walk d h parts)
;;

let source_project root parts =
  walk_destination
    root
    parts
    ~found:(fun dir _ -> dir.identity, Option.is_some (read_bazel_manifest dir))
    ~missing:(fun _ _ -> invalid "Existing project root not found")
;;

let visit ?existing ?addition ?library ?(configs_required = true) root parts f =
  walk_destination
    root
    parts
    ~found:(fun dir dh ->
      let marker, common, catalog_state, configs_absent, directories, dune, inputs =
        match addition, existing with
        | Some addition, _ ->
          let marker, directories, dune, inputs = addition_project dir addition in
          marker, None, None, false, directories, dune, inputs
        | None, None ->
          require_empty dh;
          None, None, None, true, [], None, []
        | None, Some name ->
          let marker, common, catalog, configs_absent =
            existing_project dir name ~configs_required
          in
          marker, common, catalog, configs_absent, [], None, []
      in
      let stat = Core_unix.Ns_precision.fstat (Core_unix.dirfd dh) in
      f
        dir
        { ancestor = dir.identity
        ; destination_ctime = Some stat.st_ctime
        ; missing = []
        ; marker
        ; common
        ; catalog_state
        ; configs_absent
        ; library_inputs = Option.value_map library ~default:[] ~f:(library_inputs dir)
        ; directories
        ; dune
        ; inputs
        })
    ~missing:(fun dir parts ->
      if Option.is_some existing || Option.is_some addition
      then invalid "Existing project root not found";
      f
        dir
        { ancestor = dir.identity
        ; destination_ctime = None
        ; missing = parts
        ; marker = None
        ; common = None
        ; catalog_state = None
        ; configs_absent = true
        ; library_inputs = []
        ; directories = []
        ; dune = None
        ; inputs = []
        })
;;

let rec mkdir_missing ~on_mkdir dir missing f =
  match missing with
  | [] ->
    check_location dir;
    f dir
  | name :: rest ->
    check_location dir;
    let path, via = child dir name in
    Core_unix.mkdir via ~perm:0o755;
    on_mkdir path;
    let s = Core_unix.lstat via in
    if not (Poly.equal s.st_kind S_DIR) then changed "Created directory changed";
    with_dir ~path ~via ~identity:(id s) (fun d h ->
      require_empty h;
      mkdir_missing ~on_mkdir d rest f)
;;

let materialize ~on_mkdir dir snapshot f = mkdir_missing ~on_mkdir dir snapshot.missing f

let write dir ~name ~contents ~on_create =
  if String.is_empty name
     || String.contains name '/'
     || String.contains name '\000'
     || String.equal name "."
     || String.equal name ".."
  then invalid "Recipe output must be a single filename";
  check_location dir;
  let _, path = child dir name in
  let fd =
    Core_unix.openfile path ~mode:[ O_WRONLY; O_CREAT; O_EXCL; O_CLOEXEC ] ~perm:0o644
  in
  Exn.protect
    ~finally:(fun () -> Core_unix.close fd)
    ~f:(fun () ->
      on_create ();
      let rec loop pos =
        if pos < String.length contents
        then (
          let n =
            Core_unix.write_substring
              fd
              ~buf:contents
              ~pos
              ~len:(String.length contents - pos)
          in
          if n = 0 then failwith "Cannot complete recipe file";
          loop (pos + n))
      in
      loop 0)
;;

let publish_catalog dir snapshot contents ~on_create =
  match snapshot.catalog_state with
  | None -> write dir ~name:catalog ~contents ~on_create:(fun () -> on_create catalog)
  | Some expected ->
    let scratch =
      ".silver-"
      ^ Cryptokit.transform_string
          (Cryptokit.Hexa.encode ())
          (Cryptokit.Random.string Cryptokit.Random.secure_rng 16)
    in
    let path, via = child dir scratch in
    let _, dst = child dir catalog in
    Core_unix.mkdir via ~perm:0o700;
    let retain = ref false in
    Exn.protect
      ~finally:(fun () -> if not !retain then Core_unix.rmdir via)
      ~f:(fun () ->
        with_dir
          ~path
          ~via
          ~identity:(id (Core_unix.lstat via))
          (fun temp _ ->
            let _, replacement = child temp "new"
            and _, previous = child temp "previous" in
            let made = ref false in
            Exn.protect
              ~finally:(fun () -> if !made then Core_unix.unlink replacement)
              ~f:(fun () ->
                write temp ~name:"new" ~contents ~on_create:(fun () -> made := true);
                check_location dir;
                if not (Poly.equal expected (read_regular dir catalog))
                then changed "Catalog changed since preview";
                (* Capture the actual old entry before installing ours without
                   replacement. A rename over [dst] after a byte comparison would lose an
                   editor's concurrent atomic save in the check-to-rename window. *)
                Core_unix.rename ~src:dst ~dst:previous;
                (try
                   let identity, _, bytes = read_regular temp "previous" in
                   let expected_identity, _, expected_bytes = expected in
                   if not
                        (Poly.equal identity expected_identity
                         && String.equal bytes expected_bytes)
                   then changed "Catalog replaced during publication";
                   Core_unix.chmod
                     replacement
                     ~perm:((Core_unix.stat previous).st_perm land 0o777);
                   Core_unix.link ~target:replacement ~link_name:dst ()
                 with
                 | exn ->
                   (try
                      Core_unix.link ~target:previous ~link_name:dst ();
                      Core_unix.unlink previous
                    with
                    | _ ->
                      retain := true;
                      changed
                        ("Concurrent catalog edit retained; prior catalog preserved at "
                         ^ path
                         ^ "/previous"));
                   raise exn);
                Core_unix.unlink previous)))
;;

(* A group opens each freshly created directory once. Never adopt a directory supplied by
   a racing writer, even when several planned files share it. *)
let publish dir snapshot files ~on_mkdir ~on_create =
  let rec group dir rel entries =
    let children = String.Table.create () in
    List.iter
      entries
      ~f:(fun (parts, (file : Silver_protocol.Authoring.File.t)) ->
        match parts with
        | [ name ] ->
          write dir ~name ~contents:file.contents ~on_create:(fun () ->
            on_create file.path)
        | name :: rest -> Hashtbl.add_multi children ~key:name ~data:(rest, file)
        | [] -> assert false);
    Hashtbl.iteri children ~f:(fun ~key:name ~data ->
      let rel = rel @ [ name ] in
      let descend child = group child rel (List.rev data) in
      let key = String.concat ~sep:"/" rel in
      match
        if String.equal key ".silver" && Option.is_some snapshot.common
        then snapshot.common
        else List.Assoc.find snapshot.directories key ~equal:String.equal
      with
      | Some identity ->
        let path, via = child dir name in
        with_dir ~path ~via ~identity (fun d _ -> descend d)
      | _ -> mkdir_missing ~on_mkdir dir [ name ] descend)
  in
  group
    dir
    []
    (List.map files ~f:(fun (f : Silver_protocol.Authoring.File.t) ->
       String.split f.path ~on:'/', f))
;;
