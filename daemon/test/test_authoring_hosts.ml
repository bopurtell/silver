open! Core
open! Async
open Silver_protocol
module Client = Silver_native_http.Client

let exercise ~endpoint ~root ~outside =
  let client = Client.create endpoint in
  let%bind hello = Client.hello client >>| Or_error.ok_exn in
  assert (List.mem hello.capabilities Authoring.capability ~equal:String.equal);
  let call ?(instance_id = hello.instance_id) operation =
    Client.authoring client { instance_id; operation } >>| Or_error.ok_exn
  in
  let operation destination : Authoring.Operation.t =
    { target = { destination; project = None; object_id = None }
    ; recipe = "controlled-v1"
    ; name = "demo"
    }
  in
  let destination = Filename.concat root "new" in
  let op = operation destination in
  let preview () =
    match%map call (Preview op) with
    | Ok (Previewed p) ->
      assert (Authoring.Operation.equal op p.operation);
      assert (List.equal String.equal p.new_files [ "demo.txt" ]);
      assert (Option.is_some p.registration);
      p.preview_id
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let%bind wrong = call ~instance_id:"old" (Preview op) in
  assert (
    match wrong with
    | Error { kind = Instance_changed; _ } -> true
    | _ -> false);
  let%bind denied = call (Preview (operation (Filename.concat outside "unpermitted"))) in
  assert (
    match denied with
    | Ok (Failed { kind = Destination_denied; _ }) -> true
    | _ -> false);
  let%bind preview_id = preview () in
  let%bind cancelled = call (Cancel { preview_id }) in
  assert (
    match cancelled with
    | Ok Cancelled -> true
    | _ -> false);
  assert (not (Sys_unix.file_exists_exn destination));
  let%bind preview_id = preview () in
  Core_unix.mkdir destination;
  let file = Filename.concat destination "demo.txt" in
  Out_channel.write_all file ~data:"owner";
  let%bind stale = call (Apply { preview_id }) in
  assert (
    match stale with
    | Ok (Failed { kind = Stale_preview; _ }) -> true
    | _ -> false);
  assert (String.equal (In_channel.read_all file) "owner");
  Core_unix.unlink file;
  let%bind preview_id = preview () in
  let%map applied = call (Apply { preview_id }) in
  match applied with
  | Ok (Applied { created_files = [ "demo.txt" ]; registration = Skipped _ }) ->
    assert (Sys_unix.file_exists_exn file)
  | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
;;

let bluespec_authoring ~endpoint ~parent =
  let root = Filename.concat parent "bluespec" in
  Core_unix.mkdir root;
  Core_unix.mkdir (Filename.concat root ".silver");
  Out_channel.write_all
    (Filename.concat root ".silver/project.json")
    ~data:
      {|{"schema_version":1,"name":"classic","build_label":"//:rtl","test_label":"//:simulation","language":"bluespec-classic"}|};
  let client = Client.create endpoint in
  let%bind hello = Client.hello client >>| Or_error.ok_exn in
  let instance_id = hello.instance_id in
  let%bind opened =
    Client.open_project client { instance_id; root; environment = Inherit_daemon }
    >>| Or_error.ok_exn
  in
  let project =
    match opened with
    | Ok o -> o.project.id
    | Error e -> raise_s [%sexp (e : V1.Error.t)]
  in
  let call operation =
    Client.authoring client { instance_id; operation } >>| Or_error.ok_exn
  in
  let commit ?object_id recipe name expected =
    let%bind preview =
      call (Preview { target = { destination = root; project = Some project; object_id }; recipe; name })
    in
    let p =
      match preview with
      | Ok (Previewed p) ->
        assert (List.equal String.equal p.new_files expected);
        p
      | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
    in
    let%map applied = call (Apply { preview_id = p.preview_id }) in
    match applied with
    | Ok (Applied { created_files; registration = Not_requested }) ->
      assert (List.equal String.equal created_files expected)
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let%bind () =
    commit Authoring.ip_empty_recipe "lib" [ "ip/lib/Lib.bs"; "ip/lib/BUILD.bazel" ]
  in
  commit ~object_id:"ip/lib" Authoring.module_recipe "other" [ "ip/lib/Other.bs" ]
;;

(* This path exercises the separately installed provider. Run with WORKBENCH_TEST_REAL_CHIP_STARTER=1
   and the matching hardcaml-asic-starter on PATH. *)
let chip_integration ~endpoint ~parent =
  let root = Filename.concat parent "chips" in
  let client = Client.create endpoint in
  let%bind hello = Client.hello client >>| Or_error.ok_exn in
  let call operation =
    Client.authoring client { instance_id = hello.instance_id; operation }
    >>| Or_error.ok_exn
  in
  let preview op =
    match%map call op with
    | Ok (Previewed p) -> p
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let apply op =
    let%bind p = preview op in
    match%map call (Apply { preview_id = p.preview_id }) with
    | Ok (Applied { registration; _ }) -> registration
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let target =
    { Authoring.Target.destination = root; project = None; object_id = None }
  in
  let%bind first =
    apply (Preview { target; name = "first"; recipe = Authoring.starter_recipe })
  in
  assert (
    Authoring.Registration_result.equal first (Registered "hardcaml-asic-targets.json"));
  let%bind opened =
    Client.open_project
      client
      { instance_id = hello.instance_id; root; environment = Inherit_daemon }
    >>| Or_error.ok_exn
  in
  let project =
    match opened with
    | Ok o -> o.project.id
    | Error e -> raise_s [%sexp (e : V1.Error.t)]
  in
  let target = { target with project = Some project } in
  let dune args =
    Process.run ~working_dir:root ~prog:"dune" ~args () >>| Or_error.ok_exn >>| ignore
  in
  let asic operation =
    Client.asic client { instance_id = hello.instance_id; project; operation }
    >>| Or_error.ok_exn
    >>| function
    | Ok state -> state
    | Error e -> raise_s [%sexp (e : V1.Error.t)]
  in
  let%bind () = dune [ "build"; "--root"; "."; "asic_first/project.exe" ] in
  let%bind _ = asic Discover in
  let rec active attempts =
    let%bind state = asic Get in
    match state.chip_target with
    | Some target -> return target
    | None when attempts > 0 ->
      let%bind () = Clock.after (Time_float.Span.of_ms 50.) in
      active (attempts - 1)
    | None -> raise_s [%sexp (state : Asic.Snapshot.t)]
  in
  let%bind first_active = active 200 in
  assert (String.equal first_active.chip "first");
  let chip ?(target = target) ?(register = true) name source =
    Authoring.Request.Preview_chip { target; name; source; register }
  in
  let%bind wrong =
    call (chip ~target:{ target with destination = parent } "escape" Example)
  in
  assert (Result.is_error wrong);
  let read p = In_channel.read_all (Filename.concat root p) in
  let edit path data = Out_channel.write_all (Filename.concat root path) ~data in
  let original = read "asic_first/chip.ml" ^ "\n(* hand edited *)\n" in
  edit "asic_first/chip.ml" original;
  let%bind _ = apply (chip "second" Example) in
  let%bind _ =
    apply (Preview { target; name = "counter"; recipe = Authoring.ip_sample_recipe })
  in
  let ip_files =
    [ "block.ml"; "chip-interface.json"; "dune"; "test/dune"; "test/test_block.ml" ]
  in
  let ip_bytes () = List.map ip_files ~f:(fun p -> read ("ip/counter/" ^ p)) in
  let before = ip_bytes () in
  let ip mapping =
    Authoring.Chip_source.Ip { library_directory = "ip/counter"; mapping }
  in
  let%bind unsupported = call (chip "broken" (ip "")) in
  assert (
    match unsupported with
    | Ok (Failed _) -> true
    | _ -> false);
  let supported = chip "wrapped" (ip "ui_in:uo_out:comb8") in
  let%bind receipt = preview supported in
  edit "ip/counter/block.ml" "let create (_ : string) = 42\n";
  let%bind stale = call (Apply { preview_id = receipt.preview_id }) in
  assert (
    match stale with
    | Ok (Failed { kind = Stale_preview; created_files = []; _ }) -> true
    | _ -> false);
  let%bind wrong_type = call supported in
  assert (
    match wrong_type with
    | Ok (Failed _) -> true
    | _ -> false);
  assert (not (Sys_unix.file_exists_exn (Filename.concat root "asic_wrapped")));
  edit "ip/counter/block.ml" (List.hd_exn before);
  let%bind _ = apply (chip "wrapped" (ip "ui_in:uo_out:comb8")) in
  let%bind unlisted = apply (chip ~register:false "direct" Example) in
  assert (Authoring.Registration_result.equal unlisted Not_requested);
  assert (String.equal original (read "asic_first/chip.ml"));
  let%bind state = asic Get in
  assert (Option.equal Asic.Chip_target.equal state.chip_target (Some first_active));
  assert (List.equal String.equal before (ip_bytes ()));
  let json = Yojson.Basic.from_string (read "hardcaml-asic-targets.json") in
  let open Yojson.Basic.Util in
  assert (String.equal (member "default_target" json |> to_string) "first");
  assert (
    List.equal
      String.equal
      (member "targets" json
       |> to_list
       |> List.map ~f:(fun e -> member "id" e |> to_string))
      [ "first"; "second"; "wrapped" ]);
  let%bind () =
    dune
      [ "build"
      ; "--root"
      ; "."
      ; "asic_first/project.exe"
      ; "asic_second/project.exe"
      ; "asic_wrapped/project.exe"
      ; "asic_direct/project.exe"
      ]
  in
  let%bind () = dune [ "runtest"; "--root"; "." ] in
  let%bind _ = asic Discover in
  let rec refreshed attempts =
    let%bind s = asic Get in
    if List.length s.chips = 3
    then (
      assert (Option.equal Asic.Chip_target.equal s.chip_target (Some first_active));
      assert (
        List.equal
          String.equal
          (List.map s.chips ~f:(fun c -> c.id))
          [ "first"; "second"; "wrapped" ]);
      return ())
    else if attempts = 0
    then raise_s [%sexp (s : Asic.Snapshot.t)]
    else (
      let%bind () = Clock.after (Time_float.Span.of_ms 50.) in
      refreshed (attempts - 1))
  in
  let%bind () = refreshed 200 in
  let owner : Authoring.Owner.t = { project; destination = root; chip = "second" } in
  let describe owner =
    match%map call (Describe_owner owner) with
    | Ok (Owner_described info) -> info
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let%bind second = describe owner in
  let create name : Authoring.Request.t =
    New_flow
      { owner
      ; name
      ; recipe = List.hd_exn second.recipes
      ; endpoints = [ "synthesis" ]
      ; initial_profile = "balanced"
      }
  in
  let duplicate ?(source = "balanced") ?(edits = []) name : Authoring.Request.t =
    Duplicate_profile { owner; name; flow = "second_only"; source; edits }
  in
  let new_path = "asic_second/flows/flow_second_only.ml" in
  let%bind receipt = preview (create "second_only") in
  assert (List.equal String.equal receipt.new_files [ new_path ]);
  let%bind cancelled = call (Cancel { preview_id = receipt.preview_id }) in
  assert (Poly.equal cancelled (Ok Authoring.Response.Cancelled));
  assert (not (Sys_unix.file_exists_exn (Filename.concat root new_path)));
  let%bind receipt = preview (create "second_only") in
  edit new_path "(* occupied by the owner *)\n";
  let%bind stale = call (Apply { preview_id = receipt.preview_id }) in
  assert (
    match stale with
    | Ok (Failed { kind = Stale_preview; created_files = []; _ }) -> true
    | _ -> false);
  assert (String.equal (read new_path) "(* occupied by the owner *)\n");
  Core_unix.unlink (Filename.concat root new_path);
  let%bind _ = apply (create "second_only") in
  let build_owner () = dune [ "build"; "--root"; "."; "asic_second/project.exe" ] in
  let%bind () = build_owner () in
  let buffering = "SYNTH_ABC_BUFFERING" in
  let%bind _ = apply (duplicate ~edits:[ buffering, "false" ] "tuned") in
  let%bind () = build_owner () in
  let%bind _ = apply (duplicate ~source:"tuned" "timing_trial") in
  let path = "asic_second/flows/second_only/profiles/timing_trial.ml" in
  let source = read path in
  let%bind () = build_owner () in
  let%bind actual = describe owner in
  let flow = List.find_exn actual.flows ~f:(fun f -> String.equal f.id "second_only") in
  assert (
    Poly.equal
      (List.Assoc.find_exn flow.profiles "timing_trial" ~equal:String.equal)
      [ buffering, "false" ]);
  List.iter [ "balanced"; "timing_trial" ] ~f:(fun id ->
    assert (List.Assoc.mem flow.profiles id ~equal:String.equal));
  let%bind first = describe { owner with chip = "first" } in
  assert (not (List.exists first.flows ~f:(fun f -> String.equal f.id "second_only")));
  let rejected op =
    match%map call op with
    | Ok (Failed { created_files = []; _ }) -> ()
    | other -> raise_s [%sexp (other : V1.Authoring_call.Response.t)]
  in
  let%bind () = rejected (duplicate "balanced") in
  let%bind () = rejected (duplicate "timing_trial") in
  assert (String.equal source (read path));
  let%bind state = asic Get in
  assert (Option.equal Asic.Chip_target.equal state.chip_target (Some first_active));
  assert (
    String.equal
      (member
         "default_target"
         (Yojson.Basic.from_string (read "hardcaml-asic-targets.json"))
       |> to_string)
      "first");
  Core_unix.rename ~src:root ~dst:(root ^ "-moved");
  Core_unix.mkdir root;
  edit "dune-project" "(lang dune 3.17)\n";
  let%map replaced = call (chip "other_project" Example) in
  assert (
    match replaced with
    | Ok (Failed { kind = Destination_denied; _ }) -> true
    | _ -> false)
;;

let run daemon () =
  let dir = Filename_unix.temp_dir "silver-authoring-hosts-" "" in
  let path = Filename.concat dir in
  let root = path "standalone"
  and connected = path "connected" in
  Core_unix.mkdir root;
  Core_unix.mkdir connected;
  Monitor.protect
    ~finally:(fun () ->
      In_thread.run (fun () -> Silver_backend.Service.remove_tree_sync dir))
    (fun () ->
      let%bind endpoint =
        Server_host.start_standalone
          ~project_root:root
          ~state_dir:(Some (path "local-state"))
      in
      let%bind () = exercise ~endpoint ~root ~outside:connected in
      let%bind process =
        Process.create_exn
          ~prog:daemon
          ~args:[ "--authoring-root"; connected; "--state-dir"; path "connected-state" ]
          ()
      in
      Monitor.protect
        ~finally:(fun () ->
          Signal_unix.send_i Signal.term (`Pid (Process.pid process));
          Process.collect_output_and_wait process >>| ignore)
        (fun () ->
          match%bind Reader.read_line (Process.stdout process) with
          | `Eof -> failwith "daemon exited before publishing its endpoint"
          | `Ok line ->
            let endpoint =
              String.chop_prefix_exn line ~prefix:"silver-daemon listening on "
            in
             let%bind () = exercise ~endpoint ~root:connected ~outside:root in
             let%bind () = bluespec_authoring ~endpoint ~parent:connected in
             if Option.is_some (Sys.getenv "WORKBENCH_TEST_REAL_CHIP_STARTER")
            then chip_integration ~endpoint ~parent:connected
            else return ()))
;;

let () =
  Command.async
    ~summary:"Test authoring on standalone and daemon hosts"
    (let%map_open.Command daemon = anon ("DAEMON" %: string) in
     run daemon)
  |> Command_unix.run
;;
