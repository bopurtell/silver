open! Core
open! Async

let remove path =
  Core_unix.unlink path;
  Core_unix.unlink (Filename.concat (Filename.dirname path) "metadata.sexp");
  Core_unix.rmdir (Filename.dirname path)
;;

let%test_unit "incremental publication, failures and disk readback" =
  Thread_safe.block_on_async_exn (fun () ->
    let bytes = String.init ((3 * 65536) + 17) ~f:(fun i -> Char.of_int_exn (i % 256)) in
    let sha256 = Plain_rpc.digest bytes in
    let fetch ~offset ~limit ~check =
      check ();
      let length = Int.min limit (String.length bytes - offset) in
      return
        (Ok
           ( String.sub bytes ~pos:offset ~len:length
           , offset + length = String.length bytes ))
    in
    let launched = ref 0 in
    let launch ~prog:_ ~args =
      let path = List.hd_exn args in
      assert (String.equal (In_channel.read_all path) bytes);
      assert (
        Sys_unix.file_exists_exn (Filename.concat (Filename.dirname path) "metadata.sexp"));
      incr launched;
      return (Ok ())
    in
    let run
      ?write
      ?before_write
      ?before_verify
      ?before_publish
      ?(sha256 = sha256)
      ?(fetch = fetch)
      ()
      =
      Streaming_export.run
        ?write
        ?before_write
        ?before_verify
        ?before_publish
        ~size:(String.length bytes)
        ~sha256
        ~metadata:"fixture"
        ~suffix:".vcd"
        ~current:(fun () -> true)
        ~fetch
        ~viewer:(Some "/viewer")
        ~launch
        ()
    in
    let%bind result = run () in
    remove (Or_error.ok_exn result);
    assert (!launched = 1);
    let partial = ref None in
    let record path = partial := Some path in
    let assert_clean () =
      Option.iter !partial ~f:(fun path ->
        assert (not (Sys_unix.file_exists_exn (Filename.dirname path))));
      partial := None;
      assert (!launched = 1)
    in
    let%bind r = run ~before_write:record ~write:(fun _ _ -> failwith "ENOSPC") () in
    assert (Or_error.is_error r);
    assert_clean ();
    let%bind r =
      run ~before_write:record ~before_publish:(fun _ -> failwith "rename denied") ()
    in
    assert (Or_error.is_error r);
    assert_clean ();
    let blocked_destination = ref "" in
    let%bind r =
      run
        ~before_write:record
        ~before_publish:(fun dir ->
          let destination = dir ^ "-verified" in
          blocked_destination := destination;
          Out_channel.write_all destination ~data:"blocks directory rename")
        ()
    in
    assert (Or_error.is_error r);
    assert_clean ();
    Core_unix.unlink !blocked_destination;
    let%bind r =
      run
        ~before_write:record
        ~before_verify:(fun path -> Out_channel.write_all path ~data:"corrupt")
        ()
    in
    assert (Or_error.is_error r);
    assert_clean ();
    let%bind r = run ~before_write:record ~sha256:(String.make 64 '0') () in
    assert (Or_error.is_error r);
    assert_clean ();
    let%bind r =
      run
        ~fetch:(fun ~offset:_ ~limit:_ ~check:_ ->
          return (Or_error.error_string "missing page"))
        ()
    in
    assert (Or_error.is_error r);
    let%bind r =
      run
        ~fetch:(fun ~offset:_ ~limit:_ ~check:_ ->
          return (Ok (String.make 65537 'x', false)))
        ()
    in
    assert (Or_error.is_error r);
    let%map r =
      run ~fetch:(fun ~offset:_ ~limit:_ ~check:_ -> return (Ok ("", false))) ()
    in
    assert (Or_error.is_error r))
;;

let%test_unit "timeout and owner cancellation clean unresolved fetch; late completion \
               inert"
  =
  Thread_safe.block_on_async_exn (fun () ->
    Deferred.List.iter [ true; false ] ~how:`Sequential ~f:(fun timeout ->
      let pending = Ivar.create () in
      let waiting = Ivar.create () in
      let partial = ref None in
      let current = ref true in
      let calls = ref 0 in
      let run () =
        Streaming_export.run
          ~timeout:(Time_float.Span.of_ms (if timeout then 30. else 1000.))
          ~before_write:(fun path -> partial := Some path)
          ~size:2
          ~sha256:(Plain_rpc.digest "ab")
          ~metadata:"fixture"
          ~suffix:".bin"
          ~current:(fun () -> !current)
          ~fetch:(fun ~offset ~limit:_ ~check:_ ->
            incr calls;
            if offset = 0
            then return (Ok ("a", false))
            else (
              Ivar.fill_exn waiting ();
              Ivar.read pending))
          ~viewer:(Some "/viewer")
          ~launch:(fun ~prog:_ ~args:_ -> assert false)
          ()
      in
      let result = run () in
      let%bind busy = run () in
      assert (Or_error.is_error busy);
      let%bind () = Ivar.read waiting in
      if not timeout then current := false;
      let%bind result in
      assert (Or_error.is_error result);
      let dir = Filename.dirname (Option.value_exn !partial) in
      assert (not (Sys_unix.file_exists_exn dir));
      Ivar.fill_exn pending (Ok ("b", true));
      let%map () = Clock.after (Time_float.Span.of_ms 20.) in
      assert (!calls = 2);
      assert (not (Sys_unix.file_exists_exn dir));
      assert (not (Sys_unix.file_exists_exn (dir ^ "-verified")))))
;;

let%test_unit "ASIC identity, missing/changed pages and declared limits" =
  let open Hardcaml_workbench_protocol in
  let reference : Asic_artifact.Reference.t =
    { id = "image"
    ; run = Asic_snapshot_fixture.run_a
    ; terminal_attempt = "original"
    ; label = "image"
    ; path = "/provider/image.png"
    ; size = 1
    ; sha256 = Plain_rpc.digest "x"
    ; kind = "binary"
    }
  in
  let page : Asic_artifact.Byte_page.t =
    { artifact_id = reference.id
    ; run = reference.run
    ; terminal_attempt = reference.terminal_attempt
    ; sha256 = reference.sha256
    ; offset = 0
    ; limit = 65536
    ; next_offset = 1
    ; eof = true
    ; bytes_hex = "78"
    ; error = None
    }
  in
  assert (Or_error.is_ok (Artifact_binary_export.validate_page reference ~offset:0 page));
  List.iter
    [ { page with terminal_attempt = "changed" }
    ; { page with sha256 = String.make 64 '0' }
    ; { page with error = Some "missing" }
    ; { page with next_offset = 2 }
    ; { page with bytes_hex = String.make 131074 '0' }
    ]
    ~f:(fun page ->
      assert (
        Or_error.is_error (Artifact_binary_export.validate_page reference ~offset:0 page)));
  assert (
    Or_error.is_error
      (Artifact_binary_export.eligible { reference with size = (16 * 1024 * 1024) + 1 }))
;;

let%test_unit "simulation streaming adapter publishes exact raw bytes and rejects \
               changed pages"
  =
  Thread_safe.block_on_async_exn (fun () ->
    let module S = Hardcaml_workbench_protocol.Simulation in
    let bytes = "\000\255\128\r\n" in
    let artifact : S.Artifact.t =
      { id = "trace"
      ; attempt_id = "original"
      ; case_id = None
      ; label = "trace"
      ; kind = "waveform"
      ; media_type = "application/vnd.gtkwave.vcd"
      ; size = Some (String.length bytes)
      ; sha256 = Some (Plain_rpc.digest bytes)
      ; availability = Available
      }
    in
    let page : S.Byte_page.t =
      { attempt_id = artifact.attempt_id
      ; artifact_id = artifact.id
      ; sha256 = Option.value_exn artifact.sha256
      ; offset = 0
      ; next_offset = String.length bytes
      ; total_size = String.length bytes
      ; eof = true
      ; bytes_hex = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) bytes
      }
    in
    let launched = ref false in
    let clipboard = Export_clipboard.create () in
    let copies = ref [] in
    let complete result =
      Export_clipboard.completed clipboard result ~notice:ignore;
      Bonsai_term.Effect.Expert.handle ~on_exn:raise
        (Export_clipboard.flush clipboard ~enabled:true ~write:(fun sequence ->
           Bonsai_term.Effect.of_thunk (fun () -> copies := sequence :: !copies)))
    in
    let%bind r =
      Simulation_export.run
        ~artifact
        ~current:(fun () -> true)
        ~fetch:(fun ~offset ~limit ->
          assert (offset = 0 && limit = 65536);
          return (Ok page))
        ~viewer:(Some "/viewer with spaces")
        ~launch:(fun ~prog ~args ->
          assert (String.equal prog "/viewer with spaces");
          assert (String.equal (In_channel.read_all (List.hd_exn args)) bytes);
          launched := true;
          return (Ok ()))
    in
    assert !launched;
    complete r;
    assert (List.equal String.equal !copies [ Export_clipboard.osc52 (Or_error.ok_exn r) ]);
    remove (Or_error.ok_exn r);
    Deferred.List.iter
      [ { page with attempt_id = "changed" }
      ; { page with sha256 = String.make 64 '0' }
      ; { page with bytes_hex = String.make 131074 '0' }
      ; { page with bytes_hex = String.make (String.length page.bytes_hex) '0' }
      ; { page with total_size = 6 }
      ]
      ~how:`Sequential
      ~f:(fun page ->
        let%map r =
          Simulation_export.run
            ~artifact
            ~current:(fun () -> true)
            ~fetch:(fun ~offset:_ ~limit:_ -> return (Ok page))
            ~viewer:(Some "/viewer")
            ~launch:(fun ~prog:_ ~args:_ -> assert false)
        in
        assert (Or_error.is_error r);
        complete r;
        assert (List.length !copies = 1)))
;;

let%test_unit "ASIC streaming adapter launches only exact verified local publication" =
  Thread_safe.block_on_async_exn (fun () ->
    let open Hardcaml_workbench_protocol in
    let bytes = "\137PNG\000\255\r\n" in
    let reference : Asic_artifact.Reference.t =
      { id = "image"
      ; run = Asic_snapshot_fixture.run_a
      ; terminal_attempt = "original"
      ; label = "image"
      ; path = "/provider/image.png"
      ; size = String.length bytes
      ; sha256 = Plain_rpc.digest bytes
      ; kind = "binary"
      }
    in
    let launched = ref false in
    let%map r =
      Artifact_binary_export.run
        ~reference
        ~viewer:"/viewer"
        ~current:(fun () -> true)
        ~fetch:(fun ~reference:actual ~offset ~limit ~check ->
          check ();
          assert (Asic_artifact.Reference.equal actual reference);
          let length = Int.min 3 (reference.size - offset) in
          return
            (Ok
               { Asic_artifact.Byte_page.artifact_id = reference.id
               ; run = reference.run
               ; terminal_attempt = reference.terminal_attempt
               ; sha256 = reference.sha256
               ; offset
               ; limit
               ; next_offset = offset + length
               ; eof = offset + length = reference.size
               ; bytes_hex =
                   Cryptokit.transform_string
                     (Cryptokit.Hexa.encode ())
                     (String.sub bytes ~pos:offset ~len:length)
               ; error = None
               }))
        ~launch:(fun ~prog:_ ~args ->
          let path = List.hd_exn args in
          assert (not (String.equal path reference.path));
          assert (String.is_suffix path ~suffix:".png");
          assert (String.equal (In_channel.read_all path) bytes);
          launched := true;
          return (Ok ()))
    in
    assert !launched;
    remove (Or_error.ok_exn r))
;;

let%test_unit "empty exports, metadata budget and retained publication after viewer \
               failure"
  =
  Thread_safe.block_on_async_exn (fun () ->
    let path = ref None in
    let run ~size ~metadata =
      Streaming_export.run
        ~size
        ~metadata
        ~sha256:(Plain_rpc.digest "")
        ~suffix:".bin"
        ~current:(fun () -> true)
        ~fetch:(fun ~offset ~limit:_ ~check:_ ->
          assert (offset = 0);
          return (Ok ("", true)))
        ~viewer:(Some "/viewer")
        ~launch:(fun ~prog:_ ~args ->
          path := Some (List.hd_exn args);
          return (Or_error.error_string "viewer failed"))
        ()
    in
    let%bind r = run ~size:0 ~metadata:"empty" in
    assert (Or_error.is_error r);
    let published = Option.value_exn !path in
    assert (String.is_empty (In_channel.read_all published));
    remove published;
    path := None;
    let%bind r = run ~size:0 ~metadata:(String.make (65536 + 1) 'x') in
    assert (Or_error.is_error r && Option.is_none !path);
    let%map r = run ~size:((64 * 1024 * 1024) + 1) ~metadata:"too large" in
    assert (Or_error.is_error r && Option.is_none !path))
;;

let%test_unit "failed cleanup keeps reservation to bound leftover temporary storage" =
  Thread_safe.block_on_async_exn (fun () ->
    let directory = ref None in
    let run ?(before_publish = fun _ -> ()) () =
      Streaming_export.run
        ~before_publish
        ~size:0
        ~sha256:(Plain_rpc.digest "")
        ~metadata:"fixture"
        ~suffix:".bin"
        ~current:(fun () -> true)
        ~fetch:(fun ~offset:_ ~limit:_ ~check:_ -> return (Ok ("", true)))
        ~viewer:None
        ~launch:(fun ~prog:_ ~args:_ -> assert false)
        ()
    in
    let%bind r =
      run
        ~before_publish:(fun dir ->
          directory := Some dir;
          Out_channel.write_all (Filename.concat dir "cleanup-blocker") ~data:"fixture";
          failwith "publication failed")
        ()
    in
    assert (Or_error.is_error r);
    let%map blocked = run () in
    assert (Or_error.is_error blocked);
    let dir = Option.value_exn !directory in
    Core_unix.unlink (Filename.concat dir "cleanup-blocker");
    Core_unix.rmdir dir;
    (* Only the fault-injection test can clear a failed-cleanup reservation. *)
    Streaming_export.active := false)
;;
