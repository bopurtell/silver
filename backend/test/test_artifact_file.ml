open! Core
module Files = Hardcaml_workbench_backend.Simulation_files

let require yes message = if not yes then failwith message
let max_bytes = 64 * 1024 * 1024
let rejects f = require (Result.is_error (Or_error.try_with f)) "Expected file rejection"

let () =
  let dir = Core_unix.mkdtemp "/tmp/workbench-artifact-file-" |> Filename_unix.realpath in
  Exn.protect
    ~finally:(fun () -> Files.remove dir)
    ~f:(fun () ->
      let src = Filename.concat dir "source" in
      let dst = Filename.concat dir "captured" in
      let chunk = String.init 65536 ~f:(fun i -> Char.of_int_exn (i mod 251)) in
      let hash = Cryptokit.Hash.sha256 () in
      Out_channel.with_file src ~f:(fun out ->
        for _ = 1 to max_bytes / String.length chunk do
          Out_channel.output_string out chunk;
          hash#add_string chunk
        done);
      let expected = Files.hex hash#result in
      hash#wipe;
      let allocated f =
        let before = Stdlib.Gc.allocated_bytes () in
        let result = f () in
        let bytes = Stdlib.Gc.allocated_bytes () -. before in
        require
          Float.(bytes < 2. *. 1024. *. 1024.)
          "Whole-file allocation in streaming operation";
        result
      in
      let size, digest, page =
        allocated (fun () -> Files.read_page src ~max_bytes ~offset:65530 ~limit:20)
      in
      require
        (size = max_bytes
         && String.equal digest expected
         && String.equal page (String.suffix chunk 6 ^ String.prefix chunk 14))
        "Hash or cross-buffer slice mismatch";
      let reserved = ref 0 in
      let size, digest =
        allocated (fun () ->
          Files.capture ~src ~dst ~max_bytes ~reserve:(fun size -> reserved := size))
      in
      require
        (size = max_bytes && !reserved = size && String.equal digest expected)
        "Capture identity or reservation mismatch";
      let _, copied_hash, eof =
        Files.read_page dst ~max_bytes ~offset:max_bytes ~limit:1
      in
      require
        (String.equal copied_hash expected && String.is_empty eof)
        "Capture or EOF mismatch";
      let mode = (Core_unix.stat dst).st_perm land 0o777 in
      require (mode = 0o600) "Capture permissions changed";
      rejects (fun () ->
        Files.read_page src ~max_bytes:(max_bytes - 1) ~offset:0 ~limit:1);
      Core_unix.symlink ~target:src ~link_name:(Filename.concat dir "link");
      rejects (fun () ->
        Files.read_page (Filename.concat dir "link") ~max_bytes ~offset:0 ~limit:1);
      Core_unix.mkdir (Filename.concat dir "directory") ~perm:0o700;
      rejects (fun () ->
        Files.read_page (Filename.concat dir "directory") ~max_bytes ~offset:0 ~limit:1);
      Core_unix.mkfifo (Filename.concat dir "fifo") ~perm:0o600;
      rejects (fun () ->
        Files.read_page (Filename.concat dir "fifo") ~max_bytes ~offset:0 ~limit:1);
      (* Failed captures preserve the old destination and remove their private temporary
         file. *)
      Out_channel.write_all src ~data:"original";
      Out_channel.write_all dst ~data:"keep";
      rejects (fun () ->
        Files.capture ~src ~dst ~max_bytes ~reserve:(fun _ ->
          Out_channel.write_all src ~data:"short"));
      require
        (String.equal (In_channel.read_all dst) "keep")
        "Failed capture published bytes";
      require
        (not
           (List.exists (Sys_unix.ls_dir dir) ~f:(fun name ->
              String.is_substring name ~substring:".tmp-")))
        "Failed capture left temporary bytes";
      (* Deterministic mutation during the scan: never return a partial page/hash. *)
      List.iter
        [ "short"; String.make 131073 'g'; String.make 131072 'm' ]
        ~f:(fun changed ->
          Out_channel.write_all src ~data:(String.make 131072 'x');
          let fd = Core_unix.openfile src ~mode:[ O_RDONLY; O_CLOEXEC ] in
          Exn.protect
            ~finally:(fun () -> Core_unix.close fd)
            ~f:(fun () ->
              let mutated = ref false in
              rejects (fun () ->
                Hardcaml_workbench_backend.Artifact_file.scan
                  fd
                  ~max_bytes
                  ~offset:0
                  ~limit:1
                  ~sink:(fun _ _ ->
                    if not !mutated
                    then (
                      mutated := true;
                      Out_channel.write_all src ~data:changed;
                      Core_unix.utimes src ~access:1. ~modif:1.)))));
      Out_channel.write_all src ~data:"";
      let size, digest, page = Files.read_page src ~max_bytes ~offset:0 ~limit:65536 in
      require
        (size = 0 && String.equal digest (Files.digest "") && String.is_empty page)
        "Empty file identity mismatch")
;;
