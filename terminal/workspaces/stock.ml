open! Core
open Silver_protocol

(** The editable stock spec and the protocol-owned Editor definition form one catalog; the
    registry and preset/restore commands share the Editor's layout. *)
let config =
  let base = Workspace_config.Resolved.decode Stock_data.text |> Or_error.ok_exn in
  let config = Workspace_config.with_stock_editor base in
  Workspace_config.Resolved.validate config |> Or_error.ok_exn;
  config
;;

let find key =
  List.find config.definitions ~f:(fun d ->
    String.equal d.Workspace_config.Definition.key key)
  |> Option.value_exn
;;
