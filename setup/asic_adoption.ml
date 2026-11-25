open! Core
module Integration = Silver_project_integration
module Config = Integration.Asic_config

let check ~root =
  let%bind.Result root = Project_discovery.explicit_root root in
  Config_migration.require_absent ~root ~filename:Config.filename
;;

let adopt ~root ~executable =
  let%bind.Result root = Project_discovery.explicit_root root in
  let%bind.Result () = Config_migration.require_absent ~root ~filename:Config.filename in
  let%bind.Result contents =
    Or_error.try_with (fun () ->
      if String.is_empty (String.strip executable)
      then failwith "Enter a design executable";
      let path =
        if Filename.is_relative executable
        then Filename.concat root executable
        else executable
      in
      if not (Poly.equal (Core_unix.stat path).st_kind S_REG)
      then failwith (path ^ ": expected a regular design executable");
      Core_unix.access_exn path [ `Exec ];
      (* No provider pin: use the selected environment's provider discovery. *)
      let schema_version = 1 in
      let project_executable = path in
      let results_root = Filename.concat root "_flow_results/workbench/asic" in
      let toolchain = Filename.concat root "_flow_tools" in
      let contents =
        [%sexp
          { schema_version : int
          ; project_executable : string
          ; results_root : string
          ; toolchain : string
          ; python = (None : string option)
          ; support_tools = (None : string option)
          ; pdk_root = (None : string option)
          ; stage_timeout_seconds = (None : int option)
          }]
        |> Sexp.to_string_hum
      in
      contents ^ "\n")
    |> Result.map_error ~f:Error.to_string_hum
  in
  let%bind.Result directory = Config_migration.ensure_common_directory ~root in
  let path = Integration.Config_location.preferred_path ~root ~filename:Config.filename in
  No_clobber.publish ~directory ~path ~temporary_prefix:".asic-setup-" ~contents
;;
