open! Core
open Silver_protocol
open Authoring
module Engine = Silver_backend.Authoring_service

let ( / ) = Filename.concat
let check condition message = if not condition then failwith message
let unexpected r = raise_s [%message "Unexpected authoring response" (r : Response.t)]

let () =
  let root = Filename_unix.temp_dir "silver-bluespec-authoring-" "" |> Filename_unix.realpath in
  Exn.protect
    ~finally:(fun () -> Silver_backend.Simulation_files.remove root)
    ~f:(fun () ->
      Core_unix.mkdir (root / ".silver");
      let manifest = root / ".silver/project.json" in
      let write_manifest ?language () =
        Out_channel.write_all
          manifest
          ~data:
            (sprintf
               {|{"schema_version":1,"name":"demo","build_label":"//:rtl","test_label":"//:sim"%s}|}
               (Option.value_map language ~default:"" ~f:(sprintf {|,"language":%S|})))
      in
      let stat = Core_unix.stat root in
      let project_identity = stat.st_dev, stat.st_ino in
      let project = Project_id.of_string "project" in
      let engine = Engine.create ~permitted_roots:[ root ] in
      let run = Engine.handle ~project_identity ~bazel_project:true engine in
      let request ?object_id ?(recipe = ip_empty_recipe) name =
        { Operation.target = { destination = root; project = Some project; object_id }
        ; recipe
        ; name
        }
      in
      let preview op =
        match run (Preview op) with
        | Previewed p ->
          check (Operation.equal p.operation op) "Lost operation identity";
          check (String.equal p.provider "silver-bluespec-classic") "Wrong provider";
          List.iter p.new_files ~f:(fun file ->
            check (Poly.equal (Sys_unix.file_exists (root / file)) `No) "Preview wrote output");
          p
        | r -> unexpected r
      in
      let apply (p : Preview.t) = Engine.handle engine (Apply { preview_id = p.preview_id }) in
      let failure kind = function
        | Response.Failed f when Failure.equal_kind f.kind kind && List.is_empty f.created_files -> ()
        | r -> unexpected r
      in
      let apply_success (p : Preview.t) =
        match apply p with
        | Applied { created_files; registration } ->
          [%test_eq: string list] created_files p.new_files;
          List.iter p.files ~f:(fun f ->
            [%test_eq: string] (In_channel.read_all (root / f.path)) f.contents);
          failure Stale_preview (apply p);
          registration
        | r -> unexpected r
      in
      write_manifest ();
      failure Invalid_operation (run (Preview (request "fifo")));
      let write file data = Out_channel.write_all (root / file) ~data in
      List.iter
        [ "BUILD.bazel"; "MODULE.bazel"; "Counter.bs"; "simulation.bzl"; "simulation_provider.py" ]
        ~f:(fun path -> write path "# legacy starter fixture\n");
      let root_build = In_channel.read_all (root / "BUILD.bazel") in
      let module_request ?(dir = "ip/my_fifo") name = request ~object_id:dir ~recipe:module_recipe name in
      let root_module = preview (module_request ~dir:"." "next_stage") in
      [%test_eq: string list] root_module.new_files [ "Next_stage.bs" ];
      (match apply_success root_module with
       | Skipped { path = "BUILD.bazel"; _ } -> ()
       | _ -> failwith "Arbitrary BUILD should be left to manual registration");
      [%test_eq: string] (In_channel.read_all (root / "BUILD.bazel")) root_build;
      write_manifest ~language:"other" ();
      failure Invalid_operation (run (Preview (request "fifo")));
      write_manifest ~language:"bluespec-classic" ();
      List.iter
        [ "BUILD.bazel"; "MODULE.bazel"; "Counter.bs"; "simulation.bzl"; "simulation_provider.py" ]
        ~f:(fun path -> Core_unix.unlink (root / path));
      List.iter [ ""; "Fifo"; "my-fifo"; "0fifo"; "../fifo"; "prelude"; String.make 65 'a' ] ~f:(fun name ->
        failure Invalid_operation (run (Preview (request name))));
      failure Invalid_operation (run (Preview (request ~recipe:module_recipe "missing_dir")));
      failure Invalid_operation (run (Preview (request ~recipe:add_to_project_recipe "dune_only")));
      failure Destination_denied (run (Preview (module_request ~dir:"../out" "bad")));
      let primary = preview (request ~recipe:ip_sample_recipe "my_fifo") in
      [%test_eq: string list] primary.new_files [ "ip/my_fifo/My_fifo.bs"; "ip/my_fifo/BUILD.bazel" ];
      let file (p : Preview.t) path = (List.find_exn p.files ~f:(fun f -> String.equal f.path path)).contents in
      let source = file primary "ip/my_fifo/My_fifo.bs" in
      let build = file primary "ip/my_fifo/BUILD.bazel" in
      List.iter [ "package My_fifo"; "mkMy_fifo"; {| "increment": |} ] ~f:(fun substring ->
        check (String.is_substring source ~substring) ("Missing template content: " ^ substring));
      List.iter [ {|name = "sources"|}; {|glob(["*.bs"]|}; "//visibility:public" ] ~f:(fun substring ->
        check (String.is_substring build ~substring) ("Missing filegroup contract: " ^ substring));
      ignore (apply_success primary : Registration_result.t);
      failure Destination_denied (run (Preview (request "my_fifo")));
      let second = preview (module_request "my_stage") in
      [%test_eq: string list] second.new_files [ "ip/my_fifo/My_stage.bs" ];
      check (Option.is_none second.registration) "Generated glob should not need manual wiring";
      ignore (apply_success second : Registration_result.t);
      [%test_eq: string] (In_channel.read_all (root / "ip/my_fifo/BUILD.bazel")) build;
      let stale = preview (module_request "stale") in
      write "ip/my_fifo/BUILD.bazel" "# editor change\n";
      failure Stale_preview (apply stale);
      let stale = preview (module_request "collision") in
      write "ip/my_fifo/Collision.bs" "-- user contents\n";
      failure Stale_preview (apply stale);
      [%test_eq: string] (In_channel.read_all (root / "ip/my_fifo/Collision.bs")) "-- user contents\n";
      write "ip/my_fifo/Reserved.bsv" "// another package\n";
      failure Destination_denied (run (Preview (module_request "reserved")));
      let stale = preview (request "edited") in
      write_manifest ~language:"other" ();
      failure Stale_preview (apply stale);
      write_manifest ~language:"bluespec-classic" ();
      Core_unix.symlink ~target:(root / "ip/my_fifo") ~link_name:(root / "ip/symlink");
      failure Destination_denied (run (Preview (module_request ~dir:"ip/symlink" "bad")));
      write "ip/my_fifo/MODULE.bazel" "";
      failure Destination_denied (run (Preview (module_request "nested")));
      let unbound ?(destination = root) () : Request.t =
        Preview
          { target = { destination; project = None; object_id = None }
          ; name = "unbound"
          ; recipe = ip_empty_recipe
          }
      in
      (* Explicit Silver configuration wins even when a Dune marker is also present. *)
      write "dune-project" "(lang dune 3.22)\n";
      (match Engine.handle engine (unbound ()) with
       | Previewed p ->
         [%test_eq: string] p.provider "silver-bluespec-classic";
         ignore (apply_success p : Registration_result.t)
       | other -> unexpected other);
      Core_unix.rename ~src:(root / ".silver") ~dst:(root / ".silver-old");
      Core_unix.symlink ~target:(root / ".silver-old") ~link_name:(root / ".silver");
      failure Destination_denied (Engine.handle engine (unbound ()));
      let alias = root / "alias" in
      Core_unix.symlink ~target:root ~link_name:alias;
      failure Destination_denied (Engine.handle engine (unbound ~destination:alias ())))
;;
