open! Core
open Bonsai_term

type mode =
  | Auto
  | Osc52
  | Disabled

let mode_of_string = function
  | "auto" -> Auto
  | "osc52" -> Osc52
  | "disabled" -> Disabled
  | _ -> failwith "Editor clipboard must be auto, osc52, or disabled"
;;

let has_env getenv name =
  Option.exists (getenv name) ~f:(fun value -> not (String.is_empty value))
;;

(* The terminal host, not the project/daemon, owns the clipboard. In an SSH session even a
   forwarded DISPLAY is not evidence of a local desktop. *)
let native_commands ~getenv =
  let has = has_env getenv in
  if List.exists [ "SSH_CONNECTION"; "SSH_CLIENT"; "SSH_TTY" ] ~f:has
  then []
  else
    (if has "WAYLAND_DISPLAY" || has "WAYLAND_SOCKET"
     then [ "wl-copy", [ "--type"; "text/plain;charset=utf-8" ] ]
     else [])
    @
    if has "DISPLAY"
    then [ "xclip", [ "-selection"; "clipboard"; "-in"; "-silent" ] ]
    else []
;;

let native_copy ~prog ~args text =
  let open Async in
  let open Deferred.Let_syntax in
  let%bind result =
    Monitor.try_with (fun () ->
      match%bind Process.create ~prog ~args ~stdin:text () with
      | Error _ -> return (Error "unavailable")
      | Ok process ->
        let deadline = Clock.after (Time_float.Span.of_sec 2.) in
        let input_closed = Writer.close (Process.stdin process) ~force_close:deadline in
        don't_wait_for (Reader.drain (Process.stdout process));
        don't_wait_for (Reader.drain (Process.stderr process));
        let waited = Process.wait process in
        let%bind result =
          Deferred.choose
            [ Deferred.choice waited (function
                | Ok () -> Ok ()
                | Error _ -> Error "failed")
            ; Deferred.choice deadline (fun () -> Error "timed out")
            ]
        in
        let%bind () =
          if Deferred.is_determined waited
          then return ()
          else (
            Process.send_signal process Signal.kill;
            Deferred.ignore_m waited)
        in
        (* wl-copy and xclip normally fork a selection owner. Its lifetime must not hold
           up this effect even if it inherits a pipe. *)
        let%bind () =
          Deferred.all_unit
            [ input_closed
            ; Reader.close (Process.stdout process)
            ; Reader.close (Process.stderr process)
            ]
        in
        return result)
  in
  return (Result.map_error result ~f:(fun _ -> "failed") |> Result.join)
;;

type t =
  { queue : unit Async.Throttle.Sequencer.t
  ; mutable generation : int
  }

let create () =
  { queue = Async.Throttle.Sequencer.create ~continue_on_error:true (); generation = 0 }
;;

let copy t ~mode ~write ~notice text =
  let open Async in
  let open Deferred.Let_syntax in
  let rec native generation failures commands =
    if generation <> t.generation
    then return `Superseded
    else (
      match commands with
      | [] -> return (`Terminal (List.rev failures))
      | (prog, args) :: tail ->
        (match%bind native_copy ~prog ~args text with
         | Ok () -> return (`Native prog)
         | Error reason -> native generation ((prog ^ " " ^ reason) :: failures) tail))
  in
  let%bind.Effect generation, outcome =
    Effect.of_deferred_thunk (fun () ->
      t.generation <- t.generation + 1;
      let generation = t.generation in
      let%map outcome =
        Throttle.enqueue t.queue (fun () ->
          if generation <> t.generation
          then return `Superseded
          else (
            match mode with
            | Disabled -> return `Disabled
            | Osc52 -> return (`Terminal [])
            | Auto -> native generation [] (native_commands ~getenv:Sys.getenv)))
      in
      generation, outcome)
  in
  (* Serialize native helper delivery across all mounted projects and do not let a delayed
     fallback overwrite a newer yank. *)
  if generation <> t.generation
  then Effect.Ignore
  else (
    match outcome with
    | `Superseded -> Effect.Ignore
    | `Disabled -> notice "Clipboard disabled; internal yank retained"
    | `Native prog -> notice ("Copied to clipboard via " ^ prog)
    | `Terminal failures ->
      let detail =
        match failures with
        | [] -> ""
        | failures -> String.concat ~sep:"; " failures ^ "; "
      in
      if Option.exists (Sys.getenv "TERM") ~f:(String.equal "dumb")
      then notice (detail ^ "No clipboard transport; internal yank retained")
      else (
        let%bind.Effect result =
          Effect.try_with
            (Effect.bind (Effect.return ()) ~f:(fun () ->
               write (Terminal_presentation.Export_clipboard.osc52 text)))
        in
        if generation <> t.generation
        then Effect.Ignore
        else (
          match result with
          | Ok () -> notice (detail ^ "OSC 52 sent; terminal acceptance unknown")
          | Error _ -> notice (detail ^ "OSC 52 unavailable; internal yank retained"))))
;;

let%test_unit "native clipboard selects Wayland before X11, never SSH" =
  let commands vars =
    native_commands ~getenv:(fun name -> List.Assoc.find vars ~equal:String.equal name)
  in
  let names vars = List.map (commands vars) ~f:fst in
  assert (List.is_empty (names []));
  assert (List.equal String.equal (names [ "DISPLAY", ":0" ]) [ "xclip" ]);
  assert (
    List.equal
      String.equal
      (names [ "DISPLAY", ":0"; "WAYLAND_DISPLAY", "wayland-1" ])
      [ "wl-copy"; "xclip" ]);
  assert (
    List.is_empty
      (names
         [ "DISPLAY", "localhost:10"
         ; "WAYLAND_DISPLAY", "wayland-1"
         ; "SSH_TTY", "/dev/pts/1"
         ]))
;;
