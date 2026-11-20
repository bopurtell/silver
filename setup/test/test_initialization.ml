open! Core
module Initialization = Hardcaml_workbench_setup.Initialization
module Adoption = Hardcaml_workbench_setup.Asic_adoption
module Asic_config = Hardcaml_workbench_project_integration.Asic_config

let with_project f =
  let root = Filename_unix.temp_dir "workbench-init-test-" "" in
  Exn.protect
    ~f:(fun () ->
      Out_channel.write_all
        (Filename.concat root "dune-project")
        ~data:"(lang dune 3.22)\n";
      f root)
    ~finally:(fun () ->
      let common = Filename.concat root ".workbench" in
      if Sys_unix.file_exists_exn common
      then (
        List.iter (Sys_unix.ls_dir common) ~f:(fun name ->
          Core_unix.unlink (Filename.concat common name));
        Core_unix.rmdir common);
      List.iter (Sys_unix.ls_dir root) ~f:(fun name ->
        Core_unix.unlink (Filename.concat root name));
      Core_unix.rmdir root)
;;

let prepare_exn root =
  match Initialization.prepare ~root () with
  | Ok plan -> plan
  | Error message -> failwith message
;;

let%test_unit "adoption records the existing executable without running or replacing it" =
  with_project (fun root ->
    let filename = "design (existing).exe" in
    let path = Filename.concat root filename in
    let source = "#!/bin/sh\ntouch \"$0.invoked\"\n" in
    Out_channel.write_all path ~data:source;
    Core_unix.chmod path ~perm:0o700;
    let generic = Filename.concat root "hardcaml-workbench.sexp" in
    Out_channel.write_all generic ~data:"existing generic configuration";
    assert (Result.is_ok (Adoption.check ~root));
    assert (not (Sys_unix.file_exists_exn (Filename.concat root ".workbench")));
    assert (Result.is_ok (Adoption.adopt ~root ~executable:filename));
    let config_path =
      Filename.concat (Filename.concat root ".workbench") Asic_config.filename
    in
    let contents = In_channel.read_all config_path in
    (match Or_error.ok_exn (Asic_config.parse_project contents) with
     | `Discover resolve ->
       let config = resolve "/installed/provider" in
       [%test_eq: string] config.project_executable path;
       [%test_eq: string] config.toolchain (Filename.concat root "_flow_tools")
     | `Explicit _ -> failwith "Expected environment provider discovery");
    assert (Result.is_error (Adoption.adopt ~root ~executable:path));
    [%test_eq: string] (In_channel.read_all config_path) contents;
    [%test_eq: string] (In_channel.read_all generic) "existing generic configuration";
    [%test_eq: string] (In_channel.read_all path) source;
    assert (not (Sys_unix.file_exists_exn (path ^ ".invoked")));
    [%test_eq: string list]
      (Sys_unix.ls_dir (Filename.dirname config_path))
      [ Asic_config.filename ])
;;

let%test_unit "invalid inputs and occupied legacy ASIC path leave project untouched" =
  with_project (fun root ->
    List.iter [ "missing"; "dune-project"; "." ] ~f:(fun executable ->
      assert (Result.is_error (Adoption.adopt ~root ~executable)));
    let path = Filename.concat root Asic_config.filename in
    Core_unix.symlink ~target:"missing" ~link_name:path;
    assert (Result.is_error (Adoption.check ~root));
    assert (Result.is_error (Adoption.adopt ~root ~executable:"/bin/sh"));
    [%test_eq: string] (Core_unix.readlink path) "missing";
    assert (not (Sys_unix.file_exists_exn (Filename.concat root ".workbench"))))
;;

let%test_unit "only direct project roots accepted by the opener can be initialized" =
  with_project (fun root ->
    let nested = Filename.concat root "nested" in
    Core_unix.mkdir nested;
    Exn.protect
      ~f:(fun () ->
        Out_channel.write_all (Filename.concat nested "dune") ~data:"";
        assert (Result.is_error (Initialization.prepare ~root:nested ()));
        assert (Result.is_ok (Initialization.prepare ~root ())))
      ~finally:(fun () ->
        Core_unix.unlink (Filename.concat nested "dune");
        Core_unix.rmdir nested))
;;

let%test_unit "publication refuses a file or dangling symlink created after preparation" =
  List.iter [ `File; `Symlink ] ~f:(fun occupant ->
    with_project (fun root ->
      let plan = prepare_exn root in
      let path = Initialization.path plan in
      Core_unix.mkdir (Filename.dirname path);
      (match occupant with
       | `File -> Out_channel.write_all path ~data:"created by another writer\n"
       | `Symlink ->
         Core_unix.symlink ~target:(Filename.concat root "missing") ~link_name:path);
      assert (Result.is_error (Initialization.publish plan));
      (match occupant with
       | `File ->
         [%test_eq: string] (In_channel.read_all path) "created by another writer\n"
       | `Symlink ->
         [%test_eq: string] (Core_unix.readlink path) (Filename.concat root "missing"));
      [%test_eq: string list]
        (List.sort (Sys_unix.ls_dir (Filename.dirname path)) ~compare:String.compare)
        [ "hardcaml-workbench.sexp" ]))
;;

let%test_unit "publishing the same plan twice preserves the complete first publication" =
  with_project (fun root ->
    let plan = prepare_exn root in
    assert (Result.is_ok (Initialization.publish plan));
    [%test_eq: string]
      (In_channel.read_all (Initialization.path plan))
      (Initialization.contents plan);
    assert (Result.is_error (Initialization.publish plan));
    [%test_eq: string]
      (In_channel.read_all (Initialization.path plan))
      (Initialization.contents plan);
    [%test_eq: int] (List.length (Sys_unix.ls_dir root)) 2)
;;
