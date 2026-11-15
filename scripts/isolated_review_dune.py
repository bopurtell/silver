#!/usr/bin/env python3
"""Private launcher PATH shim: preserve Dune argv except force single-job builds.

WB_REVIEW_REAL_DUNE is captured before this shim is put on PATH. Never install
this wrapper globally. Arguments following `--` belong to the executed program.
"""
import os
import sys


def single_job(argv):
    if not argv or argv[0] not in {
        'build', 'exec', 'test', 'runtest', 'install', 'uninstall', 'utop', 'top',
    }:
        return argv
    before, separator, after = [], [], []
    if '--' in argv:
        index = argv.index('--')
        argv, after, separator = argv[:index], argv[index + 1:], ['--']
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg in ('-j', '--jobs'):
            index += 2
            continue
        if arg.startswith('--jobs=') or (arg.startswith('-j') and len(arg) > 2):
            index += 1
            continue
        before.append(arg)
        index += 1
    return [argv[0], '-j', '1', *before, *separator, *after]


def main():
    executable = os.environ['WB_REVIEW_REAL_DUNE']
    os.execve(executable, [executable, *single_job(sys.argv[1:])], os.environ)


if __name__ == '__main__':
    main()
