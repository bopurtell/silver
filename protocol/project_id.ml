(** Identifies one opened project within a daemon session. *)

include Id.Make (struct
    let module_name = "Silver_protocol.Project_id"
  end)
