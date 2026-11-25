open! Core
open! Async
open Silver_protocol

type source =
  | Embedded of { started_endpoint : string }
  | Attached

type target
type offer

(** Check the active, already-open binding without spawning or opening a service. Pass
    [Embedded] only with the endpoint returned by the frontend's actual standalone server
    startup, never the endpoint supplied to [--connect]. [Attached] checks the local
    daemon record, its lifetime lock and a fresh matching hello. [runtime] defaults to
    [Runtime.paths ()]. *)
val validate
  :  ?runtime:Runtime.paths
  -> source:source
  -> client:Client.t
  -> instance_id:V1.Daemon_instance_id.t
  -> project_id:Project_id.t
  -> project_root:string
  -> unit
  -> target Deferred.Or_error.t

(** Revalidate and create a new publication. The frontend owns this handle and must
    withdraw it on stop, binding change, or exit. Serialize transitions; if a binding
    changes while publishing, withdraw the returned handle immediately. *)
val publish : target -> offer Deferred.Or_error.t

val offer_id : offer -> string

(** Idempotently withdraw just this publication; does not touch the service or remove a
    replacement record. Attempts to unlink the published inode before releasing its lock.
    If unlinking fails, returns the error and still deactivates the offer: any leftover
    record is unlocked and stale. *)
val withdraw : offer -> unit Deferred.Or_error.t

(** Local-user settings only. Keys are canonical roots; unset is false. [config_home]
    overrides [XDG_CONFIG_HOME] for isolated callers/tests. *)
val remembered : ?config_home:string -> project_root:string -> unit -> bool Or_error.t

val set_remembered : ?config_home:string -> project_root:string -> bool -> unit Or_error.t
