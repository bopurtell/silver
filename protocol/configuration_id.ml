(** Identifies one build configuration a project offers for a target. *)

include Id.Make (struct
    let module_name = "Silver_protocol.Configuration_id"
  end)
