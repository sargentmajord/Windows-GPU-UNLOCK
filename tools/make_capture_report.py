"""Turn one read-only diagnostic capture (DIAGnn.TXT) into the plain-text report that the host tests read.

The tests read three kinds of lines, so the report has all three:
  config_offset=0x<hex>  /  value=0x<hex>     (64 pairs: the target's 256-byte PCI configuration)
  config[<offset>]=<dword> <dword> <dword> <dword>   (16 rows of the same configuration)
  cold state: chip=... plm=... gfw=.../.../... WPR2_HI=... SS0=... SS1=...   and   memory=0x<hex>

Reads a text file and writes a text file. No GPU or firmware access. Usage:
  python make_capture_report.py DIAG02.TXT REPORT.TXT
"""
import re
import sys
from pathlib import Path

# Registers read by the diagnostic (offset -> meaning), see probe.c
OFFSETS = {0x000000: 'chip', 0x118128: 'gfw0', 0x118234: 'gfw1', 0x110100: 'gfw2', 0x1fa828: 'wpr2_hi',
           0x823804: 'plm', 0x82381c: 'ss0', 0x823820: 'ss1', 0x1183a4: 'memory'}


def parse(text):
    block = re.search(r'probe-target seg=.*?\ncfg256 status=0x0+\ncfg dwords=([0-9a-f ]+)', text, re.S)
    if not block:
        raise ValueError('no complete target configuration in the capture')
    cfg = [int(x, 16) for x in block.group(1).split()]
    if len(cfg) != 64:
        raise ValueError('configuration is not 64 dwords')
    regs = {}
    for m in re.finditer(r'^mmio off=0x([0-9a-f]+) status=0x0+ value=0x([0-9a-f]+)$', text, re.M):
        off = int(m.group(1), 16)
        if off in OFFSETS:
            regs.setdefault(OFFSETS[off], int(m.group(2), 16))
    missing = sorted(set(OFFSETS.values()) - set(regs))
    if missing:
        raise ValueError('registers missing from the capture: ' + ', '.join(missing))
    if 'capture-complete=1' not in text or 'diagnostic-result status=0x0000000000000000' not in text:
        raise ValueError('capture is not a complete successful diagnostic')
    return cfg, regs


def h(v):
    """C printf %#x: zero prints as 0, everything else as 0x..."""
    return '0' if v == 0 else '0x%x' % v


def render(cfg, regs):
    out = []
    for i, v in enumerate(cfg):
        out.append('config_offset=0x%x' % (i * 4))
        out.append('value=0x%x' % v)
    for row in range(16):
        out.append('config[%x]=%08x %08x %08x %08x' % (row * 16, *cfg[row * 4:row * 4 + 4]))
    out.append('cold state: chip=%s plm=%s gfw=%s/%s/%s WPR2_HI=%s SS0=%s SS1=%s' % tuple(h(regs[k]) for k in (
        'chip', 'plm', 'gfw0', 'gfw1', 'gfw2', 'wpr2_hi', 'ss0', 'ss1')))
    out.append('memory=%s' % h(regs['memory']))
    return '\n'.join(out) + '\n'


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    cfg, regs = parse(Path(argv[1]).read_text(encoding='utf-8'))
    Path(argv[2]).write_text(render(cfg, regs), encoding='utf-8', newline='\n')
    print('report written: %d config dwords, registers %s' % (len(cfg), ', '.join('%s=%#x' % kv for kv in regs.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
