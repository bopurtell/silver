open! Core
open! Async
open Hardcaml_workbench_protocol
module Rpc_server = Hardcaml_workbench_rpc_server.Rpc_server
module Service = Hardcaml_workbench_backend.Service

let application_version = "0.1.0"
let default_cache_entries = 64
let default_cache_bytes = 4_194_304

let instance_id () =
  Random.self_init ();
  sprintf
    "%d-%d-%08x"
    (Core_unix.getpid () |> Pid.to_int)
    (Time_ns.now () |> Time_ns.to_int_ns_since_epoch)
    (Random.bits ())
  |> V1.Daemon_instance_id.of_string
;;

let session_temporary_paths () =
  match Sys.getenv "TMPDIR" with
  | Some _ ->
    (* Preserve Filename's explicit-temp behavior and the unmodified child environment. *)
    Filename_unix.temp_dir "hardcaml-workbench-" "-logs" ~perm:0o700, None
  | None ->
    let cache =
      Sys.getenv "XDG_CACHE_HOME"
      |> Option.filter ~f:Filename.is_absolute
      |> Option.value_or_thunk ~default:(fun () ->
        Filename.concat (Sys_unix.home_directory ()) ".cache")
    in
    Core_unix.mkdir_p cache;
    let parent = Filename.concat cache "silver-runtime" in
    (try Core_unix.mkdir parent ~perm:0o700 with
     | Unix.Unix_error (EEXIST, _, _) -> ());
    let stat = Core_unix.lstat parent in
    if not (Poly.equal stat.st_kind S_DIR)
       || stat.st_uid <> Core_unix.geteuid ()
       || stat.st_perm land 0o777 <> 0o700
    then failwithf "Silver runtime cache must be a private directory: %s" parent ();
    let session = Filename_unix.temp_dir ~in_dir:parent ~perm:0o700 "session" "" in
    let scratch = Filename.concat session "tmp" in
    Core_unix.mkdir scratch ~perm:0o700;
    Filename.concat session "logs", Some scratch
;;

type state_lock_conflict = { state_dir : string }

let start_with_state_lock
  ?(authoring_roots = [])
  ~port
  ~discovery_dir
  ~state_dir
  ~inspection_detail_cache_entries
  ~inspection_detail_cache_bytes
  ()
  =
  Hardcaml_workbench_backend.Inspection_detail_cache.validate_limits
    ~entries:inspection_detail_cache_entries
    ~bytes:inspection_detail_cache_bytes;
  let instance_id = instance_id () in
  let state_dir =
    Option.value_or_thunk state_dir ~default:(fun () ->
      match discovery_dir with
      | Some directory -> Filename.concat directory "state"
      | None ->
        let home =
          Sys.getenv "XDG_STATE_HOME"
          |> Option.filter ~f:(Fn.non String.is_empty)
          |> Option.value
               ~default:(Filename.concat (Sys_unix.home_directory ()) ".local/state")
        in
        Filename.concat home "hardcaml-workbench/state")
  in
  if not (Filename.is_absolute state_dir) then failwith "--state-dir must be absolute";
  let state_paths =
    Hardcaml_workbench_native_http.Runtime.paths ~directory:state_dir ()
  in
  let%bind () = Hardcaml_workbench_native_http.Runtime.ensure_directory state_paths in
  let%bind.Deferred.Result state_lock =
    let%map lock =
      Hardcaml_workbench_native_http.Runtime.try_acquire_lifetime_lock state_paths
    in
    Result.of_option lock ~error:{ state_dir }
  in
  let%bind log_dir, subprocess_temp_dir = In_thread.run session_temporary_paths in
  let%bind service =
    Service.create
      ~authoring_roots
      ~instance_id
      ~log_dir
      ?subprocess_temp_dir
      ~state_dir
      ~inspection_detail_cache_entries
      ~inspection_detail_cache_bytes
      ()
  in
  let service = Or_error.ok_exn service in
  let rpc = Rpc_server.create ~application_version ~instance_id ~service in
  let paths = Hardcaml_workbench_native_http.Runtime.paths ?directory:discovery_dir () in
  let%bind lifetime_lock =
    match discovery_dir with
    | None -> return (Ok None)
    | Some _ ->
      let%map lock = Hardcaml_workbench_native_http.Runtime.acquire_lifetime_lock paths in
      Or_error.map lock ~f:Option.some
  in
  let lifetime_lock = Or_error.ok_exn lifetime_lock in
  let%bind server = Rpc_server.start rpc ~port in
  let port = Cohttp_async.Server.listening_on server in
  let endpoint = sprintf "http://127.0.0.1:%d" port in
  let%bind () =
    match discovery_dir with
    | None -> return ()
    | Some _ ->
      let metadata : Hardcaml_workbench_native_http.Runtime.Metadata.t =
        { endpoint
        ; instance_id = V1.Daemon_instance_id.to_string instance_id
        ; pid = Core_unix.getpid () |> Pid.to_int
        }
      in
      let client = Hardcaml_workbench_native_http.Client.create endpoint in
      let%bind hello = Hardcaml_workbench_native_http.Client.hello client in
      let hello = Or_error.ok_exn hello in
      if not (V1.Daemon_instance_id.equal hello.instance_id instance_id)
      then raise_s [%message "daemon readiness probe returned the wrong instance"];
      Hardcaml_workbench_native_http.Runtime.publish_metadata paths metadata
  in
  Shutdown.at_shutdown ~here:[%here] (fun () ->
    let%bind () = Service.shutdown service in
    let%bind () =
      match subprocess_temp_dir with
      | None -> Deferred.unit
      | Some scratch ->
        Monitor.try_with (fun () ->
          In_thread.run (fun () -> Service.remove_tree_sync (Filename.dirname scratch)))
        >>| ignore
    in
    let%bind () = Cohttp_async.Server.close server in
    Unix.funlock state_lock;
    let%bind () = Unix.close state_lock in
    match lifetime_lock with
    | None -> return ()
    | Some fd ->
      Unix.funlock fd;
      Unix.close fd);
  return (Ok endpoint)
;;

let state_lock_failure { state_dir } =
  Error.tag
    (Hardcaml_workbench_native_http.Runtime.lifetime_lock_held_error ())
    ~tag:("cannot open Silver state at " ^ state_dir)
;;

let start
  ?authoring_roots
  ~port
  ~discovery_dir
  ~state_dir
  ~inspection_detail_cache_entries
  ~inspection_detail_cache_bytes
  ()
  =
  let%map result =
    start_with_state_lock
      ?authoring_roots
      ~port
      ~discovery_dir
      ~state_dir
      ~inspection_detail_cache_entries
      ~inspection_detail_cache_bytes
      ()
  in
  result
  |> Result.map_error ~f:state_lock_failure
  |> Or_error.ok_exn
;;

let handle_signals signals =
  Signal.handle signals ~f:(fun signal ->
    Shutdown.shutdown_with_signal_exn
      ~force:(Clock.after (Time_float.Span.of_sec 12.))
      signal)
;;

let try_start_standalone ~project_root ~state_dir =
  let state_dir =
    Option.value_or_thunk state_dir ~default:(fun () ->
      let state_home =
        Sys.getenv "XDG_STATE_HOME"
        |> Option.filter ~f:Filename.is_absolute
        |> Option.value_or_thunk ~default:(fun () ->
          Filename.concat (Sys_unix.home_directory ()) ".local/state")
      in
      Filename.concat
        (Filename.concat state_home "silver/projects")
        (Md5.digest_string (Filename_unix.realpath project_root) |> Md5.to_hex))
  in
  handle_signals [ Signal.hup; Signal.int; Signal.term ];
  start_with_state_lock
    ~authoring_roots:[ Filename_unix.realpath project_root ]
    ~port:0
    ~discovery_dir:None
    ~state_dir:(Some state_dir)
    ~inspection_detail_cache_entries:default_cache_entries
    ~inspection_detail_cache_bytes:default_cache_bytes
    ()
;;

let start_standalone ~project_root ~state_dir =
  let%map result = try_start_standalone ~project_root ~state_dir in
  result |> Result.map_error ~f:state_lock_failure |> Or_error.ok_exn
;;
