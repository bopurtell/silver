open! Core

let () =
  let root = Filename_unix.temp_dir "silver-runtime-paths-" "" in
  let canonical = root ^/ "silver" in
  let legacy = root ^/ "hardcaml-workbench" in
  let named suffix = Silver_native_http.Runtime.named_directory ~root ~suffix in
  Exn.protect
    ~finally:(fun () ->
      List.iter [ canonical ^/ "terminal"; legacy ^/ "terminal"; canonical; legacy; root ]
        ~f:(fun path ->
          if Sys_unix.file_exists_exn path then Core_unix.rmdir path))
    ~f:(fun () ->
      assert (String.equal (named "") canonical);
      Core_unix.mkdir legacy;
      assert (String.equal (named "") legacy);
      Core_unix.mkdir (legacy ^/ "terminal");
      assert (String.equal (named "terminal") (legacy ^/ "terminal"));
      Core_unix.mkdir canonical;
      assert (String.equal (named "terminal") (legacy ^/ "terminal"));
      assert (Result.is_error (Or_error.try_with (fun () -> named "")));
      Core_unix.mkdir (canonical ^/ "terminal");
      assert (Result.is_error (Or_error.try_with (fun () -> named "terminal"))))
