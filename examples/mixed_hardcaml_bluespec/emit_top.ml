open Hardcaml
open Signal

let () =
  let clock = input "clock" 1 in
  let reset_n = input "reset_n" 1 in
  let enable = input "enable" 1 in
  let clear = input "clear" 1 in
  let ip =
    Instantiation.create
      ()
      ~name:"mkCounterIp"
      ~instance:"u_counter_ip"
      ~inputs:[ "CLK", clock; "RST_N", reset_n; "EN_step", enable; "step_clear", clear ]
      ~outputs:[ "count", 8 ]
  in
  let count = Instantiation.output ip "count" in
  let sampled = reg (Reg_spec.create ~clock ~clear:(~:reset_n) ()) count in
  Circuit.create_exn
    ~name:"mixed_top"
    [ output "ip_count" count; output "sampled_count" sampled ]
  |> Rtl.print Verilog
;;
