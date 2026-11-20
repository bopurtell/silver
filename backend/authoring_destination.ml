open! Core

(* All mutation paths are relative to an open directory via Linux procfs, as in
   Asic_workloads_storage. Never follow a client-selected symlink, including the final
   destination; O_EXCL also protects individual outputs at creation time. *)
exception Invalid of string
exception Changed of string

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
  ; catalog_exists : bool
  ; directories : (string * (int * int)) list
  ; dune : ((int * int) * Time_ns.t * string) option
  }
[@@deriving equal, sexp_of]

module Integration = Hardcaml_workbench_project_integration

let catalog = "hardcaml-asic-targets.json"
let catalog_exists s = s.catalog_exists
let design_dir name = "asic_" ^ name

let existing_project dir name =
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
    [ Integration.Asic_config.filename; Integration.Preparation_config.filename ]
  in
  List.iter configs ~f:(absent dir);
  let common =
    match stat dir ".workbench" with
    | None -> None
    | Some s when Poly.equal s.st_kind S_DIR ->
      let path, via = child dir ".workbench" in
      with_dir ~path ~via ~identity:(id s) (fun d _ -> List.iter configs ~f:(absent d));
      Some (id s)
    | Some _ -> invalid "Expected plain directory: .workbench"
  in
  marker, common, Option.is_some (regular catalog)
;;

type addition =
  | Ip of string
  | Module of string list * string

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

let addition_project dir addition =
  let regular dir name =
    match inspect (snd (child dir name)) with
    | Some s when Poly.equal s.st_kind S_REG -> id s
    | _ -> invalid ("Expected regular file: " ^ name)
  in
  let marker = regular dir "dune-project" in
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
           walk d ((String.concat ~sep:"/" rel, id s) :: dirs) rel rest finish)
       | _ -> invalid ("Expected plain directory: " ^ path))
  in
  let directories, dune =
    match addition with
    | Ip name ->
      if Option.is_none (inspect (snd (child dir "ip")))
      then [], None
      else
        walk dir [] [] [ "ip" ] (fun d dirs ->
          absent d name;
          dirs, None)
    | Module (parts, name) ->
      walk dir [] [] parts (fun d dirs ->
        absent d (name ^ ".ml");
        let identity = regular d "dune" in
        let path, via = child d "dune" in
        let fd = Core_unix.openfile via ~mode:[ O_RDONLY; O_CLOEXEC; O_NONBLOCK ] in
        Exn.protect
          ~finally:(fun () -> Core_unix.close fd)
          ~f:(fun () ->
            let stat = Core_unix.fstat fd in
            if not
                 (Poly.equal identity (id stat)
                  && Poly.equal stat.st_kind S_REG
                  && Int64.(stat.st_size <= 65536L)
                  && String.equal
                       path
                       (Core_unix.readlink
                          ("/proc/self/fd/"
                           ^ Int.to_string (Core_unix.File_descr.to_int fd))))
            then invalid "Library dune file changed or exceeds size limit";
            let ctime () = (Core_unix.Ns_precision.fstat fd).st_ctime in
            let before = ctime () in
            let buf = Bytes.create (Int64.to_int_exn stat.st_size) in
            let rec read pos =
              if pos < Bytes.length buf
              then (
                let n = Core_unix.read fd ~buf ~pos ~len:(Bytes.length buf - pos) in
                if n = 0 then changed "Library dune file changed";
                read (pos + n))
            in
            read 0;
            if not (Time_ns.equal before (ctime ()))
            then changed "Library dune file changed";
            dirs, Some (identity, before, Bytes.to_string buf)))
  in
  Some marker, directories, dune
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

let visit ?existing ?addition (root : root) parts f =
  let rec walk dir dh parts =
    match parts with
    | [] ->
      let marker, common, catalog_exists, directories, dune =
        match addition, existing with
        | Some addition, _ ->
          let marker, directories, dune = addition_project dir addition in
          marker, None, false, directories, dune
        | None, None ->
          require_empty dh;
          None, None, false, [], None
        | None, Some name ->
          let marker, common, catalog = existing_project dir name in
          marker, common, catalog, [], None
      in
      let stat = Core_unix.Ns_precision.fstat (Core_unix.dirfd dh) in
      f
        dir
        { ancestor = dir.identity
        ; destination_ctime = Some stat.st_ctime
        ; missing = []
        ; marker
        ; common
        ; catalog_exists
        ; directories
        ; dune
        }
    | name :: rest ->
      let path, via = child dir name in
      (match inspect via with
       | None ->
         if Option.is_some existing || Option.is_some addition
         then invalid "Existing Dune project root not found";
         f
           dir
           { ancestor = dir.identity
           ; destination_ctime = None
           ; missing = parts
           ; marker = None
           ; common = None
           ; catalog_exists = false
           ; directories = []
           ; dune = None
           }
       | Some s when Poly.equal s.st_kind S_DIR ->
         with_dir ~path ~via ~identity:(id s) (fun d h -> walk d h rest)
       | Some _ -> invalid "Destination component is not a plain directory")
  in
  with_dir ~path:root.path ~via:root.path ~identity:root.identity (fun d h ->
    walk d h parts)
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

(* A group opens each freshly created directory once. Never adopt a directory supplied by
   a racing writer, even when several planned files share it. *)
let publish dir snapshot files ~on_mkdir ~on_create =
  let rec group dir rel entries =
    let children = String.Table.create () in
    List.iter
      entries
      ~f:(fun (parts, (file : Hardcaml_workbench_protocol.Authoring.File.t)) ->
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
        if String.equal key ".workbench" && Option.is_some snapshot.common
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
    (List.map files ~f:(fun (f : Hardcaml_workbench_protocol.Authoring.File.t) ->
       String.split f.path ~on:'/', f))
;;
