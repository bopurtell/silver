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
  }
[@@deriving equal, sexp_of]

let visit (root : root) parts f =
  let rec walk dir dh parts =
    match parts with
    | [] ->
      require_empty dh;
      let stat = Core_unix.Ns_precision.fstat (Core_unix.dirfd dh) in
      f
        dir
        { ancestor = dir.identity; destination_ctime = Some stat.st_ctime; missing = [] }
    | name :: rest ->
      let path, via = child dir name in
      (match inspect via with
       | None ->
         f dir { ancestor = dir.identity; destination_ctime = None; missing = parts }
       | Some s when Poly.equal s.st_kind S_DIR ->
         with_dir ~path ~via ~identity:(id s) (fun d h -> walk d h rest)
       | Some _ -> invalid "Destination component is not a plain directory")
  in
  with_dir ~path:root.path ~via:root.path ~identity:root.identity (fun d h ->
    walk d h parts)
;;

let rec mkdir_missing dir missing f =
  match missing with
  | [] ->
    check_location dir;
    f dir
  | name :: rest ->
    check_location dir;
    let path, via = child dir name in
    Core_unix.mkdir via ~perm:0o755;
    let s = Core_unix.lstat via in
    if not (Poly.equal s.st_kind S_DIR) then changed "Created directory changed";
    with_dir ~path ~via ~identity:(id s) (fun d h ->
      require_empty h;
      mkdir_missing d rest f)
;;

let materialize dir snapshot f = mkdir_missing dir snapshot.missing f

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
