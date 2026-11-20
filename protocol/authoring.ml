(** The host interprets all destinations. Clients select a recipe and supply its input;
    they never submit source text or filesystem edit instructions. Preview IDs are one-use
    and scoped to a running service. File and registration paths in replies are relative
    to the preview destination. *)
open! Core

let capability = "authoring"
let rpc_path = "/api/v1/authoring"

module Target = struct
  type t =
    { destination : string (** Absolute directory on the service host. *)
    ; project : Project_id.t option
    ; object_id : string option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Operation = struct
  type t =
    { target : Target.t
    ; recipe : string
    ; name : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Request = struct
  type t =
    | Preview of Operation.t
    | Apply of { preview_id : string }
    | Cancel of { preview_id : string }
  [@@deriving bin_io, compare, equal, sexp]
end

module Registration = struct
  type t =
    { path : string
    ; snippet : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module File = struct
  type t =
    { path : string
    ; contents : string
    }
  [@@deriving bin_io, compare, equal, sexp]
end

let starter_recipe = "hardcaml-asic-starter-v1"
let add_to_project_recipe = "hardcaml-asic-add-to-project-v1"
let ip_empty_recipe = "hardcaml-ip-empty-v1"
let ip_sample_recipe = "hardcaml-ip-sample-v1"
let module_recipe = "hardcaml-module-v1"

let targets_project_root recipe =
  List.mem
    [ add_to_project_recipe; ip_empty_recipe; ip_sample_recipe; module_recipe ]
    recipe
    ~equal:String.equal
;;

module Preview = struct
  type t =
    { preview_id : string
    ; operation : Operation.t
    ; new_files : string list
    ; provider : string [@sexp.default ""]
    ; version : string [@sexp.default ""]
    ; files : File.t list [@sexp.default []]
    ; registration : Registration.t option
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Registration_result = struct
  type t =
    | Not_requested
    | Registered of string
    | Skipped of
        { path : string
        ; reason : string
        }
  [@@deriving bin_io, compare, equal, sexp]
end

module Failure = struct
  type kind =
    | Invalid_operation
    | Destination_denied
    | Stale_preview
    | Provider_failure
  [@@deriving bin_io, compare, equal, sexp]

  type t =
    { kind : kind
    ; message : string
    ; created_files : string list
    }
  [@@deriving bin_io, compare, equal, sexp]
end

module Response = struct
  type t =
    | Previewed of Preview.t
    | Applied of
        { created_files : string list
        ; registration : Registration_result.t
        }
    | Cancelled
    | Failed of Failure.t
  [@@deriving bin_io, compare, equal, sexp]
end
