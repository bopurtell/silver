(* The Dune rule passes only the editable source files, not Bazel's generated outputs or
   workspace symlinks. Embed bytes so the native binary is relocatable. *)
let () =
  print_endline "let files =";
  print_endline "  [";
  for i = 1 to Array.length Sys.argv - 1 do
    let path = Sys.argv.(i) in
    let contents = In_channel.with_open_bin path In_channel.input_all in
    Printf.printf "    %S, %S;\n" (Filename.basename path) contents
  done;
  print_endline "  ]"
;;
