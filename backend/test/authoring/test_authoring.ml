open! Core
open Hardcaml_workbench_protocol
open Authoring
module Engine = Hardcaml_workbench_backend.Authoring_service

let check yes message = if not yes then failwith message
let unexpected r = raise_s [%message "Unexpected authoring response" (r : Response.t)]
let ( / ) = Filename.concat
let mkdir path = Core_unix.mkdir path ~perm:0o700

let () =
  let base = Filename_unix.temp_dir "wb-authoring-" "" in
  Exn.protect
    ~finally:(fun () -> Hardcaml_workbench_backend.Simulation_files.remove base)
    ~f:(fun () ->
      let base = Filename_unix.realpath base in
      let root = base / "permitted" in
      let outside = root ^ "-other" in
      mkdir root;
      mkdir outside;
      let state = Engine.create ~permitted_roots:[ root ] in
      let run = Engine.handle state in
      let op
        ?project
        ?object_id
        ?(recipe = Engine.controlled_recipe)
        ?(name = "block")
        path
        =
        { Operation.recipe; name; target = { destination = path; project; object_id } }
      in
      let preview op =
        match run (Preview op) with
        | Previewed p ->
          check (Operation.equal op p.operation) "Lost operation identity";
          p
        | r -> unexpected r
      in
      let apply (p : Preview.t) = run (Apply { preview_id = p.preview_id }) in
      let cancel (p : Preview.t) = run (Cancel { preview_id = p.preview_id }) in
      let failure kind = function
        | Response.Failed f
          when Failure.equal_kind f.kind kind && List.is_empty f.created_files -> ()
        | r -> unexpected r
      in
      let empty path = check (List.is_empty (Sys_unix.ls_dir path)) "Unexpected write" in
      let nested = root / "missing" / "destination" in
      let p = preview (op nested) in
      let other = preview (op ~name:"other" nested) in
      check (not (String.equal p.preview_id other.preview_id)) "Preview IDs alias";
      check (Response.equal (cancel p) Cancelled) "Cancel failed";
      failure Stale_preview (apply p);
      empty root;
      let successful path (p : Preview.t) =
        let expected = p.operation.name ^ ".txt" in
        check (List.equal String.equal p.new_files [ expected ]) "Incorrect file plan";
        let edit = Option.value_exn p.registration in
        check
          (String.equal edit.snippet (expected ^ "\n"))
          "No concrete registration edit";
        (match apply p with
         | Applied { created_files = [ actual ]; registration = Skipped { path; reason } }
           ->
           check
             (String.equal actual expected
              && String.equal path edit.path
              && not (String.is_empty reason))
             "Incorrect creation/registration result"
         | r -> unexpected r);
        check
          (List.equal String.equal (Sys_unix.ls_dir path) [ expected ])
          "Unexpected files";
        check
          (String.is_substring
             (In_channel.read_all (path / expected))
             ~substring:p.operation.name)
          "Recipe output disagrees with preview";
        failure Stale_preview (apply p)
      in
      successful nested other;
      let target = root / "empty" in
      mkdir target;
      let existing =
        preview (op ~project:(Project_id.of_string "p") ~object_id:"obj" target)
      in
      empty target;
      successful target existing;
      let deny path = failure Destination_denied (run (Preview (op path))) in
      List.iter
        [ outside; root / ".." / Filename.basename outside; "relative"; target ]
        ~f:deny;
      failure Invalid_operation (run (Preview (op ~recipe:"arbitrary" nested)));
      failure Invalid_operation (run (Preview (op ~name:"../x" nested)));
      failure Stale_preview (run (Apply { preview_id = "forged" }));
      let occupied = root / "occupied" in
      mkdir occupied;
      let p = preview (op occupied) in
      let collision = occupied / "block.txt" in
      Out_channel.write_all collision ~data:"user work";
      failure Stale_preview (apply p);
      check
        (String.equal "user work" (In_channel.read_all collision))
        "Clobbered collision";
      let absent = root / "absent" in
      let p = preview (op absent) in
      mkdir absent;
      failure Stale_preview (apply p);
      empty absent;
      let p = preview (op absent) in
      Core_unix.rename ~src:absent ~dst:(root / "moved");
      mkdir absent;
      failure Stale_preview (apply p);
      empty absent;
      let p = preview (op (absent / "new")) in
      Core_unix.rmdir absent;
      Core_unix.symlink ~target:outside ~link_name:absent;
      failure Stale_preview (apply p);
      deny (absent / "new");
      empty outside;
      (* Preview needs only directory read access; distinguish a write failure with
         unchanged preconditions from a stale preview. *)
      if Core_unix.geteuid () <> 0
      then (
        let readonly = root / "readonly" in
        mkdir readonly;
        Core_unix.chmod readonly ~perm:0o555;
        Exn.protect
          ~finally:(fun () -> Core_unix.chmod readonly ~perm:0o755)
          ~f:(fun () ->
            failure Provider_failure (apply (preview (op readonly)));
            empty readonly)))
;;
