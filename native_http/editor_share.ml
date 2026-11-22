open! Core
open! Async
open Hardcaml_workbench_protocol

module Fs = struct
  type fd = Core_unix.File_descr.t

  external open_path : string -> bool -> bool -> fd = "silver_share_open_path"
  external open_dir : fd -> string -> bool -> bool -> fd = "silver_share_open_dir"
  external open_file : fd -> string -> bool -> fd = "silver_share_open_file"
  external same_entry : fd -> string -> fd -> bool = "silver_share_same_entry"
  external same_dir : fd -> fd -> bool = "silver_share_same_dir"
  external try_flock : fd -> bool -> bool = "silver_share_try_flock"
  external rename_fresh : fd -> string -> string -> unit = "silver_share_rename_fresh"
  external unlink_same : fd -> string -> fd -> unit = "silver_share_unlink_same"

  let close = Core_unix.close
  let with_fd fd ~f = Exn.protect ~f:(fun () -> f fd) ~finally:(fun () -> close fd)

  let absent f ~default =
    try f () with
    | Core_unix.Unix_error (ENOENT, _, _) -> default
  ;;

  let require condition message = if not condition then failwith message

  let require_entry dir name fd =
    require (same_entry dir name fd) ("Share entry was replaced: " ^ name)
  ;;

  let require_directory open_directory dir =
    with_fd (open_directory ~create:false) ~f:(fun current ->
      require (same_dir current dir) "Share directory was replaced")
  ;;

  let read fd ~max_bytes =
    ignore (Core_unix.lseek fd 0L ~mode:SEEK_SET : Int64.t);
    let buf = Bytes.create (max_bytes + 1) in
    let rec loop pos =
      if pos > max_bytes then failwith "Share record is too large";
      match Core_unix.read fd ~buf ~pos ~restart:true with
      | 0 -> Bytes.sub buf ~pos:0 ~len:pos |> Bytes.to_string
      | count -> loop (pos + count)
    in
    loop 0
  ;;

  let write fd body =
    let rec loop pos =
      if pos < String.length body
      then (
        let count = Core_unix.single_write_substring fd ~buf:body ~pos ~restart:true in
        require (count > 0) "Could not write share record";
        loop (pos + count))
    in
    loop 0
  ;;

  let random_id () =
    Cryptokit.Random.string Cryptokit.Random.secure_rng 16
    |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
    |> String.lowercase
  ;;

  let create_record dir ~name ~body ~lock ~check_dir =
    let temporary = "." ^ random_id () ^ ".tmp" in
    let fd = open_file dir temporary true in
    let published = ref false in
    try
      if lock then require (try_flock fd true) "Could not lock new share record";
      write fd body;
      if not lock then Core_unix.fsync fd;
      check_dir ();
      require_entry dir temporary fd;
      rename_fresh dir temporary name;
      published := true;
      require_entry dir name fd;
      check_dir ();
      fd
    with
    | exn ->
      Exn.protect
        ~f:(fun () -> unlink_same dir (if !published then name else temporary) fd)
        ~finally:(fun () -> close fd);
      raise exn
  ;;
end

type source =
  | Embedded of { started_endpoint : string }
  | Attached

type target =
  { runtime : Runtime.paths
  ; source : source
  ; endpoint : string
  ; instance_id : V1.Daemon_instance_id.t
  ; project_id : Project_id.t
  ; project_root : string
  }

type publication =
  { directory : Fs.fd
  ; file : Fs.fd
  }

type offer =
  { id : string
  ; mutable publication : publication option
  }

let canonical_root root =
  Fs.require (Filename.is_absolute root) "Project root must be absolute";
  let canonical = Filename_unix.realpath root in
  Fs.require (Sys_unix.is_directory_exn canonical) "Project root is not a directory";
  canonical
;;

let require_loopback endpoint =
  let prefix = "http://127.0.0.1:" in
  let valid =
    Option.bind (String.chop_prefix endpoint ~prefix) ~f:Int.of_string_opt
    |> Option.exists ~f:(fun port ->
      port > 0 && port <= 65535 && String.equal endpoint (prefix ^ Int.to_string port))
  in
  Fs.require valid "Editor sharing requires the service's exact local loopback endpoint"
;;

let max_record_bytes = 16 * 1024

let runtime_directory runtime ~create =
  (* Match the reader's runtime-path and record bounds. *)
  let components =
    String.split runtime.Runtime.directory ~on:'/'
    |> List.count ~f:(Fn.non String.is_empty)
  in
  Fs.require (components > 0 && components <= 64) "Invalid editor sharing runtime path";
  Fs.open_path runtime.directory create true
;;

let registry_directory runtime ~create =
  Fs.with_fd (runtime_directory runtime ~create) ~f:(fun dir ->
    Fs.with_fd (Fs.open_dir dir "editor-shares" create true) ~f:(fun shares ->
      Fs.open_dir shares "v1" create true))
;;

let valid_offer_text s =
  (not (String.is_empty s))
  && String.length s <= 4096
  && not (String.exists s ~f:(fun c -> Char.to_int c < 32 || Char.equal c '\127'))
;;

module Attachment = struct
  type t =
    { directory : Fs.fd
    ; record : Fs.fd
    ; lock : Fs.fd
    ; mutable body : string option
    }

  let close { directory; record; lock; _ } =
    Fs.close lock;
    Fs.close record;
    Fs.close directory
  ;;

  let open_ runtime =
    let directory = runtime_directory runtime ~create:false in
    try
      let lock = Fs.open_file directory "lifetime.lock" false in
      try
        (* A persistent lockfile is not evidence of liveness by itself. *)
        Fs.require
          (not (Fs.try_flock lock false))
          "The local daemon's lifetime lock is not held";
        let record = Fs.open_file directory "daemon.sexp" false in
        { directory; record; lock; body = None }
      with
      | exn ->
        Fs.close lock;
        raise exn
    with
    | exn ->
      Fs.close directory;
      raise exn
  ;;

  let check t target =
    Fs.require_directory (runtime_directory target.runtime) t.directory;
    Fs.require_entry t.directory "lifetime.lock" t.lock;
    Fs.require_entry t.directory "daemon.sexp" t.record;
    Fs.require
      (not (Fs.try_flock t.lock false))
      "The local daemon's lifetime lock is not held";
    let body = Fs.read t.record ~max_bytes:max_record_bytes in
    Fs.require_entry t.directory "daemon.sexp" t.record;
    Option.iter t.body ~f:(fun previous ->
      Fs.require (String.equal previous body) "The local daemon's record changed");
    t.body <- Some body;
    let metadata = Runtime.Metadata.t_of_sexp (Sexp.of_string body) in
    Fs.require
      (metadata.pid > 0
       && String.equal metadata.endpoint target.endpoint
       && String.equal
            metadata.instance_id
            (V1.Daemon_instance_id.to_string target.instance_id))
      "The active connection does not match the local daemon's endpoint and instance"
  ;;
end

let verify target ~f =
  let%map result =
    Monitor.try_with_or_error ~extract_exn:true (fun () ->
      require_loopback target.endpoint;
      Fs.require
        (List.for_all
           [ Project_id.to_string target.project_id
           ; V1.Daemon_instance_id.to_string target.instance_id
           ; target.project_root
           ]
           ~f:valid_offer_text)
        "An already-open project and service instance with shareable identifiers are \
         required";
      Fs.require
        (String.equal (canonical_root target.project_root) target.project_root)
        "The current project root changed";
      Fs.absent ~default:() (fun () ->
        Fs.close (registry_directory target.runtime ~create:false));
      let attachment =
        match target.source with
        | Embedded { started_endpoint } ->
          Fs.require
            (String.equal started_endpoint target.endpoint)
            "The active connection is not the embedded service Silver started";
          None
        | Attached -> Some (Attachment.open_ target.runtime)
      in
      Monitor.protect
        ~finally:(fun () ->
          Option.iter attachment ~f:Attachment.close;
          return ())
        (fun () ->
          let check_attachment () =
            Option.iter attachment ~f:(fun a -> Attachment.check a target)
          in
          check_attachment ();
          let client =
            Client.create target.endpoint ~timeout:(Time_float.Span.of_sec 1.)
          in
          let%map hello = Client.hello client in
          let hello = Or_error.ok_exn hello in
          Fs.require
            (V1.Daemon_instance_id.equal hello.instance_id target.instance_id
             && List.mem hello.protocol_versions V1.version ~equal:Int.equal
             && List.mem hello.capabilities "snapshot" ~equal:String.equal)
            "The active service did not confirm its instance and v1 snapshot support";
          check_attachment ();
          f ()))
  in
  Or_error.tag result ~tag:"Editor sharing is unavailable"
;;

let validate ?runtime ~source ~client ~instance_id ~project_id ~project_root () =
  match Or_error.try_with (fun () -> canonical_root project_root) with
  | Error error -> return (Error error)
  | Ok project_root ->
    let target =
      { runtime = Option.value_or_thunk runtime ~default:(fun () -> Runtime.paths ())
      ; source
      ; endpoint = Client.endpoint client
      ; instance_id
      ; project_id
      ; project_root
      }
    in
    verify target ~f:(fun () -> target)
;;

let offer_id offer = offer.id

let publication_body target id =
  let atom s = Sexp.Atom s in
  let fields =
    [ "offer_id", id
    ; "endpoint", target.endpoint
    ; "instance_id", V1.Daemon_instance_id.to_string target.instance_id
    ; "project_id", Project_id.to_string target.project_id
    ; "project_root", target.project_root
    ; ( "mode"
      , match target.source with
        | Embedded _ -> "embedded"
        | Attached -> "attached" )
    ]
    |> List.map ~f:(fun (key, value) -> Sexp.List [ atom key; atom value ])
  in
  Sexp.to_string_mach (Sexp.List [ atom "silver-editor-share-v1"; Sexp.List fields ])
;;

let publish target =
  verify target ~f:(fun () ->
    let id = Fs.random_id () in
    let name = id ^ ".sexp" in
    let body = publication_body target id in
    Fs.require
      (String.length body <= max_record_bytes)
      "The editor share record is too large";
    let open_directory = registry_directory target.runtime in
    let directory = open_directory ~create:true in
    try
      let check_dir () = Fs.require_directory open_directory directory in
      let file = Fs.create_record directory ~name ~body ~lock:true ~check_dir in
      { id; publication = Some { directory; file } }
    with
    | exn ->
      Fs.close directory;
      raise exn)
;;

let withdraw offer =
  match offer.publication with
  | None -> return (Ok ())
  | Some { directory; file } ->
    let name = offer.id ^ ".sexp" in
    (* Never leave a live offer behind when unlinking fails. Close the locked descriptor
       after the attempt; an unremoved record then becomes stale. *)
    let unlink = Or_error.try_with (fun () -> Fs.unlink_same directory name file) in
    offer.publication <- None;
    let release = Or_error.try_with (fun () -> Fs.close file) in
    let close_directory = Or_error.try_with (fun () -> Fs.close directory) in
    return (Or_error.combine_errors_unit [ unlink; release; close_directory ])
;;

module Remember = struct
  let directory override =
    let config_home =
      match override with
      | Some path -> path
      | None ->
        Sys.getenv "XDG_CONFIG_HOME"
        |> Option.filter ~f:Filename.is_absolute
        |> Option.value_or_thunk ~default:(fun () ->
          Filename.concat (Sys_unix.home_directory ()) ".config")
    in
    (* silver/ also holds user-managed settings; the dedicated store itself is private.
       Separate per-root records avoid a shared read/modify/write. *)
    fun ~create ->
      Fs.with_fd (Fs.open_path config_home create false) ~f:(fun config ->
        Fs.with_fd (Fs.open_dir config "silver" create false) ~f:(fun silver ->
          Fs.open_dir silver "editor-share-remembered-v1" create true))
  ;;

  let record project_root =
    let root = canonical_root project_root in
    let key =
      Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) root
      |> Cryptokit.transform_string (Cryptokit.Hexa.encode ())
    in
    let body = Sexp.to_string_mach (Sexp.Atom root) in
    Fs.require (String.length body <= max_record_bytes) "The project root is too large";
    key ^ ".sexp", body
  ;;

  let check dir name ~body fd =
    Fs.require
      (String.equal (Fs.read fd ~max_bytes:max_record_bytes) body)
      "This preference record does not match the project root";
    Fs.require_entry dir name fd
  ;;
end

let remembered ?config_home ~project_root () =
  Or_error.try_with (fun () ->
    let name, body = Remember.record project_root in
    let open_directory = Remember.directory config_home in
    Fs.absent ~default:false (fun () ->
      Fs.with_fd (open_directory ~create:false) ~f:(fun dir ->
        Fs.with_fd (Fs.open_file dir name false) ~f:(fun fd ->
          Remember.check dir name ~body fd;
          Fs.require_directory open_directory dir;
          true))))
;;

let set_remembered ?config_home ~project_root value =
  Or_error.try_with (fun () ->
    let name, body = Remember.record project_root in
    let open_directory = Remember.directory config_home in
    let remove_or_confirm dir ~remove =
      Fs.with_fd (Fs.open_file dir name false) ~f:(fun fd ->
        Remember.check dir name ~body fd;
        Fs.require_directory open_directory dir;
        if remove then Fs.unlink_same dir name fd)
    in
    if value
    then
      Fs.with_fd (open_directory ~create:true) ~f:(fun dir ->
        try
          let check_dir () = Fs.require_directory open_directory dir in
          Fs.create_record dir ~name ~body ~lock:false ~check_dir |> Fs.close
        with
        | Core_unix.Unix_error (EEXIST, _, _) -> remove_or_confirm dir ~remove:false)
    else
      Fs.absent ~default:() (fun () ->
        Fs.with_fd (open_directory ~create:false) ~f:(fun dir ->
          remove_or_confirm dir ~remove:true)))
;;
