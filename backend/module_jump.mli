open! Core
open! Async
open Silver_protocol

(** A module-owned jump hook. The backend correlates resolutions with invocations but does
    not choose a candidate, open an editor, or decide which request is current. *)

module Location : sig
  (** The same destination-independent value is used by all editors. [relative_path] is
      relative to [project]'s root. [line] and [column] are optional and one-based;
      [column] counts display cells, not bytes, code points, or UTF-16 units, and requires
      a [line]. [source_identity], when supplied, is opaque provenance for the resolved
      source (for example a retained artifact ID and digest); destinations must not
      silently treat retained evidence as the current working copy. The hook forwards this
      payload without accessing the filesystem; opening it requires destination-side path
      and provenance checks. *)
  type t =
    { project : Project_id.t
    ; relative_path : string
    ; line : int option
    ; column : int option
    ; source_identity : string option
    }
  [@@deriving compare, equal, sexp_of]
end

module Action : sig
  (** [id] is a stable provider-owned identifier, unique among actions for a selection;
      [label] is user-facing and is not used for dispatch. *)
  type t =
    { id : string
    ; label : string
    }
  [@@deriving compare, equal, sexp_of]
end

module Candidate : sig
  type t =
    { label : string
    ; location : Location.t
    }
  [@@deriving compare, equal, sexp_of]
end

module Resolution : sig
  type t =
    | Direct of Location.t
    | Ambiguous of Candidate.t list
    | Unavailable of string
  [@@deriving compare, equal, sexp_of]
end

module Provider : sig
  type 'selection t

  (** A module supplies callbacks over its own stable, immutable selection reference.
      Return [Deferred.return] for a known result; asynchronous lookups use the same
      contract. Resolvers must report expected lookup failures as [Unavailable]. *)
  val create
    :  offer:(project:Project_id.t -> selection:'selection -> Action.t list)
    -> resolve:
         (project:Project_id.t
          -> selection:'selection
          -> action_id:string
          -> Resolution.t Deferred.t)
    -> 'selection t
end

module Offer : sig
  type t

  val action : t -> Action.t
end

module Request : sig
  type t

  val project : t -> Project_id.t
  val action : t -> Action.t
end

module Response : sig
  type t

  val request : t -> Request.t
  val resolution : t -> Resolution.t

  (** True only for the exact invocation, even if two invocations use the same offer. *)
  val matches : t -> Request.t -> bool
end

(** Offers bind the provider and the selection that was presented; re-offering for a
    different selection does not mutate an earlier offer. *)
val offer
  :  'selection Provider.t
  -> project:Project_id.t
  -> selection:'selection
  -> Offer.t list

(** Capture a fresh invocation of an offer before starting its lookup. *)
val capture : Offer.t -> Request.t

(** An already-determined provider result produces an already-determined response. A
    response carries the request even when it completes later. Before acting, the frontend
    checks [Response.matches] against its current request, if any. A frontend can clear
    its current request when a selection change invalidates a pending jump. *)
val resolve : Request.t -> Response.t Deferred.t
