open! Core
open! Async

(* Scheduler-owned state and synchronous bounded IO are intentional: there is no
   background writer which can outlive cancellation and recreate partial files. One active
   export process-wide reserves at most 64 MiB + 64 KiB metadata. Published directories
   are deliberately retained for external viewers, including launch failure; users remove
   them explicitly. They are not partial-output reservations and there is no automatic
   retention/pruning policy here. *)
let page_bytes = 64 * 1024
let max_bytes = 64 * 1024 * 1024
let metadata_bytes = 64 * 1024
let active = ref false
let digest hash = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) hash#result

let run
  ?(timeout = Time_float.Span.of_sec 120.)
  ?(write = Out_channel.output_string)
  ?(before_write = fun _ -> ())
  ?(before_verify = fun _ -> ())
  ?(before_publish = fun _ -> ())
  ~size
  ~sha256
  ~metadata
  ~suffix
  ~current
  ~fetch
  ~viewer
  ~launch
  ()
  =
  if !active
  then return (Or_error.error_string "Another private export is active")
  else if size < 0 || size > max_bytes || String.length metadata > metadata_bytes
  then return (Or_error.error_string "Export size/metadata budget exceeded")
  else (
    active := true;
    let stopped = ref false in
    let deadline =
      Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_sec (Time_float.Span.to_sec timeout))
    in
    let check () =
      if !stopped || (not (current ())) || Time_ns.(now () >= deadline)
      then failwith "Export cancelled, owner changed or deadline expired"
    in
    let directory = ref None in
    let channel = ref None in
    let input_channel = ref None in
    let published = ref false in
    let cleanup () =
      let results = ref [] in
      let attempt f = results := Or_error.try_with f :: !results in
      Option.iter !channel ~f:(fun out -> attempt (fun () -> Out_channel.close out));
      channel := None;
      Option.iter !input_channel ~f:(fun input ->
        attempt (fun () -> In_channel.close input));
      input_channel := None;
      if not !published
      then
        Option.iter !directory ~f:(fun dir ->
          List.iter
            [ "artifact" ^ suffix; "metadata.sexp" ]
            ~f:(fun name ->
              let path = Filename.concat dir name in
              attempt (fun () ->
                if Sys_unix.file_exists_exn path then Core_unix.unlink path));
          attempt (fun () -> Core_unix.rmdir dir));
      Or_error.combine_errors_unit !results
    in
    let work () =
      let open Deferred.Let_syntax in
      check ();
      let dir = Filename_unix.temp_dir ~perm:0o700 "hardcaml-export-partial-" "" in
      directory := Some dir;
      let path = Filename.concat dir ("artifact" ^ suffix) in
      let out = Out_channel.create ~binary:true ~perm:0o600 ~fail_if_exists:true path in
      channel := Some out;
      let hash = Cryptokit.Hash.sha256 () in
      let rec collect offset remaining =
        let%bind () = Scheduler.yield () in
        check ();
        if remaining = 0 then failwith "Export page budget exhausted";
        (* The fetch result has no continuation with filesystem side effects. *)
        let%bind bytes, eof =
          fetch ~offset ~limit:page_bytes ~check >>| Or_error.ok_exn
        in
        check ();
        let length = String.length bytes in
        if length > page_bytes
           || length > size - offset
           || ((not eof) && length = 0)
           || not (Bool.equal eof (offset + length = size))
        then failwith "Export byte count/page size/EOF mismatch";
        before_write path;
        check ();
        write out bytes;
        hash#add_string bytes;
        if eof then return (offset + length) else collect (offset + length) (remaining - 1)
      in
      let%bind count = collect 0 4096 in
      Out_channel.close out;
      channel := None;
      if count <> size || not (String.equal (digest hash) sha256)
      then failwith "Export SHA256/byte count mismatch";
      before_verify path;
      check ();
      let read_hash = Cryptokit.Hash.sha256 () in
      let read_count = ref 0 in
      let input = In_channel.create ~binary:true path in
      input_channel := Some input;
      let buffer = Bytes.create page_bytes in
      let rec verify () =
        let%bind () = Scheduler.yield () in
        check ();
        let n = In_channel.input input ~buf:buffer ~pos:0 ~len:page_bytes in
        if n = 0
        then return ()
        else (
          read_count := !read_count + n;
          if !read_count > size then failwith "Readback exceeds declared size";
          read_hash#add_substring buffer 0 n;
          verify ())
      in
      let%bind () = verify () in
      In_channel.close input;
      input_channel := None;
      if !read_count <> size || not (String.equal (digest read_hash) sha256)
      then failwith "Export disk readback verification failed";
      Out_channel.with_file
        (Filename.concat dir "metadata.sexp")
        ~binary:true
        ~perm:0o600
        ~fail_if_exists:true
        ~f:(fun out -> Out_channel.output_string out metadata);
      before_publish dir;
      check ();
      (* temp_dir creates a unique private sibling; the destination does not exist. *)
      let destination = dir ^ "-verified" in
      Core_unix.rename ~src:dir ~dst:destination;
      published := true;
      let path = Filename.concat destination ("artifact" ^ suffix) in
      check ();
      let%map () =
        match viewer with
        | None -> return ()
        | Some prog ->
          launch ~prog ~args:[ path ]
          >>| fun r ->
          Or_error.ok_exn (Or_error.tag r ~tag:("Verified bytes retained at " ^ path))
      in
      path
    in
    let finished = Ivar.create () in
    let rec watch () =
      if Ivar.is_full finished
      then return ()
      else if (not (current ())) || Time_ns.(now () >= deadline)
      then (
        stopped := true;
        return ())
      else Clock.after (Time_float.Span.of_ms 10.) >>= watch
    in
    let work_result = Monitor.try_with_or_error work in
    let cancellation =
      watch () >>| fun () -> Or_error.error_string "Export cancelled or timed out"
    in
    let%bind result = Deferred.any [ work_result; cancellation ] in
    stopped := true;
    Ivar.fill_exn finished ();
    (* Cleanup happens even if fetch has never resolved. Late fetch completion sees
       stopped before any write, publication or launch. *)
    let cleanup_result = cleanup () in
    (* A cleanup failure keeps the reservation: repeated attempts must not leave an
       unbounded number of private partial directories behind. *)
    active := Or_error.is_error cleanup_result;
    return (Or_error.bind cleanup_result ~f:(fun () -> result)))
;;
