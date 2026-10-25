"""Reject ambiguous production build selection before creating artifacts."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLANG = sys.argv[1]
BASE = [CLANG, '-std=c11', '-fsyntax-only', '-x', 'c', '-',
        '-I../../deps/edk2/MdePkg/Include', '-I../../deps/edk2/MdePkg/Include/X64']
EXP = '-DGU_EXPERIMENTAL_UNLOCK'
ORIGINAL = '-DGU_STOCK_PROFILE_ORIGINAL_03100062'
OBSERVED = '-DGU_STOCK_PROFILE_OBSERVED_03000062'
LATCHED = '-DGU_ENTRY_LATCHED_SS1_PRESERVE'
FULL = '-DGU_ENTRY_LATCHED_SS1_FULL'
CASES = [([], True), ([EXP, ORIGINAL], True), ([EXP, OBSERVED], True),
         ([EXP, LATCHED], True), ([LATCHED], False),
         ([EXP, FULL], True), ([FULL], False),
         ([EXP, LATCHED, FULL], False),
         ([EXP, LATCHED, ORIGINAL], False), ([EXP, LATCHED, OBSERVED], False),
         ([EXP, LATCHED, ORIGINAL, OBSERVED], False),
         ([EXP], False), ([EXP, ORIGINAL, OBSERVED], False),
         ([ORIGINAL], False), ([OBSERVED], False),
         ([EXP, '-DGU_STOCK_PROFILE_UNKNOWN'], False),
         ([EXP, ORIGINAL, '-DGU_STOCK_PROFILE_SS0=0x03000062U'], False),
         ([EXP, OBSERVED, '-DGU_STOCK_PROFILE_NAME="original03100062"'], False),
         (['-ffreestanding', '-DGU_HOST_WRITE_TEST'], False)]
for defines, expected in CASES:
    result = subprocess.run(BASE + defines, cwd=ROOT, input='#include "port.h"\n',
                            text=True, capture_output=True)
    assert (result.returncode == 0) == expected, (defines, result.stderr)

parameter_rejections = 0
for script in ('build.ps1', 'test-all.ps1'):
    for args in (['-ExperimentalUnlock'],
                 ['-ExperimentalUnlock', '-StockProfile', 'unknown'],
                 ['-StockProfile', 'original03100062'],
                  ['-StockProfile', 'observed03000062'],
                  ['-StockProfile', 'entryLatchedSs1Preserve'],
                  ['-StockProfile', 'entryLatchedSs1Full'],
                 ['-ExperimentalUnlock', '-StockProfile', '']):
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy',
                                 'Bypass', '-File', str(ROOT / script)] + args,
                                cwd=ROOT, text=True, capture_output=True)
        assert result.returncode != 0, (script, args, result.stdout, result.stderr)
        parameter_rejections += 1
print(f'PASS {len(CASES)} compile-time selector cases + {parameter_rejections} build/test parameter rejections')
