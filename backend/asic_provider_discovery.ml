open! Core
open! Async
module Adapter = Hardcaml_workbench_adapters.Asic_adapter

let candidates ~override ~path =
  match override with
  | Some path ->
    if not (Filename.is_absolute path)
    then failwith "SILVER_ASIC_PROVIDER must be an absolute executable path";
    [ path ]
  | None ->
    String.split path ~on:':'
    |> List.filter ~f:Filename.is_absolute
    |> List.stable_dedup ~compare:String.compare
    |> List.concat_map ~f:(fun dir ->
      List.map [ "hardcaml-asic-flow"; "hardcaml_asic" ] ~f:(Filename.concat dir))
;;

let find ?(environment = Hardcaml_workbench_protocol.V1.Environment_selection.Inherit_daemon)
    ~override ~path () =
  let rec loop = function
    | [] ->
      failwith
        "No compatible ASIC provider (CLI4 + namedflow1=true); set SILVER_ASIC_PROVIDER \
         to an absolute executable or install hardcaml-asic-flow on PATH"
    | program :: rest ->
      let%bind result = Monitor.try_with (fun () ->
        let%bind () = In_thread.run (fun () ->
          if not (Poly.equal (Core_unix.stat program).st_kind S_REG)
          then failwith "not a regular file";
          Core_unix.access_exn program [ `Exec ]) in
        let%map output =
          Asic_process.run ~seconds:3. ~stop_grace_seconds:0.2
            ~max_stdout_bytes:(1024 * 1024) ~max_record_bytes:(1024 * 1024)
            ~cancel:(Deferred.never ()) ~on_process:ignore ~on_line:(fun _ -> Deferred.unit)
            (Adapter.invocation ~root:"/" ~environment program [ "--version"; "--json" ])
        in
        Asic_public.metadata (Asic_public.decode output))
      in
      (match result, override with
       | Ok (), _ -> return program
       | Error exn, Some _ -> failwithf "Invalid SILVER_ASIC_PROVIDER %s: %s" program (Exn.to_string exn) ()
       | Error _, None -> loop rest)
  in
  loop (candidates ~override ~path)
;;

let discover ?environment () =
  find ?environment ~override:(Sys.getenv "SILVER_ASIC_PROVIDER")
    ~path:(Option.value (Sys.getenv "PATH") ~default:"") ()
;;
