open! Core
open! Async
open Silver_protocol

module Location = struct
  type t =
    { project : Project_id.t
    ; relative_path : string
    ; line : int option
    ; column : int option
    ; source_identity : string option
    }
  [@@deriving compare, equal, sexp_of]
end

module Action = struct
  type t =
    { id : string
    ; label : string
    }
  [@@deriving compare, equal, sexp_of]
end

module Candidate = struct
  type t =
    { label : string
    ; location : Location.t
    }
  [@@deriving compare, equal, sexp_of]
end

module Resolution = struct
  type t =
    | Direct of Location.t
    | Ambiguous of Candidate.t list
    | Unavailable of string
  [@@deriving compare, equal, sexp_of]
end

module Provider = struct
  type 'selection t =
    { offer : project:Project_id.t -> selection:'selection -> Action.t list
    ; resolve :
        project:Project_id.t
        -> selection:'selection
        -> action_id:string
        -> Resolution.t Deferred.t
    }

  let create ~offer ~resolve = { offer; resolve }
end

module Offer = struct
  type t =
    { project : Project_id.t
    ; action : Action.t
    ; resolve : unit -> Resolution.t Deferred.t
    }

  let action t = t.action
end

module Request = struct
  type t =
    { offer : Offer.t
    ; token : unit ref
    }

  let project t = t.offer.project
  let action t = t.offer.action
end

module Response = struct
  type t =
    { request : Request.t
    ; resolution : Resolution.t
    }

  let request t = t.request
  let resolution t = t.resolution
  let matches t (request : Request.t) = phys_equal t.request.token request.token
end

let offer (provider : _ Provider.t) ~project ~selection =
  List.map (provider.offer ~project ~selection) ~f:(fun action ->
    { Offer.project
    ; action
    ; resolve = (fun () -> provider.resolve ~project ~selection ~action_id:action.id)
    })
;;

let capture offer = { Request.offer; token = ref () }

let resolve (request : Request.t) =
  let lookup = request.offer.resolve () in
  let respond resolution = { Response.request; resolution } in
  match Deferred.peek lookup with
  | Some resolution -> Deferred.return (respond resolution)
  | None -> Deferred.map lookup ~f:respond
;;
