"""Exact simulation suite IDs used by current and retained example captures."""

FIFO_SUITE = 'controlled-fifo'
MEMORY_SUITE = 'memory-workloads'
RETAINED_MEMORY_SUITE = 'pt8-memory-workloads'


def captured_suite_ids(manifest):
    commands = manifest['provider_commands']
    for memory in (MEMORY_SUITE, RETAINED_MEMORY_SUITE):
        if set(commands) == {FIFO_SUITE, memory}:
            # The provider emits FIFO first, independent of JSON key order.
            return [FIFO_SUITE, memory]
    raise AssertionError('expected FIFO and exactly one known memory suite')


def inspection_case(suite):
    # Treat both generations as memory workloads without rewriting the suite
    # ID used to reopen the original attempt.
    return {
        FIFO_SUITE: 'seeded',
        MEMORY_SUITE: 'exact256',
        RETAINED_MEMORY_SUITE: 'exact256',
    }[suite]
