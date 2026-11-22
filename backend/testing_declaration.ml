open! Core
open! Async
open Hardcaml_workbench_protocol

let action : Module_jump.Action.t = { id = "declaration"; label = "Declaration" }

let provider : Simulation.Declaration.t Module_jump.Provider.t =
  Module_jump.Provider.create
    ~offer:(fun ~project:_ ~selection:_ -> [ action ])
    ~resolve:(fun ~project ~(selection : Simulation.Declaration.t) ~action_id ->
      Deferred.return
        (if String.equal action_id action.id
         then
           Module_jump.Resolution.Direct
             { project
             ; relative_path = selection.relative_path
             ; line = Some selection.line
             ; column = Some selection.column
             ; source_identity = None
             }
         else Unavailable "Unknown Testing jump action"))
;;

let offer ~project ~declarations ~suite_id ~case_id =
  match
    List.filter declarations ~f:(fun declaration ->
      String.equal declaration.Simulation.Declaration.suite_id suite_id
      && String.equal declaration.case_id case_id)
  with
  | [ selection ] when Hardcaml_workbench_provider.Validation.valid_declaration selection
    -> Ok (List.hd_exn (Module_jump.offer provider ~project ~selection))
  | [] -> Error "The provider did not report a declaration for this test"
  | _ -> Error "The provider reported an invalid declaration for this test"
;;
