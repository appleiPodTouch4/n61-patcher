"""Verify the native B1 adaptation changes exactly three firmware mappings."""
import importlib.util
from pathlib import Path
import unittest


class HashstoreTests(unittest.TestCase):
    def implementation(self):
        path = Path(__file__).with_name('hashstore_patch.py')
        self.assertTrue(path.exists(), 'native B1 hashstore adapter is missing')
        spec = importlib.util.spec_from_file_location('wifi_hashstore_adapter', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_adaptation_preserves_every_unrelated_key_and_original_shared_value(self):
        m = self.implementation()
        k = m.Kernel(m.BASELINE)
        before = m.read_index(k)
        data, report = m.adapt(k)
        if report.get('already_approved'):
            # n56ap 的 barbera 已在 j96 基线里被批准，没有可验证的适配。
            self.skipTest('board firmware already approved in baseline hashstore')
        after = m.read_index(m.ByteView(k, data))
        changed = {key for key in before if m.semantic(before[key]) != m.semantic(after[key])}
        self.assertEqual(changed, {m.path_key(name) for name in m.OLD_HASHES})
        self.assertEqual(len(before) - len(changed), len(before) - len(m.OLD_HASHES))
        for name, item in m.native_files().items():
            self.assertEqual(after[m.path_key(name)]['digest'], bytes.fromhex(item['sha256']))
            self.assertEqual(after[m.path_key(name)]['length'], item['bytes'])
        trx = next(n for n in m.OLD_HASHES if n.endswith('.trx'))
        original = before[m.path_key(trx)]['value']
        view = m.ByteView(k, data)
        self.assertEqual(view.read(original, 24), k.read(original, 24))
        for bundle in ('com.apple.driver.AppleSN2400Charger', 'com.apple.driver.AppleChestnutDisplayPMU'):
            for s in k.ksegments(bundle):
                if s['vs']:
                    self.assertEqual(view.read(s['vm'], s['vs']), k.read(s['vm'], s['vs']))
        self.assertEqual(report['new_slide_slots'], [m.STORAGE + 0x80, m.STORAGE + 0x90])

    def test_bad_digest_length_is_rejected(self):
        m = self.implementation()
        k = m.Kernel(m.BASELINE)
        files = m.native_files()
        files[next(n for n in m.OLD_HASHES if n.endswith('.trx'))]['bytes'] += 1
        with self.assertRaisesRegex(ValueError, 'length'):
            m.adapt(k, files)


if __name__ == '__main__':
    unittest.main()
