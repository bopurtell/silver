open Hardcaml_workbench_protocol

(** Offer “Declaration” for the exact stable suite/case in an observed catalog. Supply
    [declarations] from that same catalog snapshot. The offer captures the position and
    project; replacing the catalog or moving the cursor cannot retarget it. An absent
    position is an error suitable for display, not a fallback by display name. *)
val offer
  :  project:Project_id.t
  -> declarations:Simulation.Declaration.t list
  -> suite_id:string
  -> case_id:string
  -> (Module_jump.Offer.t, string) result
