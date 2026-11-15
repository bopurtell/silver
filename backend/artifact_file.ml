open! Core

let require yes message = if not yes then failwith message
let chunk_bytes = 64 * 1024

(* The caller validates the path and descriptor target. Hash and retain the page in one
   pass over that same descriptor, never seeking back after verification. A sink may write
   to an unpublished temporary file; nothing is published before return. *)
let scan fd ~max_bytes ~offset ~limit ~sink =
  require (offset >= 0 && limit >= 0 && limit <= chunk_bytes) "Invalid artifact slice";
  let before = Core_unix.fstat fd in
  require (Poly.equal before.st_kind S_REG) "Artifact is not a regular file";
  require
    Int64.(before.st_size >= 0L && before.st_size <= of_int max_bytes)
    "Artifact exceeds byte limit";
  let size = Int64.to_int_exn before.st_size in
  let page = Bytes.create (if offset > size then 0 else Int.min limit (size - offset)) in
  let buffer = Bytes.create chunk_bytes in
  let hash = Cryptokit.Hash.sha256 () in
  Exn.protect
    ~finally:(fun () -> hash#wipe)
    ~f:(fun () ->
      let rec loop pos =
        (* One extra byte detects growth, including growth at the exact cap. *)
        let n =
          Core_unix.read fd ~buf:buffer ~pos:0 ~len:(Int.min chunk_bytes (size - pos + 1))
        in
        require (pos + n <= size) "Artifact grew while reading";
        if n = 0
        then pos
        else (
          hash#add_substring buffer 0 n;
          sink buffer n;
          let start = Int.max pos offset in
          let stop = Int.min (pos + n) (offset + Bytes.length page) in
          if stop > start
          then
            Bytes.blit
              ~src:buffer
              ~src_pos:(start - pos)
              ~dst:page
              ~dst_pos:(start - offset)
              ~len:(stop - start);
          loop (pos + n))
      in
      let count = loop 0 in
      let after = Core_unix.fstat fd in
      require
        (count = size
         && Int64.equal before.st_size after.st_size
         && Poly.equal before.st_mtime after.st_mtime
         && Poly.equal before.st_ctime after.st_ctime)
        "Artifact changed while reading";
      let sha256 = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) hash#result in
      size, sha256, Bytes.to_string page)
;;

let page fd ~max_bytes ~offset ~limit =
  scan fd ~max_bytes ~offset ~limit ~sink:(fun _ _ -> ())
;;
