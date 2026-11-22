open! Core
open Async
open Hardcaml_workbench_protocol
module Share = Hardcaml_workbench_native_http.Editor_share
module Client = Hardcaml_workbench_native_http.Client

type binding =
  { client : Client.t
  ; instance : V1.Daemon_instance_id.t
  ; project : Project_id.t
  ; root : string
  }

let same_target a b =
  String.equal (Client.endpoint a.client) (Client.endpoint b.client)
  && V1.Daemon_instance_id.equal a.instance b.instance
  && Project_id.equal a.project b.project
  && String.equal a.root b.root
;;

let equal_binding a b = phys_equal a.client b.client && same_target a b

type t =
  { source : Share.source
  ; mutable active : bool
  ; mutable closed : bool
  ; mutable binding : binding option
  ; mutable generation : int
  ; mutable session_only : binding option
  ; mutable publication : Share.offer option
  ; mutable tail : unit Deferred.t
  ; mutable notice : string option
  }

let create source =
  { source
  ; active = false
  ; closed = false
  ; binding = None
  ; generation = 0
  ; session_only = None
  ; publication = None
  ; tail = Deferred.unit
  ; notice = None
  }
;;

let no_project = "No project binding is available to share."
let changed = "The project connection changed; reopen Share with Cobalt."

let enqueue t f =
  (* A new binding must not publish until the old handle (including a publish already in
     flight) has been withdrawn. All handle writes use this queue. *)
  let result = t.tail >>= fun () -> Monitor.try_with_or_error f >>| Or_error.join in
  t.tail <- Deferred.ignore_m result;
  result
;;

let withdraw t =
  match t.publication with
  | None -> return (Ok ())
  | Some offer ->
    t.publication <- None;
    Share.withdraw offer
;;

let validate t (binding : binding) =
  let%map validated =
    Share.validate
      ~source:t.source
      ~client:binding.client
      ~instance_id:binding.instance
      ~project_id:binding.project
      ~project_root:binding.root
      ()
  in
  Or_error.tag
    validated
    ~tag:"Cannot verify the current service as a same-user local connection"
;;

let publish t target ~current =
  let%bind result = Share.publish target in
  match result with
  | Error _ as error -> return error
  | Ok offer when current () ->
    t.publication <- Some offer;
    return (Ok ())
  | Ok offer ->
    let%map result = Share.withdraw offer in
    Result.bind result ~f:(fun () -> Or_error.error_string changed)
;;

let sync t binding =
  let binding = if t.active then binding else None in
  if not (Option.equal equal_binding t.binding binding)
  then (
    t.binding <- binding;
    t.generation <- t.generation + 1;
    t.notice <- None;
    let generation = t.generation in
    let current () = t.active && t.generation = generation in
    don't_wait_for
      (enqueue t (fun () ->
         let%bind.Deferred.Or_error () = withdraw t in
         match binding with
         | None -> return (Ok ())
         | Some binding when current () ->
           let remembered = Share.remembered ~project_root:binding.root () in
           (match remembered with
            | Error _ as error -> return error
            | Ok remembered ->
              let session_only = Option.exists t.session_only ~f:(same_target binding) in
              if not (remembered || session_only)
              then return (Ok ())
              else (
                let%bind.Deferred.Or_error target = validate t binding in
                if current () then publish t target ~current else return (Ok ())))
         | Some _ -> return (Ok ()))
       >>| function
       | Error e when current () -> t.notice <- Some (Error.to_string_hum e)
       | _ -> ()))
;;

let activate t binding =
  if not t.closed
  then (
    t.active <- true;
    sync t binding)
;;

let deactivate t =
  t.active <- false;
  sync t None;
  t.tail
;;

let close t =
  t.closed <- true;
  deactivate t
;;

let is_sharing t = Option.is_some t.publication

let check t ~current =
  enqueue t (fun () ->
    match t.binding with
    | None -> return (Or_error.error_string no_project)
    | Some binding when current () ->
      let%bind.Deferred.Or_error remembered =
        return (Share.remembered ~project_root:binding.root ())
      in
      let%map eligible = validate t binding >>| Or_error.map ~f:ignore in
      if current () then Ok (remembered, eligible) else Or_error.error_string changed
    | Some _ -> return (Or_error.error_string changed))
;;

let share t ~current ~remember =
  enqueue t (fun () ->
    match t.binding with
    | Some binding when current () ->
      let previously_shared = is_sharing t in
      let%bind.Deferred.Or_error target = validate t binding in
      if not (current ())
      then return (Or_error.error_string changed)
      else (
        let%bind.Deferred.Or_error () =
          if previously_shared then return (Ok ()) else publish t target ~current
        in
        let result =
          if not (current ())
          then Or_error.error_string changed
          else if remember
          then Share.set_remembered ~project_root:binding.root true
          else Ok ()
        in
        match result with
        | Ok () ->
          t.session_only <- (if remember then None else Some binding);
          t.notice <- None;
          return (Ok ())
        | Error _ when not previously_shared ->
          let%map withdrawn = withdraw t in
          Or_error.combine_errors_unit [ result; withdrawn ]
        | Error _ -> return result)
    | _ -> return (Or_error.error_string changed))
;;

let stop t ~current =
  enqueue t (fun () ->
    match t.binding with
    | Some binding when current () ->
      t.session_only <- None;
      t.notice <- None;
      let%map withdrawn = withdraw t in
      let forget = Share.set_remembered ~project_root:binding.root false in
      Or_error.combine_errors_unit [ withdrawn; forget ]
    | _ -> return (Or_error.error_string changed))
;;
