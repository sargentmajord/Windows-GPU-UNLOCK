#!/usr/bin/env python3
# GPL-2.0-only. Part of Windows GPU UNLOCK.
"""Build a machine profile (the C header the boot programs are compiled against) from one read-only
diagnostic capture of the user's own PC.

No GPU or firmware access: it reads the capture text (DIAGnn.TXT) and the image dumps next to it
(IMGnn.BIN). Whenever something is missing, ambiguous or outside what the boot programs can check, it
REFUSES with a plain reason and writes no profile; there is no override. The boot programs then repeat
every one of these checks on the live machine, and the host replay tests run them against this same
capture before anything is ever staged.

Usage:
  python profile_gen.py --capture DIAG.TXT --images DIR --target-bus 1 --target-id 10de:2544 \
      --target-subsystem 1462:397d --console-bus 2 --console-id 10de:2f04 --console-subsystem 1043:89f2 \
      --target-name "NVIDIA GeForce RTX 3060" --console-name "NVIDIA GeForce RTX 5070" \
      --profile-name NAME --out profile.h --summary summary.json
Exit codes: 0 profile written; 2 refused (findings printed as JSON); 1 usage or internal error.
"""
import argparse
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

# Protocol and file identifiers (UEFI specification and the reference firmware).
GOP_GUID = '9042a9de-23dc-4a38-96fb-7aded080516a'
TEXT_OUT_GUID = '387477c2-69c7-11d2-8e39-00a0c969723b'
PCI_IO_GUID = '4cf5b200-68b8-4ca5-9eec-b23e3f50029a'
EDID_DISCOVERED_GUID = '1c0c34f6-d380-41fa-a049-8ad06c1a66aa'
BY_DRIVER = 0x10
BY_CHILD = 0x08
PASSIVE = (1, 2, 4)
EFI_BOOT_SERVICES_CODE = 3
ESP_NODE_PCI_ROOT_HID = bytes.fromhex('d041030a')   # PNP0A03

# Cold-state values every supported card shows once its firmware has finished (same constants the
# boot programs and the upstream module check).
COLD = {0x118128: 0x8b8f, 0x118234: 0x3ff, 0x110100: 0x10, 0x1fa828: 0, 0x823804: 0xffffff8f}
OFF_CHIP, OFF_MEMORY, OFF_SS0, OFF_SS1 = 0x000000, 0x1183a4, 0x82381c, 0x823820


class Finding:
    def __init__(self, code, message, fix=''):
        self.code, self.message, self.fix = code, message, fix

    def as_dict(self):
        return {'code': self.code, 'message': self.message, 'fix': self.fix}


class Refused(Exception):
    def __init__(self, findings):
        super().__init__('; '.join(f.message for f in findings))
        self.findings = findings


def refuse(code, message, fix=''):
    raise Refused([Finding(code, message, fix)])


def guid_text(raw16):
    """UEFI GUID (mixed-endian, as stored) -> canonical text."""
    d1, d2, d3 = struct.unpack('<IHH', raw16[:8])
    return '%08x-%04x-%04x-%s-%s' % (d1, d2, d3, raw16[8:10].hex(), raw16[10:16].hex())


def guid_initializer(raw16):
    d1, d2, d3 = struct.unpack('<IHH', raw16[:8])
    return '{0x%x,0x%x,0x%x,{%s}}' % (d1, d2, d3, ','.join('0x%02x' % b for b in raw16[8:16]))


# ---------------------------------------------------------------------------------------------
# Capture parsing
# ---------------------------------------------------------------------------------------------
class Handle:
    def __init__(self, hid):
        self.id = hid
        self.opens = {}            # protocol guid -> [(agent, controller, attributes, count)]
        self.driver = None         # (image, binding, version, stop)
        self.image = None          # dict(parent, device, base, size, code_type)
        self.image_path = []       # raw node bytes
        self.path = []             # device path raw node bytes
        self.pci_location = None   # (segment, bus, device, function)
        self.pci_config = None     # 16 dwords
        self.gop = False


class Capture:
    pass


HEX = r'0x([0-9a-f]+)'


def node_bytes(lines):
    return [bytes.fromhex(m) for m in lines]


def parse_capture(text):
    text = text.replace('\r\n', '\n')
    c = Capture()
    c.complete = 'capture-complete=1\n' in text
    c.result_ok = 'diagnostic-result status=0x0000000000000000' in text
    first = text.find('\nhandle id=')
    head = text[:first] if first >= 0 else text
    body = text[first + 1:] if first >= 0 else ''

    # --- target probe section ---
    c.probe_targets = [int(m, 16) for m in re.findall(r'^probe targets=([0-9a-f]+)$', head, re.M)]
    c.targets = []
    for m in re.finditer(r'^probe-target seg=%s bus=%s dev=%s fun=%s$' % (HEX, HEX, HEX, HEX), head, re.M):
        c.targets.append({'pos': m.start(), 'seg': int(m[1], 16), 'bus': int(m[2], 16), 'dev': int(m[3], 16), 'fun': int(m[4], 16)})
    cfgs = [(m.start(), [int(x, 16) for x in m[1].split()]) for m in re.finditer(r'^cfg dwords=([0-9a-f ]+)$', head, re.M)]
    c.cfg = None
    if len(c.targets) == 1:
        after = [d for p, d in cfgs if p > c.targets[0]['pos']]
        c.cfg = after[0] if after else None
    m = re.search(r'^probe-bar0 base=%s$' % HEX, head, re.M)
    c.bar0 = int(m[1], 16) if m else None
    c.mmio = {}
    for m in re.finditer(r'^mmio off=%s status=0x([0-9a-f]+) value=%s$' % (HEX, HEX), head, re.M):
        if int(m[2], 16) == 0:
            c.mmio[int(m[1], 16)] = int(m[3], 16)
    m = re.search(r'^prom sha256=([0-9a-f]{64})$', head, re.M)
    c.prom_sha = m[1] if m else None
    c.caps = [(int(a, 16), int(b, 16)) for a, b in re.findall(r'^cap off=%s\ncap id=%s$' % (HEX, HEX), head, re.M)]
    m = re.search(r'^subsystem=%s$' % HEX, head, re.M)
    c.subsystem = int(m[1], 16) if m else None
    m = re.search(r'^gops=([0-9a-f]+)$', head, re.M)
    c.gop_count = int(m[1], 16) if m else None
    m = re.search(r'^console out=%s error=%s input=%s$' % (HEX, HEX, HEX), text, re.M)
    c.console_handles = tuple(int(x, 16) for x in m.groups()) if m else None

    # --- driver bindings section: binding records and their image info/dump index ---
    c.bindings = {}
    cur = None
    in_bindings = False
    for line in head.split('\n'):
        if line.startswith('driver-bindings='):
            in_bindings = True
            continue
        if not in_bindings:
            continue
        m = re.fullmatch(r'binding handle=%s image=%s version=%s stop=%s' % (HEX, HEX, HEX, HEX), line)
        if m:
            cur = {'image': int(m[2], 16), 'version': int(m[3], 16), 'stop': int(m[4], 16), 'nodes': [], 'dump': None, 'base': None, 'size': None, 'code': None}
            c.bindings.setdefault(int(m[1], 16), cur)
            continue
        if cur is None:
            continue
        m = re.fullmatch(r'img base=%s' % HEX, line)
        if m: cur['base'] = int(m[1], 16); continue
        m = re.fullmatch(r'img size=%s' % HEX, line)
        if m: cur['size'] = int(m[1], 16); continue
        m = re.fullmatch(r'img code-type=%s' % HEX, line)
        if m: cur['code'] = int(m[1], 16); continue
        m = re.fullmatch(r'img-path-node raw=([0-9a-f]+)', line)
        if m: cur['nodes'].append(bytes.fromhex(m[1])); continue
        m = re.fullmatch(r'img dump index=()([0-9a-f]+)', line)
        if m: cur['dump'] = int(m[2], 16); continue

    # --- per-handle blocks ---
    c.handles = {}
    hcur = None
    proto = None
    for line in body.split('\n'):
        m = re.fullmatch(r'handle id=%s' % HEX, line)
        if m:
            hcur = Handle(int(m[1], 16)); c.handles[hcur.id] = hcur; proto = None
            continue
        if hcur is None or line.startswith('capture-complete') or line.startswith('diagnostic-result'):
            continue
        m = re.fullmatch(r'protocol guid=([0-9a-f-]{36})', line)
        if m:
            proto = m[1]; hcur.opens.setdefault(proto, []); continue
        m = re.fullmatch(r'open agent=%s controller=%s attributes=%s count=%s' % (HEX, HEX, HEX, HEX), line)
        if m and proto:
            hcur.opens[proto].append(tuple(int(x, 16) for x in m.groups())); continue
        m = re.fullmatch(r'driver image=%s binding=%s version=%s stop-address=%s' % (HEX, HEX, HEX, HEX), line)
        if m: hcur.driver = tuple(int(x, 16) for x in m.groups()); continue
        m = re.fullmatch(r'image parent=%s device=%s base=%s size=%s code-type=%s' % (HEX, HEX, HEX, HEX, HEX), line)
        if m:
            hcur.image = dict(zip(('parent', 'device', 'base', 'size', 'code_type'), (int(x, 16) for x in m.groups()))); continue
        m = re.fullmatch(r'image-file-path-node raw=([0-9a-f]+)', line)
        if m: hcur.image_path.append(bytes.fromhex(m[1])); continue
        m = re.fullmatch(r'path-node raw=([0-9a-f]+)', line)
        if m: hcur.path.append(bytes.fromhex(m[1])); continue
        m = re.fullmatch(r'pci location-status=%s segment=%s bus=%s device=%s function=%s' % (HEX, HEX, HEX, HEX, HEX), line)
        if m:
            if int(m[1], 16) == 0:
                hcur.pci_location = tuple(int(x, 16) for x in m.groups()[1:])
            continue
        m = re.fullmatch(r'pci config-dwords=([0-9a-f ]+)', line)
        if m: hcur.pci_config = [int(x, 16) for x in m[1].split()]; continue
        if line.startswith('gop framebuffer='): hcur.gop = True; continue
    return c


# ---------------------------------------------------------------------------------------------
# PE helpers (for the GOP driver's code hash)
# ---------------------------------------------------------------------------------------------
def pe_sections(img):
    if img[:2] != b'MZ':
        refuse('image-not-pe', 'The saved GOP driver image is not a PE file.')
    e = struct.unpack_from('<I', img, 0x3c)[0]
    if img[e:e + 4] != b'PE\0\0':
        refuse('image-not-pe', 'The saved GOP driver image is not a PE file.')
    nsec, = struct.unpack_from('<H', img, e + 6)
    optsize, = struct.unpack_from('<H', img, e + 20)
    opt = e + 24
    magic, = struct.unpack_from('<H', img, opt)
    dd = opt + (112 if magic == 0x20b else 96)
    reloc_rva, reloc_size = struct.unpack_from('<II', img, dd + 8 * 5)
    secs = []
    p = opt + optsize
    for i in range(nsec):
        name, vsize, va, rawsize, rawptr = struct.unpack_from('<8sIIII', img, p + 40 * i)
        flags, = struct.unpack_from('<I', img, p + 40 * i + 36)
        secs.append({'name': name.rstrip(b'\0').decode('latin1'), 'vsize': vsize, 'va': va, 'flags': flags})
    return secs, (reloc_rva, reloc_size)


def relocations_in(img, reloc, lo, hi):
    """Number of base relocations whose target lies in [lo, hi)."""
    rva, size = reloc
    n = 0
    if not rva or not size:
        return 0
    at, end = rva, rva + size
    while at + 8 <= end and at + 8 <= len(img):
        page, blk = struct.unpack_from('<II', img, at)
        if blk < 8:
            break
        for i in range((blk - 8) // 2):
            ent, = struct.unpack_from('<H', img, at + 8 + 2 * i)
            if ent >> 12 and lo <= page + (ent & 0xfff) < hi:
                n += 1
        at += blk
    return n


# ---------------------------------------------------------------------------------------------
# Device path helpers
# ---------------------------------------------------------------------------------------------
def classify_path(nodes):
    """Return (acpi_hid_bytes, [pci nodes (dev,fn)], adr_value) for the one supported shape
    PciRoot(0)/Pci(a,b)/Pci(0,0)/ADR/END, else None."""
    raw = b''.join(nodes)
    if len(raw) != 36 or len(nodes) != 5:
        return None
    n0, n1, n2, n3, n4 = nodes
    if not (n0[:4] == bytes([2, 1, 12, 0]) and n0[4:8] == ESP_NODE_PCI_ROOT_HID and n0[8:12] == bytes(4)):
        return None
    if not (n1[:4] == bytes([1, 1, 6, 0]) and n2[:4] == bytes([1, 1, 6, 0])):
        return None
    if not (n3[:4] == bytes([2, 3, 8, 0])) or n4 != bytes([0x7f, 0xff, 4, 0]):
        return None
    if n2[4:6] != bytes(2):
        return None
    return {'raw': raw, 'root_fn': n1[4], 'root_dev': n1[5], 'adr': struct.unpack('<I', n3[4:8])[0], 'prefix': raw[:24]}


def short_card_name(name, vram_mib=None):
    """'NVIDIA GeForce RTX 3060' -> ('RTX 3060', 'RTX3060', 'RTX 3060 12GB', '3060')"""
    n = re.sub(r'[^A-Za-z0-9 +.-]', '', name or '')
    n = re.sub(r'^NVIDIA\s+(GeForce\s+)?', '', n).strip()
    if not n:
        n = 'GPU'
    digits = re.search(r'\d{3,4}', n)
    num = digits.group(0) if digits else n.split()[-1]
    long_name = n + (' %dGB' % round(vram_mib / 1024) if vram_mib else '')
    return n, n.replace(' ', ''), long_name, num


# ---------------------------------------------------------------------------------------------
# Profile generation
# ---------------------------------------------------------------------------------------------
class Spec:
    def __init__(self, bus, dev_id, subsystem, name='', vram_mib=None):
        self.bus, self.name, self.vram_mib = bus, name, vram_mib
        v, d = dev_id.split(':'); self.dword0 = (int(d, 16) << 16) | int(v, 16)
        v2, d2 = subsystem.split(':'); self.sub = (int(d2, 16) << 16) | int(v2, 16)   # vendor:device -> device<<16|vendor


def handle_for(c, spec):
    hits = [h for h in c.handles.values() if h.pci_config and h.pci_location and h.pci_config[0] == spec.dword0 and h.pci_config[11] == spec.sub and h.pci_location[1] == spec.bus]
    return hits


def build_profile(c, target, console, images_dir, profile_name, board_note=''):
    f = []   # findings that do not stop parsing
    if not c.complete or not c.result_ok:
        refuse('capture-incomplete', 'The capture did not finish cleanly.', 'Run the capture again.')
    if c.probe_targets != [1] or len(c.targets) != 1:
        refuse('target-count', 'The diagnostic found %s matching card(s) instead of exactly one.' % (c.probe_targets or 'no'),
               'Two identical cards are not supported yet. Remove one or choose a different card.' if c.probe_targets and c.probe_targets[0] > 1 else 'Run the capture again.')
    t = c.targets[0]
    if t['seg'] != 0 or t['dev'] != 0 or t['fun'] != 0:
        refuse('target-location', 'The target card is not at device 0, function 0 of a PCI bus on segment 0.', 'This layout is not supported.')
    if t['bus'] != target.bus:
        refuse('bus-mismatch', 'The firmware sees the target card on PCI bus %d but Windows reported bus %d.' % (t['bus'], target.bus), 'Restart the installer so the cards are chosen again.')
    cfg = c.cfg
    if not cfg or len(cfg) != 64:
        refuse('config-missing', 'The capture has no complete PCI configuration of the target card.', 'Run the capture again.')
    if cfg[0] != target.dword0 or cfg[11] != target.sub:
        refuse('identity-mismatch', 'The captured card is not the card that was chosen (ID or subsystem differs).', 'Choose the card again.')
    if (cfg[2] >> 24) != 3:
        refuse('not-display', 'The captured device is not a display controller.')
    if (cfg[4] & 0xf) != 0 or not (cfg[4] & ~0xf):
        refuse('bar0', 'The card\'s first memory window (BAR0) is not a 32-bit memory range the boot programs support.')
    if cfg[1] & 4:
        refuse('bus-master', 'The card already has bus mastering on in the capture.', 'Power the PC off completely and run the capture again.')

    # ---- cold state ----
    m = c.mmio
    for off in (OFF_CHIP, OFF_MEMORY, OFF_SS0, OFF_SS1) + tuple(COLD):
        if off not in m:
            refuse('registers-missing', 'The capture is missing register 0x%06x.' % off, 'Run the capture again.')
    bad = [('0x%06x' % off, m[off], want) for off, want in COLD.items() if m[off] != want]
    if bad:
        refuse('not-cold', 'The card is not in the untouched state the unlock expects (register %s reads %#x, expected %#x).' % bad[0],
               'Power the PC off completely (not a restart, Fast Startup off), then run the capture again. If it still differs, this card is not supported.')
    ss0, ss1 = m[OFF_SS0], m[OFF_SS1]
    if ss0 in (0xffffffff, 0x88888888) or (ss0 & 0xffff0000) == 0xbadf0000 or ss1 > 15:
        refuse('selectors', 'The speed selectors read %#x / %#x, which is not an untouched card.' % (ss0, ss1),
               'Power the PC off completely and run the capture again. A card that is already unlocked cannot be captured.')
    if not c.prom_sha:
        refuse('prom-missing', 'The capture has no video BIOS fingerprint.', 'Run the capture again.')

    # ---- capabilities ----
    caps = dict(c.caps)
    def cap_offset(cid):
        offs = [o for o, i in c.caps if i == cid]
        return offs[0] if len(offs) == 1 else None
    pcie = cap_offset(0x10)
    # On the reference card the MSI-X capability sits at 0xc8 but is not linked from the capability chain,
    # so it is looked up at the chain position if present and otherwise at the fixed offset the boot
    # programs pin (the dword there must still carry the MSI-X id).
    msix = cap_offset(0x11)
    if msix is None and (cfg[0xc8 // 4] & 0xff) == 0x11:
        msix = 0xc8
    if pcie is None or msix is None:
        refuse('capabilities', 'The card does not show exactly one PCI Express and one MSI-X capability.')
    if msix != 0xc8:
        refuse('capabilities', "The card's MSI-X capability is at offset %#x; the boot programs only pin offset 0xc8." % msix)
    # ---- handles ----
    th = handle_for(c, target)
    ch = handle_for(c, console)
    if len(th) != 1:
        refuse('target-handle', 'The firmware lists %d PCI devices matching the target card.' % len(th))
    if len(ch) != 1:
        refuse('console-handle', 'The screen adapter was not found exactly once in the capture (bus %d).' % console.bus,
               'Choose the screen adapter again.')
    th, ch = th[0], ch[0]
    # PCI handle paths are PciRoot/Pci/Pci/END (no ADR): compute prefix from nodes
    def pci_prefix(h):
        raw = b''.join(h.path)
        return raw[:24] if len(raw) == 28 and raw[24:] == bytes([0x7f, 0xff, 4, 0]) else None
    tpre, cpre = pci_prefix(th), pci_prefix(ch)
    if tpre is None or cpre is None:
        refuse('pci-path', 'A graphics card is not directly under a CPU root port in the firmware device tree (a bridge or switch is in between).', 'This layout is not supported yet.')

    # ---- GOPs ----
    gops = [h for h in c.handles.values() if GOP_GUID in h.opens]
    if len(gops) != 2:
        refuse('gop-count', 'The firmware created %d graphics output(s); exactly 2 are needed (one per card), none virtual.' % len(gops),
               'If the target card shows no output, attach a monitor, a wireless HDMI adapter or an HDMI/DisplayPort dummy plug to it, power off completely and capture again.' if len(gops) == 1 else 'Unsupported console layout.')
    def gop_for(prefix):
        hits = []
        for g in gops:
            p = classify_path(g.path)
            if p and p['prefix'] == prefix:
                hits.append((g, p))
        return hits
    tg, cg = gop_for(tpre), gop_for(cpre)
    if not tg:
        refuse('no-display-on-target', 'The firmware created no display output for the target card.',
               'Attach a monitor, a wireless HDMI adapter or an HDMI/DisplayPort dummy plug to the target card, power the PC off completely and run the capture again.')
    if len(tg) != 1 or len(cg) != 1:
        refuse('gop-shape', 'The graphics outputs are not one standard output per card.', 'This layout is not supported yet.')
    (rg, rpath), (og, opath) = tg[0], cg[0]
    if rg is og:
        refuse('gop-shape', 'Both cards share one graphics output.')

    # ---- who owns the target's console outputs ----
    def active(h, proto):
        return [o for o in h.opens.get(proto, []) if o[2] not in PASSIVE]
    for h, label in ((rg, 'target'), (og, 'screen adapter')):
        if active(h, EDID_DISCOVERED_GUID):
            refuse('edid-driver', 'The firmware binds a monitor-identity (EDID) driver to the %s output. That layout is not supported yet.' % label)
    def owner(h, proto):
        hits = [o for o in active(h, proto) if o[2] == BY_DRIVER and o[1] == h.id]
        return hits[0][0] if len(hits) == 1 else None
    out_agent, gfx_agent = owner(rg, TEXT_OUT_GUID), owner(rg, GOP_GUID)
    if out_agent is None or gfx_agent is None or out_agent == gfx_agent:
        refuse('console-owners', 'The target\'s text and graphics outputs are not each owned by exactly one firmware driver.')
    if owner(og, TEXT_OUT_GUID) != out_agent or owner(og, GOP_GUID) != gfx_agent:
        refuse('console-shared', 'The screen adapter\'s outputs are not served by the same two firmware console drivers as the target\'s.',
               'This firmware layout is not supported yet; the unlock could blank your screen.')
    # ---- driver facts ----
    def firmware_driver(agent, what):
        b = c.bindings.get(agent)
        if not b or b['base'] is None or b['size'] is None or b['code'] is None:
            refuse('driver-missing', 'The capture has no image details for the %s driver.' % what, 'Run the capture again.')
        if b['code'] != EFI_BOOT_SERVICES_CODE:
            refuse('driver-type', 'The %s driver is not a boot-services driver.' % what)
        if len(b['nodes']) != 2 or b['nodes'][1] != bytes([0x7f, 0xff, 4, 0]):
            refuse('driver-path', 'The %s driver is not a plain firmware-volume file.' % what)
        n = b['nodes'][0]
        if not (n[0] == 4 and n[1] == 6 and n[2:4] == bytes([0x14, 0]) and len(n) == 20):
            refuse('driver-path', 'The %s driver is not a plain firmware-volume file.' % what)
        stop = b['stop'] - b['base']
        if not 0 < stop < b['size']:
            refuse('driver-stop', 'The %s driver\'s stop routine is outside its image.' % what)
        return {'size': b['size'], 'stop': stop, 'version': b['version'], 'guid': n[4:20]}
    txt, gfx = firmware_driver(out_agent, 'text-output'), firmware_driver(gfx_agent, 'graphics')

    # ---- the card's own GOP driver ----
    nv_owners = [o for o in active(th, PCI_IO_GUID) if o[2] == BY_DRIVER and o[1] == th.id]
    if len(nv_owners) != 1:
        refuse('nv-owner', 'The card\'s PCI device is not owned by exactly one firmware driver.')
    nv_agent = nv_owners[0][0]
    b = c.bindings.get(nv_agent)
    if not b or b['dump'] is None or b['code'] != EFI_BOOT_SERVICES_CODE or b['image'] != nv_agent:
        refuse('nv-driver', 'The card\'s GOP driver details are missing from the capture.', 'Run the capture again.')
    n0 = b['nodes'][0] if b['nodes'] else b''
    if len(b['nodes']) != 2 or not (n0[0] == 4 and n0[1] == 4):
        refuse('nv-driver', 'The card\'s GOP driver is not loaded from the card\'s option ROM by name.')
    name = n0[4:].decode('utf-16-le', 'strict').rstrip('\0')
    if not re.fullmatch(r'[A-Za-z0-9._-]{1,40}', name):
        refuse('nv-driver', 'The card\'s GOP driver has an unexpected file name.')
    dump = Path(images_dir) / ('IMG%02d.BIN' % b['dump'])
    if not dump.is_file():
        refuse('image-missing', 'The saved copy of the card\'s GOP driver (%s) is missing.' % dump.name, 'Run the capture again.')
    img = dump.read_bytes()
    if len(img) != b['size']:
        refuse('image-size', 'The saved GOP driver copy has the wrong size.')
    secs, reloc = pe_sections(img)
    code = [s for s in secs if s['flags'] & 0x20]
    if not code:
        refuse('image-text', 'The GOP driver has no code section.')
    text = code[0]
    if text['va'] + text['vsize'] > len(img):
        refuse('image-text', 'The GOP driver\'s code section lies outside its image.')
    if relocations_in(img, reloc, text['va'], text['va'] + text['vsize']):
        refuse('image-relocs', 'The GOP driver\'s code contains relocations, so it cannot be fingerprinted from memory.')
    text_sha = hashlib.sha256(img[text['va']:text['va'] + text['vsize']]).hexdigest()
    stop = b['stop'] - b['base']
    if not 0 < stop < b['size']:
        refuse('driver-stop', 'The GOP driver\'s stop routine is outside its image.')

    short, nospace, long_name, number = short_card_name(target.name, target.vram_mib)
    cshort = short_card_name(console.name)[0]
    bar0 = cfg[4] & ~0xf
    v = {
        'GU_PROFILE_NAME': '"%s"' % re.sub(r'[^A-Za-z0-9._-]', '-', profile_name)[:80],
        'GU_CONSOLE_AGGREGATE': '0',
        'GU_BOARD_ID': '0x%08xU' % cfg[0], 'GU_BOARD_SUBSYSTEM': '0x%08xU' % cfg[11],
        'GU_BAR0_BASE': '0x%08xULL' % bar0, 'GU_BAR0_END': '0x%08xULL' % (bar0 + 0xffffff),
        'GU_CHIP_ID': '0x%08xU' % m[OFF_CHIP], 'GU_DEVICE_MEMORY_SIZE': '0x%xU' % m[OFF_MEMORY],
        'GU_PROM_SHA256': '"%s"' % c.prom_sha,
        'GU_ROOT_PORT_DEVICE': '%dU' % rpath['root_dev'], 'GU_ROOT_PORT_FUNCTION': '%dU' % rpath['root_fn'],
        'GU_RTX_PATH_BYTES': ','.join(str(x) for x in rpath['raw']),
        'GU_OTHER_GPU_BUS': '%d' % console.bus, 'GU_OTHER_GPU_ID': '0x%08xU' % ch.pci_config[0],
        'GU_OTHER_GPU_SUBSYSTEM': '0x%08xU' % ch.pci_config[11],
        'GU_OTHER_GPU_ROOT_DEVICE': '%dU' % opath['root_dev'], 'GU_OTHER_GPU_ROOT_FUNCTION': '%dU' % opath['root_fn'],
        'GU_OTHER_GPU_ADR': '0x%08xU' % opath['adr'], 'GU_OTHER_GPU_PATH_BYTES': ','.join(str(x) for x in opath['raw']),
        'GU_CONSOLE_TEXT_SIZE': '0x%xU' % txt['size'], 'GU_CONSOLE_TEXT_STOP': '0x%xU' % txt['stop'], 'GU_CONSOLE_TEXT_VERSION': '0x%xU' % txt['version'],
        'GU_CONSOLE_GFX_SIZE': '0x%xU' % gfx['size'], 'GU_CONSOLE_GFX_STOP': '0x%xU' % gfx['stop'], 'GU_CONSOLE_GFX_VERSION': '0x%xU' % gfx['version'],
        'GU_NVGOP_VERSION': '0x%xU' % b['version'], 'GU_NVGOP_IMAGE_SIZE': '0x%xU' % b['size'], 'GU_NVGOP_STOP': '0x%xU' % stop,
        'GU_NVGOP_TEXT_RVA': '0x%xU' % text['va'], 'GU_NVGOP_TEXT_BYTES': '0x%xU' % text['vsize'], 'GU_NVGOP_TEXT_SHA256': '"%s"' % text_sha,
        'GU_NO_EDID_DRIVER': '1', 'GU_EDID_IMAGE_SIZE': '0U', 'GU_EDID_STOP': '0U', 'GU_EDID_TEXT_BYTES': '0U', 'GU_EDID_TEXT_SHA256': '""',
        'GU_COMBO_SIZE': '0U', 'GU_COMBO_STOP': '0U', 'GU_COMBO_VERSION': '0U',
        'GU_TARGET_BUS': '%dU' % t['bus'], 'GU_CONFIG_CLASS_REV': '0x%08xU' % cfg[2],
        'GU_PCIE_CAP_OFFSET': '0x%xU' % pcie, 'GU_PCIE_CAP_DWORD': '0x%08xU' % cfg[pcie // 4],
        'GU_MSIX_CAP_OFFSET': '0x%xU' % msix, 'GU_MSIX_CAP_DWORD': '0x%08xU' % cfg[msix // 4],
        'GU_NVGOP_NAME': 'L"%s"' % name,
        'GU_CONSOLE_TEXT_FILE_GUID': guid_initializer(txt['guid']), 'GU_CONSOLE_GFX_FILE_GUID': guid_initializer(gfx['guid']),
        'GU_TARGET_SHORT': '"%s"' % short, 'GU_TARGET_SHORT_NOSPACE': '"%s"' % nospace, 'GU_TARGET_LONG': '"%s"' % long_name,
        'GU_CONSOLE_SHORT': '"%s"' % cshort, 'GU_TARGET_DISPLAY_NUMBER': '"%s"' % number,
    }
    summary = {
        'target': {'bus': t['bus'], 'id': '%04x:%04x' % (cfg[0] & 0xffff, cfg[0] >> 16), 'subsystem': '%04x:%04x' % (cfg[11] & 0xffff, cfg[11] >> 16),
                   'chip': '0x%08x' % m[OFF_CHIP], 'memory_register': '0x%x' % m[OFF_MEMORY], 'bar0': '0x%08x' % bar0,
                   'display_output_found': True, 'selectors': ['0x%x' % ss0, '0x%x' % ss1]},
        'screen_adapter': {'bus': console.bus, 'id': '%04x:%04x' % (ch.pci_config[0] & 0xffff, ch.pci_config[0] >> 16)},
        'console_drivers': {'text': {'size': txt['size'], 'version': txt['version']}, 'graphics': {'size': gfx['size'], 'version': gfx['version']}, 'shared_by_both_cards': True},
        'card_gop_driver': {'name': name, 'version': '0x%x' % b['version'], 'size': b['size']},
        'edid_driver': False, 'aggregate_console': False,
        # what the host replay tests need to find this PC's two cards in the capture (see boot/make-console-fixture.py)
        'fixture': {'rtx_id': '%08x' % cfg[0], 'other_id': '%08x' % ch.pci_config[0],
                    'rtx_path_node': rpath['raw'][12:18].hex(), 'other_path_node': opath['raw'][12:18].hex(),
                    'nvgop_image': 'IMG%02d.BIN' % b['dump']},
    }
    return v, summary


HEADER = '''// GPL-2.0-only. Generated by tools/profile_gen.py from a read-only capture of this PC. Do not edit by hand:
// the boot programs compare every value below with the live machine, and a wrong value only makes them refuse.
// Local file: it describes one PC and must not be shared or committed.
/*
 * Single-machine profile: all hardware identities, display topology and driver fingerprints are
 * immutable build-time constants and are never read from a user-editable file at boot.
 * %(note)s
 */
#pragma once

#define GU_PROFILE_GENERATED 1

/* Production (freestanding firmware) builds that can write to the card:
 *  - headless research stays blocked;
 *  - the release-only test (GU_FULL_UNLOCK + GU_RELEASE_ONLY) loads no unlock program. */
#if !__STDC_HOSTED__ && defined(GU_HEADLESS_RESEARCH)
#error Headless firmware builds are blocked for this profile
#endif
#if !__STDC_HOSTED__ && defined(GU_RELEASE_ONLY) && defined(GU_EXPERIMENTAL_UNLOCK)
#error The release-only test must not be combined with an unlock build
#endif
'''

ORDER = [
    'GU_PROFILE_NAME', 'GU_CONSOLE_AGGREGATE', 'GU_BOARD_ID', 'GU_BOARD_SUBSYSTEM', 'GU_BAR0_BASE', 'GU_BAR0_END', 'GU_CHIP_ID',
    'GU_DEVICE_MEMORY_SIZE', 'GU_PROM_SHA256', 'GU_ROOT_PORT_DEVICE', 'GU_ROOT_PORT_FUNCTION', 'GU_RTX_PATH_BYTES',
    'GU_OTHER_GPU_BUS', 'GU_OTHER_GPU_ID', 'GU_OTHER_GPU_SUBSYSTEM', 'GU_OTHER_GPU_ROOT_DEVICE', 'GU_OTHER_GPU_ROOT_FUNCTION',
    'GU_OTHER_GPU_ADR', 'GU_OTHER_GPU_PATH_BYTES',
    'GU_CONSOLE_TEXT_SIZE', 'GU_CONSOLE_TEXT_STOP', 'GU_CONSOLE_TEXT_VERSION', 'GU_CONSOLE_GFX_SIZE', 'GU_CONSOLE_GFX_STOP', 'GU_CONSOLE_GFX_VERSION',
    'GU_NVGOP_VERSION', 'GU_NVGOP_IMAGE_SIZE', 'GU_NVGOP_STOP', 'GU_NVGOP_TEXT_RVA', 'GU_NVGOP_TEXT_BYTES', 'GU_NVGOP_TEXT_SHA256',
    'GU_NO_EDID_DRIVER', 'GU_EDID_IMAGE_SIZE', 'GU_EDID_STOP', 'GU_EDID_TEXT_BYTES', 'GU_EDID_TEXT_SHA256',
    'GU_COMBO_SIZE', 'GU_COMBO_STOP', 'GU_COMBO_VERSION',
    'GU_TARGET_BUS', 'GU_CONFIG_CLASS_REV', 'GU_PCIE_CAP_OFFSET', 'GU_PCIE_CAP_DWORD', 'GU_MSIX_CAP_OFFSET', 'GU_MSIX_CAP_DWORD',
    'GU_NVGOP_NAME', 'GU_CONSOLE_TEXT_FILE_GUID', 'GU_CONSOLE_GFX_FILE_GUID',
    'GU_TARGET_SHORT', 'GU_TARGET_SHORT_NOSPACE', 'GU_TARGET_LONG', 'GU_CONSOLE_SHORT', 'GU_TARGET_DISPLAY_NUMBER',
]


def render_header(values, note=''):
    out = [HEADER % {'note': re.sub(r'[^A-Za-z0-9 .,:/()_-]', '', note)}]
    assert set(ORDER) == set(values), set(ORDER) ^ set(values)
    for k in ORDER:
        out.append('#define %s %s' % (k, values[k]))
    return '\n'.join(out) + '\n'


def parse_define_values(header_text):
    """Reference/generated header -> {macro: normalized value}; used by tests to compare two profiles by VALUE."""
    # join continuation lines
    t = re.sub(r'\\\r?\n\s*', ' ', header_text)
    t = re.sub(r'/\*.*?\*/', '', t, flags=re.S)
    t = re.sub(r'//[^\n]*', '', t)
    out = {}
    for m in re.finditer(r'^#define\s+(GU_[A-Z0-9_]+)\s+(.*?)\s*$', t, re.M):
        name, val = m[1], m[2]
        out[name] = normalize_value(val)
    return out


def normalize_value(val):
    val = val.strip()
    if re.fullmatch(r'(0x[0-9a-fA-F]+|\d+)(U|ULL|u|ull)?', val):
        return ('int', int(re.sub(r'[Uu][Ll]*$', '', val), 0))
    if re.fullmatch(r'L?"[^"]*"', val):
        return ('str', val[1:-1] if val[0] == '"' else 'L' + val[2:-1])
    if val.startswith('{') and val.endswith('}'):
        return ('list', tuple(int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+', val)))
    if re.fullmatch(r'(0x[0-9a-fA-F]+|\d+)(\s*,\s*(0x[0-9a-fA-F]+|\d+))+', val):
        return ('list', tuple(int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+', val)))
    return ('raw', val)


DISCOVERY = """// GPL-2.0-only. Discovery profile: lets the READ-ONLY diagnostic find the chosen card. It holds nothing but the
// card's PCI id. Boot programs that can write to a card refuse to build against it (they need a generated profile).
#pragma once
#define GU_PROFILE_DISCOVERY 1
#define GU_BOARD_ID 0x%08xU
#define GU_CONSOLE_AGGREGATE 0
"""


def render_discovery(dev_id):
    spec = Spec(0, dev_id, '0000:0000')
    return DISCOVERY % spec.dword0


def generate(capture_path, images_dir, target, console, profile_name, note=''):
    text = Path(capture_path).read_text(encoding='utf-8', errors='replace')
    cap = parse_capture(text)
    values, summary = build_profile(cap, target, console, images_dir, profile_name, note)
    return render_header(values, note), summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--discovery', action='store_true', help='write only the discovery profile for --target-id')
    ap.add_argument('--capture')
    ap.add_argument('--images')
    ap.add_argument('--target-bus', type=int)
    ap.add_argument('--target-id', required=True)
    ap.add_argument('--target-subsystem')
    ap.add_argument('--target-name', default='')
    ap.add_argument('--target-vram-mib', type=int, default=None)
    ap.add_argument('--console-bus', type=int)
    ap.add_argument('--console-id')
    ap.add_argument('--console-subsystem')
    ap.add_argument('--console-name', default='')
    ap.add_argument('--profile-name', default='generated')
    ap.add_argument('--note', default='')
    ap.add_argument('--out', required=True)
    ap.add_argument('--summary')
    a = ap.parse_args(argv)
    if a.discovery:
        if not re.fullmatch(r'[0-9a-fA-F]{4}:[0-9a-fA-F]{4}', a.target_id):
            print('bad --target-id', file=sys.stderr); return 1
        Path(a.out).write_text(render_discovery(a.target_id), encoding='ascii', newline='\n')
        return 0
    for need in ('capture', 'images', 'target_bus', 'target_subsystem', 'console_bus', 'console_id', 'console_subsystem', 'summary'):
        if getattr(a, need) is None:
            print('missing --' + need.replace('_', '-'), file=sys.stderr); return 1
    target = Spec(a.target_bus, a.target_id, a.target_subsystem, a.target_name, a.target_vram_mib)
    console = Spec(a.console_bus, a.console_id, a.console_subsystem, a.console_name)
    try:
        header, summary = generate(a.capture, a.images, target, console, a.profile_name, a.note)
    except Refused as r:
        print(json.dumps({'ok': False, 'findings': [x.as_dict() for x in r.findings]}, indent=1))
        return 2
    Path(a.out).write_text(header, encoding='ascii', newline='\n')
    Path(a.summary).write_text(json.dumps({'ok': True, 'summary': summary}, indent=1), encoding='ascii')
    print(json.dumps({'ok': True, 'summary': summary}, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
