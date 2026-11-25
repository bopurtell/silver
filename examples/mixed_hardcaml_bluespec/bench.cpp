#include "Vmixed_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: mixed_bench.exe VCD_PATH\n");
        return 2;
    }

    VerilatedContext context;
    context.threads(1);
    context.traceEverOn(true);
    Vmixed_top dut{&context};
    VerilatedVcdC trace;
    dut.trace(&trace, 99);
    trace.open(argv[1]);
    if (!trace.isOpen()) {
        std::fprintf(stderr, "could not open waveform %s\n", argv[1]);
        return 2;
    }

    const auto tick = [&](bool high) {
        dut.clock = high;
        dut.eval();
        trace.dump(context.time());
        context.timeInc(5);
    };

    unsigned cycle = 0;
    std::uint8_t count = 0;
    const auto check = [&](bool reset_n, bool enable, bool clear) {
        dut.reset_n = reset_n;
        dut.enable = enable;
        dut.clear = clear;
        const auto expected_sample = reset_n ? count : 0;
        if (!reset_n || (enable && clear)) {
            count = 0;
        } else if (enable) {
            ++count;
        }
        tick(false);
        tick(true);
        ++cycle;
        if (dut.ip_count == count && dut.sampled_count == expected_sample) {
            return true;
        }
        std::fprintf(stderr,
                     "cycle %u: expected ip_count=%d sampled_count=%d; got %d and %d\n",
                     cycle, count, expected_sample, dut.ip_count, dut.sampled_count);
        return false;
    };

    const bool passed = [&] {
        if (!check(false, true, false)) return false;  // reset wins over increment
        for (int i = 0; i < 257; ++i) {                // increment and wrap
            if (!check(true, true, false)) return false;
        }
        return check(true, false, false)                // hold
            && check(true, false, true)                 // disabled clear holds
            && check(true, true, true)                  // enabled clear
            && check(true, true, false)                 // nonzero before second reset
            && check(false, true, false)
            && check(true, false, false);
    }();
    dut.final();
    trace.close();
    if (!passed) return 1;
    std::printf("PASS: mixed top checked %u cycles\n", cycle);
    return 0;
}
