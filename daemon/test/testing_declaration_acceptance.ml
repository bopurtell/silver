open! Core
open! Async
open Silver_protocol
module Backend = Silver_backend
module Jump = Backend.Module_jump
module Testing = Backend.Testing_declaration
module Service = Backend.Service
module Files = Backend.Simulation_files
module Rpc = Silver_rpc_server.Rpc_server
module Client = Silver_native_http.Client
module Config = Silver_project_integration.Simulation_config

let require condition message = if not condition then failwith message

let rpc_ok result =
  match Or_error.ok_exn result with
  | Ok value -> value
  | Error error -> raise_s [%message "RPC failed" (error : V1.Error.t)]
;;

let relative_path = "ip/controlled_fifo/verif/simulation/test_provider.ml"
let suite_id = "controlled-fifo"
let case_ids = [ "directed"; "seeded"; "export-stress" ]

let expected_location ~project ~source case_id =
  let marker = sprintf "case [%%here] %S" case_id in
  let line, column =
    List.filter_mapi source ~f:(fun i line ->
      match String.substr_index line ~pattern:marker with
      | None -> None
      | Some start ->
        let marker_start = start + String.length "case " in
        require
          (String.for_all (String.prefix line marker_start) ~f:(fun c ->
             Char.to_int c >= 32 && Char.to_int c < 127))
          "Fixture's byte column no longer equals its display-cell column";
        Some (i + 1, marker_start + 1))
    |> function
    | [ location ] -> location
    | _ -> failwith ("Expected one OCaml registration for " ^ case_id)
  in
  { Jump.Location.project
  ; relative_path
  ; line = Some line
  ; column = Some column
  ; source_identity = None
  }
;;

let main provider example_root () =
  let provider = Filename_unix.realpath provider in
  let source = In_channel.read_all (Filename.concat example_root relative_path) in
  let directory = Filename_unix.temp_dir "testing-declaration-" "" in
  let root = Filename.concat directory "project" in
  let config_path = Filename.concat root Config.filename in
  let write_config provider_executable =
    let config : Config.t =
      { schema_version = 1
      ; provider_executable
      ; provider_args = []
      ; discovery_timeout_seconds = 10
      ; run_timeout_seconds = 10
      ; max_parallel_runs = 1
      }
    in
    Out_channel.write_all config_path ~data:(Sexp.to_string (Config.sexp_of_t config))
  in
  let service = ref None in
  let server = ref None in
  Monitor.protect
    ~finally:(fun () ->
      let%bind () =
        Option.value_map !server ~default:Deferred.unit ~f:Cohttp_async.Server.close
      in
      let%bind () =
        Option.value_map !service ~default:Deferred.unit ~f:Service.shutdown
      in
      In_thread.run (fun () -> Files.remove directory))
    (fun () ->
      let%bind () =
        In_thread.run (fun () ->
          Core_unix.mkdir_p (Filename.dirname (Filename.concat root relative_path));
          Out_channel.write_all (Filename.concat root relative_path) ~data:source;
          Out_channel.write_all
            (Filename.concat root "dune-project")
            ~data:"(lang dune 3.22)\n(name fifo_declaration_fixture)\n";
          write_config provider)
      in
      let instance_id = "testing-declaration" in
      let%bind srv =
        Service.create
          ~instance_id
          ~state_dir:(Filename.concat directory "state")
          ~log_dir:(Filename.concat directory "logs")
          ()
        >>| Or_error.ok_exn
      in
      service := Some srv;
      let rpc = Rpc.create ~application_version:"testing-declaration-test" ~instance_id ~service:srv in
      let%bind http =
        Cohttp_async.Server.create
          ~on_handler_error:`Ignore
          (Tcp.Where_to_listen.bind_to
             Tcp.Bind_to_address.Localhost
             Tcp.Bind_to_port.On_port_chosen_by_os)
          (Rpc.callback rpc)
      in
      server := Some http;
      let client =
        Client.create
          ~timeout:(Time_float.Span.of_sec 5.)
          (sprintf "http://127.0.0.1:%d" (Cohttp_async.Server.listening_on http))
      in
      let%bind opened =
        Client.open_project client { instance_id; root; environment = Inherit_daemon }
        >>| rpc_ok
      in
      let project = opened.project.id in
      let simulation operation =
        Client.simulation client { instance_id; project; operation } >>| rpc_ok
      in
      let%bind (_ : Simulation.Snapshot.t) = simulation Discover in
      let rec wait () =
        let%bind snapshot = simulation Get in
        Option.iter snapshot.discovery_error ~f:failwith;
        if Option.is_some snapshot.discovery_digest
        then return snapshot
        else (
          let%bind () = Clock.after (Time_float.Span.of_ms 30.) in
          wait ())
      in
      let%bind snapshot =
        match%map Clock.with_timeout (Time_float.Span.of_sec 15.) (wait ()) with
        | `Result snapshot -> snapshot
        | `Timeout -> failwith "FIFO discovery did not publish a catalog"
      in
      require (List.is_empty snapshot.attempts) "A test ran before discovery";
      let discovery = Option.value_exn snapshot.discovery in
      let suite =
        List.find_exn discovery.suites ~f:(fun suite -> String.equal suite.id suite_id)
      in
      require
        (List.equal String.equal case_ids (List.map suite.cases ~f:(fun case -> case.id)))
        "Wrong FIFO catalog";
      let%bind legacy_wire =
        Client.post
          client
          ~path:Simulation.rpc_path
          ~sexp_of_request:Simulation.Request.sexp_of_t
          ~response_of_sexp:Fn.id
          { instance_id; project; operation = Get }
        >>| Or_error.ok_exn
      in
      let legacy =
        Simulation.Response.t_of_sexp legacy_wire |> Result.ok |> Option.value_exn
      in
      require
        (Sexp.equal legacy_wire (Simulation.Response.sexp_of_t (Ok legacy))
         && List.is_empty legacy.declarations
         && Option.equal Simulation.Discovery.equal legacy.discovery snapshot.discovery)
        "Unnegotiated response changed the legacy catalog or contained a new field";
      require
        (Result.is_error
           (Testing.offer ~project ~declarations:[] ~suite_id ~case_id:"directed")
         && Result.is_error
              (Testing.offer
                 ~project
                 ~declarations:snapshot.declarations
                 ~suite_id
                 ~case_id:"Directed FIFO tests"))
        "Missing metadata or display-label selection invented a jump";
      let request case_id =
        let offer =
          Testing.offer ~project ~declarations:snapshot.declarations ~suite_id ~case_id
          |> Result.ok
          |> Option.value_exn
        in
        require
          (Jump.Action.equal
             (Jump.Offer.action offer)
             { id = "declaration"; label = "Declaration" })
          "Unexpected Testing action";
        Jump.capture offer
      in
      let requests = List.map case_ids ~f:(fun case_id -> case_id, request case_id) in
      let recorded = ref [] in
      let%bind () =
        Deferred.List.iter requests ~how:`Sequential ~f:(fun (case_id, request) ->
          let%map response = Jump.resolve request in
          require
            (Jump.Response.matches response request)
            "Resolution lost invocation identity";
          match Jump.Response.resolution response with
          | Direct location -> recorded := (case_id, location) :: !recorded
          | Ambiguous _ | Unavailable _ ->
            failwith "Reported FIFO declaration was not direct")
      in
      List.iter !recorded ~f:(fun (case_id, actual) ->
        let expected =
          expected_location ~project ~source:(String.split_lines source) case_id
        in
        if not (Jump.Location.equal expected actual)
        then
          raise_s
            [%message
              "Incorrect registration location"
                (expected : Jump.Location.t)
                (actual : Jump.Location.t)]);
      let%bind after = simulation Get in
      require
        (List.is_empty after.attempts)
        "Declaration resolution launched a simulation";
      let%bind () =
        In_thread.run (fun () -> write_config (Filename.concat root "not-a-provider"))
      in
      let%map stale = simulation Get in
      require
        (Option.is_some stale.discovery && List.is_empty stale.declarations)
        "Stale discovery coordinates remained available after a configuration change";
      printf "Real FIFO registrations resolved through HTTP and Module_jump\n%!")
;;

let () =
  let open Command.Let_syntax in
  Command.async
    ~summary:"Headless testing declaration acceptance with the real FIFO provider (no test runs)"
    (let%map_open provider =
       flag "--provider" (required string) ~doc:"PATH FIFO test_provider.exe"
     and root =
       flag "--example-root" (required string) ~doc:"PATH FIFO source checkout"
     in
     main provider root)
  |> Command_unix.run
;;
