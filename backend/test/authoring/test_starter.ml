open! Core
open Hardcaml_workbench_protocol.Authoring
module Engine = Hardcaml_workbench_backend.Authoring_service
module Starter = Hardcaml_workbench_backend.Authoring_starter

let ( / ) = Filename.concat

let descriptor files =
  {|{"schema_version":1,"provider":"hardcaml_asic","version":"0.1.0","files":[|}
  ^ String.concat
      ~sep:","
      (List.map files ~f:(fun path -> sprintf {|{"path":"%s","contents":"test\n"}|} path))
  ^ "]}"
;;

let () =
  List.iter
    [ []
    ; [ "/abs" ]
    ; [ "../up" ]
    ; [ "x//y" ]
    ; [ "." ]
    ; [ "x/" ]
    ; [ ".git/config" ]
    ; [ "a"; "a" ]
    ; [ "src/file"; "src" ]
    ; [ "src"; "src/file" ]
    ; List.init 129 ~f:Int.to_string
    ]
    ~f:(fun paths ->
      assert (
        Result.is_error (Result.try_with (fun () -> Starter.parse (descriptor paths)))));
  List.iter
    [ "{}"
    ; {|{"schema_version":1,"schema_version":1,"files":[]}|}
    ; String.substr_replace_all
        (descriptor [ "ok" ])
        ~pattern:"schema_version\":1"
        ~with_:"schema_version\":2"
    ; String.substr_replace_all
        (descriptor [ "ok" ])
        ~pattern:"\"contents\":"
        ~with_:"\"path\":\"hidden\",\"contents\":"
    ; String.make 10000 '['
    ; String.make (Starter.max_output + 1) ' '
    ]
    ~f:(fun text ->
      assert (Result.is_error (Result.try_with (fun () -> Starter.parse text))));
  let root = Filename_unix.temp_dir "wb-starter" "" |> Filename_unix.realpath in
  Exn.protect
    ~finally:(fun () -> Hardcaml_workbench_backend.Simulation_files.remove root)
    ~f:(fun () ->
      let real = Sys.getenv "WORKBENCH_TEST_STARTER_RENDERER" in
      let exe = root / Starter.program in
      let install script =
        Out_channel.write_all exe ~data:("#!/bin/sh\n" ^ script);
        Core_unix.chmod exe ~perm:0o700
      in
      (* This test process is single-domain. Install the controlled executable in a
         private PATH, exercising production argv/spawning/cleanup. *)
      (Core_unix.putenv [@alert "-unsafe_multidomain"])
        ~key:"PATH"
        ~data:(root ^ ":" ^ Sys.getenv_exn "PATH");
      let run = Engine.handle (Engine.create ~permitted_roots:[ root ]) in
      let op ?(name = "my-chip") path : Request.t =
        Preview
          { target = { destination = path; project = None; object_id = None }
          ; recipe = starter_recipe
          ; name
          }
      in
      let fail k = function
        | Response.Failed { kind; created_files = []; _ } when Failure.equal_kind k kind
          -> ()
        | r -> raise_s [%sexp (r : Response.t)]
      in
      let target = root / "project" in
      Core_unix.mkdir target;
      let rendered =
        [ "dune-project"
        ; "asic_my-chip/chip.ml"
        ; "asic_my-chip/project.ml"
        ; "asic_my-chip/dune"
        ]
      in
      let files =
        rendered
        @ [ ".workbench/hardcaml-workbench-asic.sexp"
          ; ".workbench/hardcaml-workbench-preparation.sexp"
          ]
      in
      let fixture () =
        install
          ("[ \"$#:$1:$2:$3\" = '3:render:--name:my-chip' ] || exit 2\n"
           ^ "cat <<'END'\n"
           ^ descriptor rendered
           ^ "\nEND\n")
      in
      fixture ();
      List.iter
        [ "A"; "aB"; "1demo"; ""; String.make 65 'a' ]
        ~f:(fun name -> fail Invalid_operation (run (op ~name target)));
      let preview path =
        match run (op path) with
        | Previewed p ->
          assert (String.equal p.provider "hardcaml_asic");
          assert (String.equal p.version "0.1.0");
          p
        | r -> raise_s [%sexp (r : Response.t)]
      in
      let apply (p : Preview.t) = run (Apply { preview_id = p.preview_id }) in
      let verify dest (p : Preview.t) =
        (match apply p with
         | Applied { created_files; registration = Registered path } ->
           assert (List.equal String.equal created_files (p.new_files @ [ path ]))
         | r -> raise_s [%sexp (r : Response.t)]);
        List.iter p.files ~f:(fun file ->
          assert (String.equal (In_channel.read_all (dest / file.path)) file.contents))
      in
      let frozen = preview target in
      assert (List.equal String.equal files frozen.new_files);
      assert (List.is_empty (Sys_unix.ls_dir target));
      let absent = root / "new" / "nested" in
      let fresh = preview absent in
      let stale = preview target in
      install "echo 'test render error' >&2\nexit 2";
      fail Provider_failure (run (op absent));
      assert (not (Sys_unix.file_exists_exn (root / "new")));
      install "yes X | head -c 300000";
      fail Provider_failure (run (op absent));
      install "echo '{}'";
      fail Provider_failure (run (op absent));
      Core_unix.unlink exe;
      verify target frozen;
      verify absent fresh;
      fail Stale_preview (apply stale);
      let existing root =
        run
          (Preview
             { target = { destination = root; project = None; object_id = None }
             ; recipe = add_to_project_recipe
             ; name = "my-chip"
             })
      in
      let expect_preview = function
        | Response.Previewed p -> p
        | r -> raise_s [%sexp (r : Response.t)]
      in
      let dir = root / "existing" in
      Core_unix.mkdir dir;
      fail Destination_denied (existing dir);
      Out_channel.write_all (dir / "dune-project") ~data:"(lang dune 3.17)\n";
      Core_unix.mkdir (dir / ".workbench");
      let write rel = Out_channel.write_all (dir / rel) ~data:"preserve\n" in
      write "source.ml";
      write ".workbench/other.sexp";
      let install_existing paths =
        install
          ("[ \"$1\" = render-target ] || exit 2\ncat <<'END'\n"
           ^ descriptor paths
           ^ "\nEND\n")
      in
      install_existing [ "dune-project" ];
      fail Provider_failure (existing dir);
      install_existing
        [ "asic_my-chip/chip.ml"; "asic_my-chip/project.ml"; "asic_my-chip/dune" ];
      let p = expect_preview (existing dir) in
      let config = ".workbench/hardcaml-workbench-asic.sexp" in
      write config;
      fail Stale_preview (apply p);
      assert (not (Sys_unix.file_exists_exn (dir / "asic_my-chip")));
      fail Destination_denied (existing dir);
      Core_unix.unlink (dir / config);
      write "hardcaml-workbench-preparation.sexp";
      fail Destination_denied (existing dir);
      Core_unix.unlink (dir / "hardcaml-workbench-preparation.sexp");
      Core_unix.symlink ~target ~link_name:(dir / "asic_my-chip");
      fail Destination_denied (existing dir);
      Core_unix.unlink (dir / "asic_my-chip");
      write "hardcaml-asic-targets.json";
      let p = expect_preview (existing dir) in
      assert (
        String.is_substring
          (Option.value_exn p.registration).snippet
          ~substring:"asic_my-chip/project.exe");
      (match apply p with
       | Applied { registration = Skipped { path; _ }; _ } ->
         assert (String.equal path "hardcaml-asic-targets.json")
       | r -> raise_s [%sexp (r : Response.t)]);
      List.iter
        [ "source.ml"; ".workbench/other.sexp"; "hardcaml-asic-targets.json" ]
        ~f:(fun path ->
          assert (String.equal (In_channel.read_all (dir / path)) "preserve\n"));
      assert (
        String.equal (In_channel.read_all (dir / "dune-project")) "(lang dune 3.17)\n");
      fail Destination_denied (existing dir);
      let add recipe ?object_id ?(name = "counter") () =
        run
          (Preview
             { target = { destination = dir; project = None; object_id }; recipe; name })
      in
      let render argv paths =
        install
          ("[ \"$*\" = '"
           ^ argv
           ^ "' ] || exit 2\ncat <<'END'\n"
           ^ descriptor paths
           ^ "\nEND\n")
      in
      let cancel p =
        (match run (Cancel { preview_id = p.Preview.preview_id }) with
         | Cancelled -> ()
         | r -> raise_s [%sexp (r : Response.t)]);
        fail Stale_preview (apply p)
      in
      let applied = function
        | Response.Applied _ -> ()
        | r -> raise_s [%sexp (r : Response.t)]
      in
      let chip ?(source = Chip_source.Example) ?(register = true) name =
        run
          (Preview_chip
             { source
             ; register
             ; name
             ; target =
                 { destination = dir
                 ; object_id = None
                 ; project =
                     Some (Hardcaml_workbench_protocol.Project_id.of_string "open")
                 }
             })
      in
      let paths name =
        List.map [ "chip.ml"; "project.ml"; "dune" ] ~f:(fun file ->
          "asic_" ^ name ^ "/" ^ file)
      in
      let catalog = dir / "hardcaml-asic-targets.json" in
      let initial =
        {|{"schema_version":1,"default_target":"first","targets":[{"id":"first","executable":"first/project.exe"}]}|}
      in
      Out_channel.write_all catalog ~data:initial;
      render "render-target --name first" (paths "first");
      fail Destination_denied (chip "first");
      fail Destination_denied (chip ~register:false "first");
      render "render-target --name second" (paths "second");
      let p = expect_preview (chip "second") in
      assert (not (Option.value_exn p.registration).manual);
      Out_channel.write_all catalog ~data:(initial ^ "\n");
      fail Stale_preview (apply p);
      assert (not (Sys_unix.file_exists_exn (dir / "asic_second")));
      assert (String.equal (In_channel.read_all catalog) (initial ^ "\n"));
      applied (apply (expect_preview (chip "second")));
      let now = In_channel.read_all catalog in
      assert (String.is_substring now ~substring:{|"default_target": "first"|});
      assert (String.is_substring now ~substring:{|"id": "second"|});
      fail Destination_denied (chip "second");
      render "render-target --name direct" (paths "direct");
      let p = expect_preview (chip ~register:false "direct") in
      assert (Option.is_none p.registration);
      applied (apply p);
      assert (String.equal now (In_channel.read_all catalog));
      let custom =
        String.substr_replace_first
          now
          ~pattern:"\"targets\""
          ~with_:"\"owner\":true,\"targets\""
      in
      Out_channel.write_all catalog ~data:custom;
      render "render-target --name third" (paths "third");
      let p = expect_preview (chip "third") in
      assert (Option.value_exn p.registration).manual;
      applied (apply p);
      assert (String.equal custom (In_channel.read_all catalog));
      List.iter
        [ ip_empty_recipe, "empty"; ip_sample_recipe, "sample" ]
        ~f:(fun (recipe, template) ->
          let name = template in
          let base = "ip/" ^ name in
          render
            ("render-ip --name " ^ name ^ " --template " ^ template)
            [ base ^ "/dune"; base ^ "/block.ml" ];
          let op () = add recipe ~name () in
          fail Invalid_operation (add recipe ~name:"bad-name" ());
          fail Invalid_operation (add recipe ~object_id:"ip" ());
          let p = expect_preview (op ()) in
          cancel p;
          assert (not (Sys_unix.file_exists_exn (dir / base)));
          let p = expect_preview (op ()) in
          let new_parent = not (Sys_unix.file_exists_exn (dir / "ip")) in
          if new_parent then Core_unix.mkdir (dir / "ip");
          Core_unix.mkdir (dir / base);
          fail Stale_preview (apply p);
          assert (List.is_empty (Sys_unix.ls_dir (dir / base)));
          Core_unix.rmdir (dir / base);
          if new_parent then Core_unix.rmdir (dir / "ip");
          applied (apply (expect_preview (op ())));
          fail Destination_denied (op ()));
      let lib = "ip/sample" in
      let module_op ?(object_id = lib) () = add module_recipe ~object_id () in
      fail Invalid_operation (add module_recipe ());
      List.iter
        [ ""
        ; "../out"
        ; "ip/../sample"
        ; "/lib"
        ; ".git"
        ; "ip//sample"
        ; "ip/sample/"
        ; "ip/./sample"
        ]
        ~f:(fun object_id -> fail Destination_denied (module_op ~object_id ()));
      Core_unix.symlink ~target:(dir / lib) ~link_name:(dir / "lib-link");
      fail Destination_denied (module_op ~object_id:"lib-link" ());
      let dune = dir / lib / "dune" in
      let custom = "(library (name ip_sample) (modules Block))\n" in
      render "render-module --name counter" [ "counter.ml" ];
      Out_channel.write_all dune ~data:"(executable (name app))";
      fail Destination_denied (module_op ());
      Out_channel.write_all dune ~data:custom;
      let p = expect_preview (module_op ()) in
      assert (List.equal String.equal p.new_files [ lib ^ "/counter.ml" ]);
      let guidance = Option.value_exn p.registration in
      assert (String.equal guidance.path (lib ^ "/dune"));
      assert (String.is_substring guidance.snippet ~substring:"Counter");
      Out_channel.write_all dune ~data:(custom ^ "; changed\n");
      fail Stale_preview (apply p);
      assert (not (Sys_unix.file_exists_exn (dir / lib / "counter.ml")));
      let p = expect_preview (module_op ()) in
      write (lib ^ "/counter.ml");
      fail Stale_preview (apply p);
      fail Destination_denied (module_op ());
      Core_unix.unlink (dir / lib / "counter.ml");
      cancel (expect_preview (module_op ()));
      (match apply (expect_preview (module_op ())) with
       | Applied { registration = Skipped _; _ } -> ()
       | r -> raise_s [%sexp (r : Response.t)]);
      assert (String.equal (In_channel.read_all dune) (custom ^ "; changed\n"));
      Out_channel.write_all (dir / "dune") ~data:"(library (name root))\n";
      render "render-module --name counter" [ "wrong.ml" ];
      fail Provider_failure (module_op ~object_id:"." ());
      render "render-module --name counter" [ "counter.ml" ];
      let p = expect_preview (module_op ~object_id:"." ()) in
      assert (Option.is_none p.registration);
      applied (apply p);
      Core_unix.unlink exe;
      Option.iter real ~f:(fun renderer ->
        Core_unix.symlink ~target:renderer ~link_name:exe;
        let dest = root / "actual" in
        let p = preview dest in
        assert (List.mem p.new_files "dune-project" ~equal:String.equal);
        assert (List.mem p.new_files "asic_my-chip/chip.ml" ~equal:String.equal);
        verify dest p;
        let incremental recipe object_id name =
          expect_preview
            (run
               (Preview
                  { target = { destination = dest; project = None; object_id }
                  ; recipe
                  ; name
                  }))
        in
        List.iter
          [ ip_empty_recipe, "blank"; ip_sample_recipe, "sample" ]
          ~f:(fun (recipe, name) ->
            applied (apply (incremental recipe None name));
            let library = "ip/" ^ name in
            applied (apply (incremental module_recipe (Some library) "extra"));
            assert (Sys_unix.file_exists_exn (dest / library / "extra.ml")));
        let p =
          expect_preview
            (run
               (Preview_chip
                  { target =
                      { destination = dest
                      ; project =
                          Some (Hardcaml_workbench_protocol.Project_id.of_string "p")
                      ; object_id = None
                      }
                  ; name = "chip_b"
                  ; source = Example
                  ; register = true
                  }))
        in
        (match apply p with
         | Applied { registration = Registered path; _ } ->
           assert (String.equal path "hardcaml-asic-targets.json")
          | r -> raise_s [%sexp (r : Response.t)]);
         let module I = Hardcaml_workbench_project_integration in
         let moved = root / "relocated-checkout" in
         Core_unix.rename ~src:dest ~dst:moved;
         let dest = moved in
        let load filename =
          (I.Config_location.resolve ~root:dest ~filename ~max_bytes:65536
           |> Or_error.ok_exn
           |> Option.value_exn)
            .contents
        in
        let prep =
          I.Preparation_config.parse_string
            ~root:dest
            (load I.Preparation_config.filename)
          |> Or_error.ok_exn
        in
        match
          I.Asic_config.parse_project ~root:dest (load I.Asic_config.filename)
          |> Or_error.ok_exn
        with
        | `Explicit _ -> assert false
        | `Discover resolve ->
          let config = resolve "/bin/provider" in
          assert (
            String.equal
              (I.Preparation_config.source_executable prep ~root:dest)
              config.project_executable);
          assert (Sys_unix.file_exists_exn (dest / "asic_my-chip/project.ml"))))
;;
