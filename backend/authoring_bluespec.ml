open! Core
open Silver_protocol.Authoring

let provider = "silver-bluespec-classic"
let version = "1"
let package_name = String.capitalize
let filename name = package_name name ^ ".bs"

let valid_name name =
  String.length name >= 1
  && String.length name <= 64
  && Char.is_lowercase name.[0]
  && String.for_all name ~f:(fun c ->
    Char.is_lowercase c || Char.is_digit c || Char.equal c '_')
  && not (String.equal name "prelude")
;;

let build_file =
  {|# Reusable Classic Bluespec sources. Add this label to a consumer's srcs.
filegroup(
    name = "sources",
    srcs = glob(["*.bs"], allow_empty = False),
    visibility = ["//visibility:public"],
)
|}
;;

let package ~sample name =
  let name = package_name name in
  sprintf
    {|package %s (%s(..), mk%s) where

interface %s =
  result :: Bit 8

mk%s :: Module %s
mk%s = module
%s|}
    name
    name
    name
    name
    name
    name
    name
    (if sample
     then
       {|  -- A small example: increments every cycle, wrapping modulo 256.
  value :: Reg (Bit 8) <- mkReg 0
  rules
    "increment": when True ==> value := value + 1
  interface
    result = value
|}
     else
       {|  -- Replace the constant with the behavior of your module.
  interface
    result = 0
|})
;;

let file ~sample parts name =
  { File.path = String.concat ~sep:"/" (parts @ [ filename name ])
  ; contents = package ~sample name
  }
;;

let library ~sample name =
  let parts = [ "ip"; name ] in
  [ file ~sample parts name
  ; { File.path = String.concat ~sep:"/" (parts @ [ "BUILD.bazel" ])
    ; contents = build_file
    }
  ]
;;
