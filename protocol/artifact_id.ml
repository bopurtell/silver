(** Identifies one stored artifact. Clients retrieve artifact content from the daemon by
    identifier; the artifact's filesystem location stays private to the backend. *)

include Id.Make (struct
    let module_name = "Silver_protocol.Artifact_id"
  end)
