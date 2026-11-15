open! Core

(* Keep the raw path out of terminal text. Only base64 enters OSC 52; details use a
   lossless OCaml string literal, including for control bytes and non-ASCII names. *)
let osc52 path =
  "\027]52;c;"
  ^ Cryptokit.transform_string (Cryptokit.Base64.encode_compact_pad ()) path
  ^ "\007"
;;

type t =
  { mutable path : string option
  ; mutable pending : (string * (string -> unit)) option
  }

let create () = { path = None; pending = None }
let details t = Option.map t.path ~f:(sprintf "%S")

let completed t result ~notice =
  match result with
  | Error _ -> ()
  | Ok path ->
    t.path <- Some path;
    t.pending <- Some (path, notice)
;;

let retry t ~notice = Option.iter t.path ~f:(fun path -> completed t (Ok path) ~notice)

(* Called by the input effect, after the export Deferred completes. The writer is
   Bonsai_term's registered output effect, never an independent stdout writer. *)
let flush t ~enabled ~write =
  let open Bonsai_term in
  match t.pending with
  | None -> Effect.Ignore
  | Some (path, notice) ->
    t.pending <- None;
    let finish message = Effect.of_thunk (fun () -> notice message) in
    if not enabled
    then finish "Export ready; clipboard unavailable (F8: path, F9: copy)"
    else
      Effect.bind
        (Effect.try_with (Effect.bind (Effect.return ()) ~f:(fun () -> write (osc52 path))))
        ~f:(function
          | Ok () -> finish "Export ready; path sent to clipboard (F8: path, F9: copy)"
          | Error _ -> finish "Export ready; clipboard unavailable (F8: path, F9: copy)")
;;

let%test_unit "OSC52 contains only base64 and preserves exact path bytes" =
  let path = "/tmp/a space/quote\";\\界\n\027]52;c;attack\007.vcd" in
  let sequence = osc52 path in
  let encoded = String.chop_prefix_exn sequence ~prefix:"\027]52;c;" in
  let encoded = String.chop_suffix_exn encoded ~suffix:"\007" in
  assert (not (String.exists encoded ~f:Char.is_whitespace));
  assert (not (String.exists encoded ~f:(fun c -> Char.to_int c < 32)));
  assert (
    String.equal
      (Cryptokit.transform_string (Cryptokit.Base64.decode ()) encoded)
      path);
  assert (String.equal (osc52 "/tmp/a.vcd") "\027]52;c;L3RtcC9hLnZjZA==\007")
;;

let%test_unit "only completed exports enqueue; unsupported terminals retain exact path" =
  let t = create () in
  let messages = ref [] in
  let notice message = messages := message :: !messages in
  let run effect = Bonsai_term.Effect.Expert.handle ~on_exn:raise effect in
  let writes = ref [] in
  let write text = Bonsai_term.Effect.of_thunk (fun () -> writes := text :: !writes) in
  completed t (Or_error.error_string "SHA256 mismatch") ~notice;
  run (flush t ~enabled:true ~write);
  assert (Option.is_none (details t));
  assert (List.is_empty !writes && List.is_empty !messages);
  let path = "/tmp/export with spaces/trace.vcd" in
  completed t (Ok path) ~notice;
  run (flush t ~enabled:false ~write);
  assert (List.is_empty !writes);
  assert (Option.equal String.equal (details t) (Some (sprintf "%S" path)));
  assert (String.is_substring (List.hd_exn !messages) ~substring:"unavailable");
  retry t ~notice;
  run (flush t ~enabled:true ~write);
  run (flush t ~enabled:true ~write);
  assert (List.equal String.equal !writes [ osc52 path ]);
  assert (String.is_substring (List.hd_exn !messages) ~substring:"sent to clipboard");
  completed t (Or_error.error_string "stale owner") ~notice;
  run (flush t ~enabled:true ~write);
  assert (List.length !writes = 1)
;;

let%test_unit "writer failures retain path and give fallback rather than claiming copy" =
  let t = create () in
  let message = ref "" in
  completed t (Ok "/tmp/trace.vcd") ~notice:(fun text -> message := text);
  Bonsai_term.Effect.Expert.handle ~on_exn:raise
    (flush t ~enabled:true ~write:(fun _ -> failwith "closed terminal"));
  assert (String.is_substring !message ~substring:"clipboard unavailable");
  assert (Option.is_some (details t))
;;
