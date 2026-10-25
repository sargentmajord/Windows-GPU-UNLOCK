"""Turn a real successful diagnostic into an ignored host replay fixture.

No firmware or GPU access. Actual addresses are replaced by ordinal handles.
The source log stays private/local; it is not copied into tracked source.
"""
import hashlib
import re
import sys
import uuid
from pathlib import Path

source = Path(sys.argv[1])
single = '--single-rtx' in sys.argv[2:]
raw = source.read_bytes()
text = raw.decode().replace('\r\n', '\n')
if 'capture-complete=1\n' not in text or 'diagnostic-result status=0x0000000000000000' not in text:
    raise ValueError('Need a successful complete diagnostic')
blocks = {m[1]: m[2] for m in re.finditer(
    r'^handle id=(0x[0-9a-f]+)\n(.*?)(?=^handle id=|^capture-complete=|\Z)', text, re.M | re.S)}
indices = {h: i + 1 for i, h in enumerate(blocks)}
edges = []
for handle, block in blocks.items():
    protocol = None
    for line in block.splitlines():
        if line.startswith('protocol guid='):
            protocol = uuid.UUID(line.removeprefix('protocol guid='))
        match = re.fullmatch(r'open agent=(0x[0-9a-f]+) controller=(0x[0-9a-f]+) attributes=(0x[0-9a-f]+) count=(0x[0-9a-f]+)', line)
        if match and int(match[3], 16) not in (1, 2, 4):
            if protocol is None or match[1] not in indices or match[2] not in indices:
                raise ValueError('Unresolved active graph reference')
            edges.append((indices[handle], indices[match[1]], indices[match[2]], protocol, int(match[3], 16), int(match[4], 16)))
def one(predicate):
    values = [h for h, block in blocks.items() if predicate(block)]
    if len(values) != 1:
        raise ValueError('Expected exactly one role')
    return indices[values[0]]
def option(name, default=None):
    """--name VALUE from argv; the defaults are this machine's values."""
    argv = sys.argv[2:]
    return argv[argv.index(name) + 1] if name in argv else default
no_edid = '--with-edid' not in sys.argv[2:]   # this firmware binds no EDID/mouse driver
rtx_id = option('--rtx-id', '254410de')        # RTX 3060: PCI dword 0 (device<<16|vendor), hex
other_id = option('--other-id', '2f0410de')    # RTX 5070 (console adapter): PCI dword 0, hex
# The two GOP handles are picked by the PCI node of their device path:
# Pci(dev1,fn0) = RTX 3060, Pci(dev1,fn1) = RTX 5070.
rtx_path_node = option('--rtx-path-node', '010106000001')
other_path_node = option('--other-path-node', '010106000101')
def gop_by(node, framebuffer):
    if node:
        return lambda b: 'protocol guid=9042a9de-23dc-4a38-96fb-7aded080516a' in b and f'path-node raw={node}' in b
    return lambda b: f'gop framebuffer={framebuffer}' in b
roles = {
    'RtxPci': one(lambda b: f'pci config-dwords={rtx_id}' in b),
    'OtherPci': one(lambda b: f'pci config-dwords={other_id}' in b),
    'Rtx': one(gop_by(rtx_path_node, '0x000000fcc0000000')),
    'Other': 0 if single else one(gop_by(other_path_node, '0x000000fce0000000')),
}
if single:
    child_records = [e for e in edges if e[0] == roles['RtxPci'] and str(e[3]) == '09576e91-6d3f-11d2-8e39-00a0c969723b' and e[4] == 8 and e[2] != roles['Rtx']]
    if len(child_records) != 1:
        raise ValueError('Expected one additional RTX EDID-only child')
    roles['EdidChild'] = child_records[0][2]
for role, protocol, controller in [
    ('OutAgent', '387477c2-69c7-11d2-8e39-00a0c969723b', roles['Rtx']),
    ('GfxAgent', '9042a9de-23dc-4a38-96fb-7aded080516a', roles['Rtx']),
    ('NvAgent', '4cf5b200-68b8-4ca5-9eec-b23e3f50029a', roles['RtxPci']),
    ('EdidAgent', '1c0c34f6-d380-41fa-a049-8ad06c1a66aa', roles['Rtx']),
]:
    if no_edid and role == 'EdidAgent':
        continue   # this firmware has no EDID/mouse driver bound to the display handles
    records = [e for e in edges if e[0] == controller and str(e[3]) == protocol and e[4] == 16]
    if len(records) != 1:
        raise ValueError('Expected a unique consumer')
    roles[role] = records[0][1]
    block = blocks[next(h for h, i in indices.items() if i == roles[role])]
    roles[role.removesuffix('Agent') + 'Image'] = indices[re.search(r'driver image=(0x[0-9a-f]+)', block)[1]]
console = re.search(r'console out=(0x[0-9a-f]+) error=(0x[0-9a-f]+) input=(0x[0-9a-f]+)', text)
for role, value in zip(['Console', 'Error', 'Input'], console.groups()):
    roles[role] = indices[value]
lines = [f'/* Local diagnostic sha256 {hashlib.sha256(raw).hexdigest()} */', f'#define FX_HANDLES {len(blocks)}']
for role, value in roles.items():
    lines.append(f'#define FX_{role} ((EFI_HANDLE){value})')
lines.append('static const EDGE FixtureEdges[]={')
for h, a, c, g, attrs, count in edges:
    data = g.bytes
    guid = f'{{0x{g.time_low:x},0x{g.time_mid:x},0x{g.time_hi_version:x},{{' + ','.join(f'0x{x:x}' for x in data[8:]) + '}}'
    lines.append(f'{{(EFI_HANDLE){h},(EFI_HANDLE){a},(EFI_HANDLE){c},{guid},{attrs},{count}}},')
lines.append('};')
for role in ['Rtx', 'Other']:
    block = blocks[next(h for h, i in indices.items() if i == roles[role + 'Pci'])]
    cfg = re.search(r'pci config-dwords=([^\n]+)', block)[1].split()
    if len(cfg) != 16:
        raise ValueError('Incomplete PCI snapshot')
    lines.append('static const UINT32 Fixture' + role + 'Config[16]={' + ','.join('0x' + x for x in cfg) + '};')
target = Path(__file__).parent / ('build/r2/replay-fixture.h' if single else 'build/console/replay-fixture.h')
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text('\n'.join(lines) + '\n')
print(f'Local replay fixture: {len(blocks)} handles, {len(edges)} active ownership records; ordinal addresses only')
