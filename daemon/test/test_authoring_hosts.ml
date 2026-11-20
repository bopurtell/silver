open! Core
open! Async
open Hardcaml_workbench_protocol
module Client = Hardcaml_workbench_native_http.Client

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

let run daemon () =
  let dir = Filename_unix.temp_dir "silver-authoring-hosts-" "" in
  let path = Filename.concat dir in
  let root = path "standalone"
  and connected = path "connected" in
  Core_unix.mkdir root;
  Core_unix.mkdir connected;
  Monitor.protect
    ~finally:(fun () ->
      In_thread.run (fun () -> Hardcaml_workbench_backend.Service.remove_tree_sync dir))
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
            exercise ~endpoint ~root:connected ~outside:root))
;;

let () =
  Command.async
    ~summary:"Test authoring on standalone and daemon hosts"
    (let%map_open.Command daemon = anon ("DAEMON" %: string) in
     run daemon)
  |> Command_unix.run
;;
