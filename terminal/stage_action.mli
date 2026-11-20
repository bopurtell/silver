open! Core
open Hardcaml_workbench_protocol

(** Fresh endpoints do not imply an occurrence in the selected historical execution. *)
type intent =
  | Physical_stage of Asic.Stage.t
  | Fresh_endpoint of string

val endpoint : intent -> string
val advertised_selection : intent -> Asic.Selection.t option

val validate_evidence
  :  snapshot:Asic.Snapshot.t option
  -> observed:Asic.Selection.t option
  -> (unit, string) Result.t

val resolve_intent
  :  intent:intent
  -> remembered:Asic.Selection.t option
  -> observed:Asic.Selection.t option
  -> snapshot:Asic.Snapshot.t option
  -> (Asic.Selection.t, string) Result.t

(** A checklist action must match the current chip. Named fresh endpoints use that chip's
    launch inputs, never a historical chip's recipe. Legacy single-chip projects may use
    observed inputs when no explicit inputs were selected. *)
val resolve
  :  stage:Asic.Stage.t
  -> remembered:Asic.Selection.t option
  -> observed:Asic.Selection.t option
  -> snapshot:Asic.Snapshot.t option
  -> (Asic.Selection.t, string) Result.t
