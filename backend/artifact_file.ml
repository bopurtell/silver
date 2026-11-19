open! Core

let require yes message = if not yes then failwith message
let chunk_bytes = 64 * 1024

(* The caller validates the path and descriptor target. Hash and retain the page in one
   pass over that same descriptor, never seeking back after verification. A sink may write
   to an unpublished temporary file; nothing is published before return. *)
let scan fd ~max_bytes ~offset ~limit ~sink =
  require (offset >= 0 && limit >= 0 && limit <= chunk_bytes) "Invalid artifact slice";
  let before = Core_unix.Ns_precision.fstat fd in
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
       let after = Core_unix.Ns_precision.fstat fd in
      require
        (count = size
         && Int64.equal before.st_size after.st_size
         && Poly.equal before.st_mtime after.st_mtime
         && Poly.equal before.st_ctime after.st_ctime)
        "Artifact changed while reading";
      let sha256 = Cryptokit.transform_string (Cryptokit.Hexa.encode ()) hash#result in
      size, sha256, Bytes.to_string page)
;;

(* Retain one bounded index, never file contents or an open descriptor. A cache hit
   is not a stat-only assertion: each returned block must match a SHA256 recorded
   during the same scan that established the whole-file digest. ctime participates
   in invalidation so restoring mtime after an out-of-page edit cannot hide it.
   Concurrent readers may replace this immutable index; that only causes misses. *)
let fingerprint (s : Core_unix.Ns_precision.stats) =
  s.st_dev, s.st_ino, s.st_size, s.st_mtime, s.st_ctime
;;

type index =
  { fingerprint : int * int * int64 * Time_ns.t * Time_ns.t
  ; size : int
  ; sha256 : string
  ; blocks : string
  }

let cached_index : index option Atomic.t = Atomic.make None
let max_indexed_bytes = 64 * 1024 * 1024

let page fd ~max_bytes ~offset ~limit =
  require (offset >= 0 && limit >= 0 && limit <= chunk_bytes) "Invalid artifact slice";
  let before = Core_unix.Ns_precision.fstat fd in
  require (Poly.equal before.st_kind S_REG) "Artifact is not a regular file";
  require
    Int64.(before.st_size >= 0L && before.st_size <= of_int max_bytes)
    "Artifact exceeds byte limit";
  let key = fingerprint before in
  match Atomic.get cached_index with
  | Some index when Poly.equal key index.fingerprint ->
    let length = if offset > index.size then 0 else Int.min limit (index.size - offset) in
    let page = Bytes.create length in
    let buffer = Bytes.create chunk_bytes in
    if length > 0
    then (
      let first = offset / chunk_bytes in
      let last = (offset + length - 1) / chunk_bytes in
      ignore
        (Core_unix.lseek fd (Int64.of_int (first * chunk_bytes)) ~mode:SEEK_SET : int64);
      for block = first to last do
        let start = block * chunk_bytes in
        let size = Int.min chunk_bytes (index.size - start) in
        let rec read pos =
          if pos < size
          then (
            let n = Core_unix.read fd ~buf:buffer ~pos ~len:(size - pos) in
            require (n > 0) "Artifact shrank while reading";
            read (pos + n))
        in
        read 0;
        let hash = Cryptokit.Hash.sha256 () in
        let digest =
          Exn.protect
            ~finally:(fun () -> hash#wipe)
            ~f:(fun () ->
              hash#add_substring buffer 0 size;
              hash#result)
        in
        require
          (String.equal digest (String.sub index.blocks ~pos:(block * 32) ~len:32))
          "Artifact block changed";
        let lo = Int.max offset start in
        let hi = Int.min (offset + length) (start + size) in
        Bytes.blit ~src:buffer ~src_pos:(lo - start) ~dst:page ~dst_pos:(lo - offset) ~len:(hi - lo)
      done);
    let after = Core_unix.Ns_precision.fstat fd in
    require
      (Poly.equal after.st_kind S_REG && Poly.equal key (fingerprint after))
      "Artifact changed while reading";
    index.size, index.sha256, Bytes.to_string page
  | _ when Int64.(before.st_size > of_int max_indexed_bytes) ->
    scan fd ~max_bytes ~offset ~limit ~sink:(fun _ _ -> ())
  | _ ->
    let hashes = ref [] in
    let hash = ref (Cryptokit.Hash.sha256 ()) in
    let used = ref 0 in
    let finish_block () =
      hashes := (!hash)#result :: !hashes;
      (!hash)#wipe;
      hash := Cryptokit.Hash.sha256 ();
      used := 0
    in
    Exn.protect
      ~finally:(fun () -> (!hash)#wipe)
      ~f:(fun () ->
        let size, sha256, page =
          scan fd ~max_bytes ~offset ~limit ~sink:(fun bytes len ->
            (* read(2) can return short blocks; index boundaries must still be
               absolute multiples of chunk_bytes, independent of syscall sizes. *)
            let rec add pos =
              if pos < len
              then (
                let n = Int.min (len - pos) (chunk_bytes - !used) in
                (!hash)#add_substring bytes pos n;
                used := !used + n;
                if !used = chunk_bytes then finish_block ();
                add (pos + n))
            in
            add 0)
        in
        if !used > 0 then finish_block ();
        require
          (Poly.equal key (fingerprint (Core_unix.Ns_precision.fstat fd)))
          "Artifact changed before indexing";
        Atomic.set cached_index
          (Some { fingerprint = key; size; sha256; blocks = String.concat (List.rev !hashes) });
        size, sha256, page)
;;
