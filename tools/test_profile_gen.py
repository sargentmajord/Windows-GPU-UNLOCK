"""Tests for profile_gen.py.

Golden and refusal tests need the private captures of the reference machine (never published); they look in
$GPU_UNLOCK_CAPTURES or ..\\..\\captures and are skipped when absent. Helper tests use synthetic data only.
Run:  python -m unittest tools/test_profile_gen.py -v
"""
import contextlib
import io
import os
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import profile_gen as pg  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
CAPS = Path(os.environ.get('GPU_UNLOCK_CAPTURES', REPO.parent / 'captures'))
RUN03 = CAPS / 'run03-restart-adapter-on-3060'
RUN01 = CAPS / 'run01-no-display-on-3060'
REFERENCE = REPO / 'internal-boot' / 'unlock' / 'profiles' / 'z790-3060' / 'profile.h'
HAVE = (RUN03 / 'DIAG02.TXT').is_file() and (RUN03 / 'IMG34.BIN').is_file()


def specs():
    t = pg.Spec(1, '10de:2544', '1462:397d', 'NVIDIA GeForce RTX 3060', 12288)
    c = pg.Spec(2, '10de:2f04', '1043:89f2', 'NVIDIA GeForce RTX 5070')
    return t, c


def run(text, images=RUN03, target=None, console=None, name='TEST-PROFILE'):
    t, c = specs()
    return pg.build_profile(pg.parse_capture(text), target or t, console or c, images, name)


def refused(testcase, text, code, **kw):
    with testcase.assertRaises(pg.Refused) as cm:
        run(text, **kw)
    testcase.assertEqual(cm.exception.findings[0].code, code, cm.exception.findings[0].message)
    return cm.exception.findings[0]


class Helpers(unittest.TestCase):
    def test_guid_forms(self):
        raw = bytes.fromhex('7d498a62f62b64428741069dbd3399d6')
        self.assertEqual(pg.guid_text(raw), '628a497d-2bf6-4264-8741-069dbd3399d6')
        self.assertEqual(pg.guid_initializer(raw), '{0x628a497d,0x2bf6,0x4264,{0x87,0x41,0x06,0x9d,0xbd,0x33,0x99,0xd6}}')

    def test_card_names(self):
        self.assertEqual(pg.short_card_name('NVIDIA GeForce RTX 3060', 12288), ('RTX 3060', 'RTX3060', 'RTX 3060 12GB', '3060'))
        self.assertEqual(pg.short_card_name('NVIDIA GeForce RTX 3080 Ti')[3], '3080')
        s = pg.short_card_name('NVIDIA GeForce RTX 3070 "evil" \\ \n name')[0]
        self.assertNotRegex(s, r'["\\\n]')
        self.assertEqual(pg.short_card_name('')[0], 'GPU')

    def test_value_normalization(self):
        self.assertEqual(pg.normalize_value('0x254410deU'), pg.normalize_value('0x254410DE'))
        self.assertEqual(pg.normalize_value('0x85000000ULL'), ('int', 0x85000000))
        self.assertEqual(pg.normalize_value('"abc"'), ('str', 'abc'))
        self.assertEqual(pg.normalize_value('L"abc"'), ('str', 'Labc'))
        self.assertEqual(pg.normalize_value('2,1,12'), ('list', (2, 1, 12)))
        self.assertEqual(pg.normalize_value('{0x1,0x2,{0x3}}'), ('list', (1, 2, 3)))

    def test_path_shapes(self):
        n = [bytes.fromhex(x) for x in ('02010c00d041030a00000000', '010106000001', '010106000000', '0203080070030180', '7fff0400')]
        p = pg.classify_path(n)
        self.assertEqual((p['root_dev'], p['root_fn'], p['adr']), (1, 0, 0x80010370))
        self.assertIsNone(pg.classify_path(n[:4] + [bytes.fromhex('7f010400')]))             # wrong end node
        self.assertIsNone(pg.classify_path(n[:3] + [bytes.fromhex('0203080070030180'), bytes.fromhex('010106000000'), n[4]]))   # extra bridge
        bad = list(n); bad[0] = bytes.fromhex('02010c00d041020a00000000')
        self.assertIsNone(pg.classify_path(bad))                                              # not a PCI root
        bad = list(n); bad[2] = bytes.fromhex('010106000100')
        self.assertIsNone(pg.classify_path(bad))                                              # not Pci(0,0)

    def _pe(self, text_va, text_size, reloc_in_text):
        img = bytearray(0x1000)
        img[0:2] = b'MZ'; struct.pack_into('<I', img, 0x3c, 0x80)
        e = 0x80
        img[e:e + 4] = b'PE\0\0'
        struct.pack_into('<H', img, e + 6, 1)           # one section
        struct.pack_into('<H', img, e + 20, 0xf0)       # optional header size
        opt = e + 24
        struct.pack_into('<H', img, opt, 0x20b)
        dd = opt + 112
        struct.pack_into('<II', img, dd + 8 * 5, 0x800, 12)   # reloc dir
        sec = opt + 0xf0
        struct.pack_into('<8sIIIII', img, sec, b'.text', text_size, text_va, text_size, 0x400, 0)
        struct.pack_into('<I', img, sec + 36, 0x60000020)
        # one reloc block: page 0x200, one entry at +0x10 (type 10) -> RVA 0x210 or elsewhere
        struct.pack_into('<II', img, 0x800, 0x200 if reloc_in_text else 0x600, 12)
        struct.pack_into('<H', img, 0x808, (10 << 12) | 0x10)
        struct.pack_into('<H', img, 0x80a, 0)
        return bytes(img)

    def test_pe_sections_and_relocs(self):
        img = self._pe(0x200, 0x300, True)
        secs, reloc = pg.pe_sections(img)
        self.assertEqual((secs[0]['name'], secs[0]['va'], secs[0]['vsize']), ('.text', 0x200, 0x300))
        self.assertEqual(pg.relocations_in(img, reloc, 0x200, 0x500), 1)
        img2 = self._pe(0x200, 0x300, False)
        secs, reloc = pg.pe_sections(img2)
        self.assertEqual(pg.relocations_in(img2, reloc, 0x200, 0x500), 0)
        with self.assertRaises(pg.Refused):
            pg.pe_sections(b'not a pe file' * 10)

    def test_render_contains_every_macro_once_and_is_ascii(self):
        values = {k: '0' for k in pg.ORDER}
        text = pg.render_header(values, 'board "x"\\ \n y')
        text.encode('ascii')
        for k in pg.ORDER:
            self.assertEqual(len(re.findall(r'^#define %s ' % k, text, re.M)), 1, k)
        self.assertNotIn('\\', text.split('*/')[0].split('/*')[1])   # the note was sanitized
        with self.assertRaises(AssertionError):
            pg.render_header({'GU_BOARD_ID': '1'})


@unittest.skipUnless(HAVE, 'private reference captures not available')
class Golden(unittest.TestCase):
    def test_generated_profile_equals_reference_by_value(self):
        text = (RUN03 / 'DIAG02.TXT').read_text(encoding='utf-8')
        values, summary = run(text, name='MSI-MEG-Z790-GODLIKE-1.I0-RTX3060')
        header = pg.render_header(values)
        got = pg.parse_define_values(header)
        ref = pg.parse_define_values(REFERENCE.read_text(encoding='utf-8'))
        for k in pg.ORDER:
            self.assertEqual(got[k], ref[k], k)
        self.assertTrue(summary['console_drivers']['shared_by_both_cards'])
        self.assertEqual(summary['card_gop_driver']['name'], 'nvgop-ga1xx')
        # the values the host replay tests need to find the two cards in the capture
        self.assertEqual(summary['fixture'], {'rtx_id': '254410de', 'other_id': '2f0410de', 'rtx_path_node': '010106000001',
                                              'other_path_node': '010106000101', 'nvgop_image': 'IMG34.BIN'})

    def test_cli_writes_files_and_refusal_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            out, summ = Path(d) / 'profile.h', Path(d) / 's.json'
            base = ['--capture', str(RUN03 / 'DIAG02.TXT'), '--images', str(RUN03), '--target-bus', '1', '--target-id', '10de:2544',
                    '--target-subsystem', '1462:397d', '--console-bus', '2', '--console-id', '10de:2f04', '--console-subsystem', '1043:89f2',
                    '--out', str(out), '--summary', str(summ)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pg.main(base), 0)
            self.assertTrue(out.is_file() and summ.is_file())
            out.unlink(); summ.unlink()
            bad = list(base); bad[bad.index('10de:2544')] = '10de:2204'
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pg.main(bad), 2)
            self.assertFalse(out.exists() or summ.exists())


@unittest.skipUnless(HAVE, 'private reference captures not available')
class Refusals(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (RUN03 / 'DIAG02.TXT').read_text(encoding='utf-8').replace('\r\n', '\n')

    def mutate(self, pattern, repl, count=1):
        new, n = re.subn(pattern, repl, self.text, count=count, flags=re.M)
        self.assertGreaterEqual(n, 1, pattern)
        return new

    def test_incomplete_capture(self):
        refused(self, self.text.replace('capture-complete=1', 'capture-complete=0'), 'capture-incomplete')
        refused(self, self.text.replace('diagnostic-result status=0x0000000000000000', 'diagnostic-result status=0x8000000000000007'), 'capture-incomplete')

    def test_wrong_choices(self):
        t, c = specs()
        refused(self, self.text, 'identity-mismatch', target=pg.Spec(1, '10de:2544', '1462:ffff', '', None))
        refused(self, self.text, 'bus-mismatch', target=pg.Spec(5, '10de:2544', '1462:397d'))
        refused(self, self.text, 'console-handle', console=pg.Spec(9, '10de:2f04', '1043:89f2'))
        refused(self, self.text, 'console-handle', console=pg.Spec(2, '10de:2f04', '1043:0000'))

    def test_two_matching_cards(self):
        t = self.mutate(r'^probe targets=0001$', 'probe targets=0002')
        f = refused(self, t, 'target-count')
        self.assertIn('Two identical cards', f.fix)

    def test_not_cold(self):
        refused(self, self.mutate(r'^(mmio off=0x00118128 status=0x0+ value=)0x00008b8f$', r'\g<1>0x00001234'), 'not-cold')
        refused(self, self.mutate(r'^(mmio off=0x00823804 status=0x0+ value=)0xffffff8f$', r'\g<1>0xffffffff'), 'not-cold')
        f = refused(self, self.mutate(r'^(mmio off=0x0082381c status=0x0+ value=)0x[0-9a-f]+$', r'\g<1>0x88888888'), 'selectors')
        self.assertIn('already unlocked', f.fix)
        refused(self, self.mutate(r'^(mmio off=0x00823820 status=0x0+ value=)0x[0-9a-f]+$', r'\g<1>0x00000010'), 'selectors')
        refused(self, self.mutate(r'^(mmio off=0x0082381c status=0x0+ value=)0x[0-9a-f]+$', r'\g<1>0xbadf5040'), 'selectors')

    def test_missing_register_or_prom(self):
        refused(self, self.mutate(r'^mmio off=0x001183a4 .*$', ''), 'registers-missing')
        refused(self, self.mutate(r'^prom sha256=.*$', ''), 'prom-missing')

    def test_bus_master_on(self):
        # config dword 1 (command/status) 0x00100003 -> 0x00100007 sets bus master
        refused(self, self.mutate(r'^(cfg dwords=\S+ )00100003', r'\g<1>00100007'), 'bus-master')

    def test_no_display_on_target(self):
        if not (RUN01 / 'DIAG00.TXT').is_file():
            self.skipTest('run01 not available')
        f = refused(self, (RUN01 / 'DIAG00.TXT').read_text(encoding='utf-8'), 'gop-count', images=RUN01)
        self.assertIn('dummy plug', f.fix)

    def test_edid_driver_bound(self):
        # make one active (BY_DRIVER) opener of the EDID protocol on the target's graphics output handle
        t = self.text
        i = t.index('handle id=0x000000006e007b18')
        j = t.index('protocol guid=%s' % pg.EDID_DISCOVERED_GUID, i)
        k = t.index('\n', t.index('opens status', j)) + 1
        t = t[:k] + 'open agent=0x000000006e198498 controller=0x000000006e007b18 attributes=0x0000000000000010 count=0x0000000000000001\n' + t[k:]
        refused(self, t, 'edid-driver')

    def test_console_drivers_not_shared(self):
        # move the screen adapter's text-output owner to another agent handle
        t = self.text
        i = t.index('handle id=0x000000006dfacf18')
        j = t.index('protocol guid=%s' % pg.TEXT_OUT_GUID, i)
        old = 'open agent=0x000000006ec48698 controller=0x000000006dfacf18 attributes=0x0000000000000010'
        k = t.index(old, j)
        t = t[:k] + old.replace('6ec48698', '6ec48518') + t[k + len(old):]
        refused(self, t, 'console-shared')

    def test_pathless_or_bridged_display_output(self):
        t = self.text
        i = t.index('handle id=0x000000006dfacf18')
        j = t.index('\nhandle id=', i + 1)
        block = t[i:j]
        block2 = re.sub(r'^path-node raw=.*\n', '', block, flags=re.M)
        refused(self, t[:i] + block2 + t[j:], 'gop-shape')

    def test_missing_image_dump(self):
        with tempfile.TemporaryDirectory() as d:
            refused(self, self.text, 'image-missing', images=d)
            # a dump of the wrong size
            (Path(d) / 'IMG34.BIN').write_bytes(b'MZ' + bytes(100))
            refused(self, self.text, 'image-size', images=d)

    def test_tampered_image_changes_the_code_fingerprint(self):
        good, _ = run(self.text)
        with tempfile.TemporaryDirectory() as d:
            img = bytearray((RUN03 / 'IMG34.BIN').read_bytes())
            img[0x300] ^= 0xff
            (Path(d) / 'IMG34.BIN').write_bytes(bytes(img))
            bad, _ = run(self.text, images=d)
        self.assertNotEqual(good['GU_NVGOP_TEXT_SHA256'], bad['GU_NVGOP_TEXT_SHA256'])

    def test_aggregate_or_third_output_refused(self):
        t = self.text.replace('handle id=0x000000006dfacf18', 'handle id=0x000000006dfacf18', 1)
        # add a pathless GOP handle (virtual aggregate console)
        t = t.replace('capture-complete=1', 'handle id=0x000000006e999999\nprotocol guid=%s\nopens status=0x0000000000000000 count=0x0000000000000000\ngop framebuffer=0x0000000000000000 bytes=0x0000000000000000 mode=0x0 max-mode=0x1\ncapture-complete=1' % pg.GOP_GUID)
        refused(self, t, 'gop-count')


if __name__ == '__main__':
    unittest.main()
