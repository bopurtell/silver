#include "VmkCounter.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

struct Simulation {
    VerilatedContext context;
    VmkCounter dut;
    VerilatedVcdC trace;

    Simulation() : dut{configure()} {
        dut.trace(&trace, 99);
    }

    VerilatedContext* configure() {
        context.threads(1);
        context.traceEverOn(true);
        return &context;
    }

    void eval() {
        dut.eval();
        trace.dump(context.time());
        context.timeInc(5);
    }
};

extern "C" int check_counter(Simulation* sim, std::uint64_t seed);

// Clock the generated RTL once and return its actual output after the edge.
extern "C" std::uint8_t counter_cycle(Simulation* sim, std::uint8_t reset_n,
                                     std::uint8_t clear, std::uint8_t enable,
                                     std::uint8_t step) {
    auto& dut = sim->dut;
    dut.CLK = 0;
    dut.RST_N = reset_n;
    dut.step_clear = clear;
    dut.step_enable = enable;
    dut.EN_step = step;
    sim->eval();
    dut.CLK = 1;
    sim->eval();
    return dut.count;
}

int main(int argc, char** argv) {
    std::string path;
    std::uint64_t seed = 1;
    const bool test_mode = argc == 1 && std::getenv("TEST_TMPDIR");
    if (test_mode) {
        const char* outputs = std::getenv("TEST_UNDECLARED_OUTPUTS_DIR");
        path = std::string(outputs ? outputs : std::getenv("TEST_TMPDIR")) + "/counter.vcd";
    } else if ((argc == 2 || argc == 3) && argv[1][0] == '/') {
        path = argv[1];
        if (argc == 3) {
            if (argv[2][0] == '\0' || std::strspn(argv[2], "0123456789") != std::strlen(argv[2])) {
                std::fprintf(stderr, "SEED must be an unsigned decimal 64-bit integer\n");
                return 2;
            }
            errno = 0;
            seed = std::strtoull(argv[2], nullptr, 10);
            if (errno == ERANGE) {
                std::fprintf(stderr, "SEED is out of range for uint64\n");
                return 2;
            }
        }
    } else {
        std::fprintf(stderr, "usage: bazel run //:bench -- ABS_VCD_PATH [SEED]\n");
        return 2;
    }

    Simulation sim;
    sim.trace.open(path.c_str());
    if (!sim.trace.isOpen()) {
        std::fprintf(stderr, "could not open VCD: %s\n", path.c_str());
        return 2;
    }
    const int result = check_counter(&sim, seed);
    sim.dut.final();
    sim.trace.close();
    // A completed check is distinct from a tool failure. Let the provider
    // publish both outcomes; in Bazel test mode the checker sets the exit code.
    std::puts(result == 0 ? "RESULT Passed" : "RESULT Failed");
    return test_mode ? result : 0;
}
