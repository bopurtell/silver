open! Core
open! Async
open Hardcaml_workbench_protocol
open Hardcaml_workbench_native_http

let main () =
  match Array.to_list (Sys.get_argv ()) with
  | [ _; "remember"; config_home; project_root; command ] ->
    (match command with
     | "get" ->
       printf
         "%b\n"
         (Or_error.ok_exn (Editor_share.remembered ~config_home ~project_root ()))
     | "set" | "clear" ->
       Or_error.ok_exn
         (Editor_share.set_remembered
            ~config_home
            ~project_root
            (String.equal command "set"))
     | _ -> failwith "Unknown preference command");
    return ()
  | [ _; mode; runtime; endpoint; started_endpoint; instance_id; project_root ] ->
    let source =
      match mode with
      | "attached" -> Editor_share.Attached
      | "embedded" -> Editor_share.Embedded { started_endpoint }
      | _ -> failwith "Unknown source mode"
    in
    let%bind target =
      Editor_share.validate
        ~runtime:(Runtime.paths ~directory:runtime ())
        ~source
        ~client:(Client.create endpoint)
        ~instance_id:(V1.Daemon_instance_id.of_string instance_id)
        ~project_id:(Project_id.of_string "example-project")
        ~project_root
        ()
    in
    let target = Or_error.ok_exn target in
    let print line =
      Writer.write_line (Lazy.force Writer.stdout) line;
      Writer.flushed (Lazy.force Writer.stdout)
    in
    let%bind () = print "validated" in
    (* Permit a deterministic change between eligibility and publication. *)
    let%bind _ = Reader.read_line (Lazy.force Reader.stdin) in
    let%bind offer = Editor_share.publish target in
    let offer = Or_error.ok_exn offer in
    let%bind () = print (Editor_share.offer_id offer) in
    let%bind _ = Reader.read_line (Lazy.force Reader.stdin) in
    let%bind withdrawn = Editor_share.withdraw offer in
    let%bind () =
      match withdrawn with
      | Ok () -> return ()
      | Error error ->
        let%bind () =
          print ("withdraw-error: " ^ Sexp.to_string_mach (Error.sexp_of_t error))
        in
        (* Let the independent reader probe the lock while we're still alive. *)
        let%map _ = Reader.read_line (Lazy.force Reader.stdin) in
        ()
    in
    let%bind withdrawn = Editor_share.withdraw offer in
    Or_error.ok_exn withdrawn;
    return ()
  | _ -> failwith "Invalid editor share probe arguments"
;;

let () =
  don't_wait_for
    (let%map result = Monitor.try_with_or_error main in
     match result with
     | Ok () -> Shutdown.shutdown 0
     | Error err ->
       eprintf "%s\n%!" (Error.to_string_hum err);
       Shutdown.shutdown 1);
  never_returns (Scheduler.go ())
;;
