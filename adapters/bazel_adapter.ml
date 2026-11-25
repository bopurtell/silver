open! Core
open Silver_protocol
module Manifest = Silver_project_integration.Silver_manifest

let action_invocation (manifest : Manifest.t) ~root ~environment action
  : Dune_adapter.Invocation.t
  =
  let command, label =
    match action with
    | V1.Dune_action.Build -> "build", manifest.build_label
    | Test -> "test", manifest.test_label
  in
  let argv = Dune_adapter.command_prefix environment @ [ "bazel"; command; label ] in
  { executable = List.hd_exn argv; argv; cwd = root; environment }
;;
