open! Core
open! Async

let command =
  Command.async
    ~summary:"Run the loopback-only Silver daemon"
    (let%map_open.Command port =
       flag "--port" (optional_with_default 0 int) ~doc:"PORT listen port"
     and discovery_dir =
       flag "--discovery-dir" (optional string) ~doc:"DIR publish discovery metadata"
     and state_dir =
       flag "--state-dir" (optional string) ~doc:"DIR absolute persistent state directory"
     and inspection_detail_cache_entries =
       flag
         "--inspection-detail-cache-entries"
         (optional_with_default Server_host.default_cache_entries int)
         ~doc:"N per-project reusable detail entries (0 disables; maximum 4096)"
     and inspection_detail_cache_bytes =
       flag
         "--inspection-detail-cache-bytes"
         (optional_with_default Server_host.default_cache_bytes int)
         ~doc:
           "N per-project serialized detail payload bytes (0 disables; maximum 268435456)"
     in
     fun () ->
       let%bind endpoint =
         Server_host.start
           ~port
           ~discovery_dir
           ~state_dir
           ~inspection_detail_cache_entries
           ~inspection_detail_cache_bytes
           ()
       in
       printf "silver-daemon listening on %s\n%!" endpoint;
       Server_host.handle_signals [ Signal.int; Signal.term ];
       Deferred.never ())
;;

let () = Command_unix.run command
