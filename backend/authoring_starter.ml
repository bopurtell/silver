module U = Unix
open! Core
module File = Hardcaml_workbench_protocol.Authoring.File

let program = "hardcaml-asic-starter"
let max_output = 256 * 1024
let invalid reason = failwith ("Invalid starter descriptor: " ^ reason)

(* Run on the blocking authoring worker. Drain both pipes with a single deadline
   (including child exit after EOF); always close the pipes and reap the child. *)
let render ?(command = "render") ?(arguments = []) name =
  let with_fd fd f = Exn.protect ~f:(fun () -> f fd) ~finally:(fun () -> U.close fd) in
  let pipe f =
    let r, w = U.pipe ~cloexec:true () in
    let open_ = ref true in
    let close_writer () =
      if !open_
      then (
        open_ := false;
        U.close w)
    in
    with_fd r (fun r ->
      Exn.protect ~finally:close_writer ~f:(fun () -> f r w close_writer))
  in
  pipe (fun stdout out_w close_stdout ->
    pipe (fun stderr err_w close_stderr ->
      let pid =
        Exn.protect
          ~finally:(fun () ->
            close_stdout ();
            close_stderr ())
          ~f:(fun () ->
            with_fd
              (U.openfile "/dev/null" [ O_RDONLY; O_CLOEXEC ] 0)
              (fun stdin ->
                U.create_process
                  program
                  (Array.of_list ([ program; command; "--name"; name ] @ arguments))
                  stdin
                  out_w
                  err_w))
      in
      let reaped = ref false in
      let now () =
        (Or_error.ok_exn Core_unix.Clock.gettime) Monotonic
        |> Int63.to_float
        |> fun ns -> ns /. 1e9
      in
      let rec wait flags =
        try U.waitpid flags pid with
        | U.Unix_error (EINTR, _, _) -> wait flags
      in
      Exn.protect
        ~finally:(fun () ->
          if not !reaped
          then (
            (try U.kill pid Stdlib.Sys.sigkill with
             | U.Unix_error (ESRCH, _, _) -> ());
            ignore (wait [] : int * U.process_status)))
        ~f:(fun () ->
          let deadline = now () +. 10. in
          let remaining () =
            let s = deadline -. now () in
            if Float.(s <= 0.) then failwith "Starter render timed out";
            s
          in
          let out = Buffer.create 4096
          and err = Buffer.create 256 in
          let chunk = Bytes.create 4096 in
          let rec drain fds =
            if not (List.is_empty fds)
            then (
              let ready, _, _ = U.select fds [] [] (remaining ()) in
              let fds =
                List.fold ready ~init:fds ~f:(fun fds fd ->
                  let n = U.read fd chunk 0 (Bytes.length chunk) in
                  if n = 0
                  then List.filter fds ~f:(Fn.non (Poly.equal fd))
                  else (
                    let buf, limit =
                      if Poly.equal fd stdout then out, max_output else err, 4096
                    in
                    if Buffer.length buf + n > limit
                    then failwith "Starter output exceeds limit";
                    Buffer.add_subbytes buf chunk ~pos:0 ~len:n;
                    fds))
              in
              drain fds)
          in
          drain [ stdout; stderr ];
          let rec finish () =
            match wait [ WNOHANG ] with
            | 0, _ ->
              U.sleepf (Float.min 0.01 (remaining ()));
              finish ()
            | _, status ->
              reaped := true;
              (match status with
               | WEXITED 0 -> Buffer.contents out
               | _ -> failwithf "Starter render failed: %s" (Buffer.contents err) ())
          in
          finish ())))
;;

let parse text =
  if String.length text > max_output then invalid "too large";
  (* Reject excessive nesting before allocating the Yojson tree. *)
  let depth = ref 0
  and quoted = ref false
  and escaped = ref false in
  String.iter text ~f:(fun c ->
    if !quoted
    then (
      if !escaped
      then escaped := false
      else if Char.equal c '\\'
      then escaped := true
      else if Char.equal c '"'
      then quoted := false)
    else (
      match c with
      | '"' -> quoted := true
      | '{' | '[' ->
        Int.incr depth;
        if !depth > 3 then invalid "nesting"
      | '/' -> invalid "JSON comments are not permitted"
      | '}' | ']' ->
        Int.decr depth;
        if !depth < 0 then invalid "unbalanced descriptor"
      | _ -> ()));
  let fields keys = function
    | `Assoc pairs
      when List.equal
             String.equal
             (List.sort (List.map pairs ~f:fst) ~compare:String.compare)
             (List.sort keys ~compare:String.compare) ->
      fun key -> List.Assoc.find_exn pairs key ~equal:String.equal
    | _ -> invalid "unexpected, missing or duplicate fields"
  in
  let get =
    fields
      [ "schema_version"; "provider"; "version"; "files" ]
      (Yojson.Basic.from_string text)
  in
  if not (Poly.equal (get "schema_version") (`Int 1)) then invalid "schema_version";
  let label key =
    match get key with
    | `String s
      when String.length s <= 128
           && (not (String.is_empty (String.strip s)))
           && String.for_all s ~f:Char.is_print -> s
    | _ -> invalid key
  in
  let paths = String.Hash_set.create ()
  and dirs = String.Hash_set.create () in
  let file json =
    let get = fields [ "path"; "contents" ] json in
    match get "path", get "contents" with
    | `String path, `String contents ->
      let parts = String.split path ~on:'/' in
      if String.length path > 1024
         || List.length parts > 16
         || List.exists parts ~f:(fun p ->
           String.is_empty p
           || String.length p > 255
           || List.mem [ "."; ".."; ".git" ] p ~equal:String.Caseless.equal
           || not
                (String.for_all p ~f:(function
                  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
                  | _ -> false)))
      then invalid "unsafe file path";
      if Hash_set.mem paths path || Hash_set.mem dirs path then invalid "path conflict";
      Hash_set.add paths path;
      List.fold (List.drop_last_exn parts) ~init:"" ~f:(fun prefix part ->
        let prefix = if String.is_empty prefix then part else prefix ^ "/" ^ part in
        if Hash_set.mem paths prefix then invalid "path conflict";
        Hash_set.add dirs prefix;
        prefix)
      |> ignore;
      if String.contains contents '\000' || not (Stdlib.String.is_valid_utf_8 contents)
      then invalid "expected text file";
      { File.path; contents }
    | _ -> invalid "expected file path and contents"
  in
  let files =
    match get "files" with
    | `List (_ :: _ as xs) when List.length xs <= 128 -> List.map xs ~f:file
    | _ -> invalid "expected 1 to 128 files"
  in
  label "provider", label "version", files
;;
