use std::ffi::c_void;

extern "C" {
    fn counter_cycle(sim: *mut c_void, reset_n: u8, clear: u8, enable: u8, step: u8) -> u8;
}

#[no_mangle]
extern "C" fn check_counter(sim: *mut c_void, seed: u64) -> i32 {
    let mut expected = 0u8;
    let mut cycle = 0;
    let mut check = |reset_n: bool, clear: bool, enable: bool, step: bool| {
        if !reset_n || (step && clear) {
            expected = 0;
        } else if step && enable {
            expected = expected.wrapping_add(1);
        }
        // `sim` is the live Verilator model owned by bench.cpp.
        let actual = unsafe {
            counter_cycle(sim, reset_n.into(), clear.into(), enable.into(), step.into())
        };
        cycle += 1;
        if actual != expected {
            eprintln!(
                "FAIL seed={seed} cycle={cycle} reset_n={reset_n} clear={clear} \
                 enable={enable} step={step}: expected {expected}, got {actual}"
            );
            return false;
        }
        true
    };

    if !check(false, false, false, false) {
        return 1;
    }
    // Directed coverage: force wraparound even if the random stream never wraps.
    for _ in 0..=256 {
        if !check(true, false, true, true) {
            return 1;
        }
    }
    for (reset_n, clear, enable, step) in [
        (true, false, false, true),  // disabled increment holds
        (true, true, true, false),  // no method call holds
        (true, true, true, true),   // clear wins over increment
        (true, false, true, true),  // increment again before reset
        (false, false, true, true), // reset wins over increment
    ] {
        if !check(reset_n, clear, enable, step) {
            return 1;
        }
    }

    // Dependency-free deterministic PRNG; all u64 seeds, including zero, work.
    let mut random = seed;
    for _ in 0..256 {
        random = random
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        if !check(
            true,
            random >> 60 == 0,
            random & (1 << 59) != 0,
            random & (1 << 58) != 0,
        ) {
            return 1;
        }
    }

    println!("PASS seed={seed} cycles={cycle}");
    0
}
