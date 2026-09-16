#!/usr/bin/env python3
"""Regression tests using synthetic firmware; no device support claim."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('audit', SCRIPTS / 'b2q_fold_cover_audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class FoldCoverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_layouts_and_path_escape(self):
        work = self.root / 'work'
        (work / 'system/system/system_ext').mkdir(parents=True)
        expected = work / 'system/system/etc/devicestate/test.xml'
        self.assertEqual(audit.resolve(work, 'system/etc/devicestate/test.xml'), expected)
        self.assertEqual(audit.resolve(work, 'system/system/etc/devicestate/test.xml'), expected)
        self.assertEqual(audit.resolve(work, 'system_ext/etc/test.xml'),
                         work / 'system/system/system_ext/etc/test.xml')
        for rel in ['../bad', '/system/etc/bad', 'unknown/etc/bad', 'product/etc/missing']:
            with self.assertRaises(ValueError):
                audit.resolve(work, rel)

    def test_stale_zip_archived_only_for_b2q(self):
        old = self.root / 'b2q_test-target_files.zip'
        old.write_bytes(b'old build')
        other = self.root / 'other_test-target_files.zip'
        other.write_bytes(b'other build')
        subprocess.run(['bash', str(SCRIPTS / 'refresh_b2q_target_files.sh'), str(self.root)], check=True)
        self.assertFalse(old.exists())
        self.assertEqual(next(self.root.glob('b2q-previous-*/*')).read_bytes(), b'old build')
        self.assertTrue(other.exists())

    def test_prepare_install_final_audit_and_detect_later_overwrite(self):
        repo = self.root / 'repo'
        (repo / 'scripts').mkdir(parents=True)
        for name in ['prepare_b2q_fold_cover.sh', 'b2q_fold_cover_audit.py']:
            shutil.copy2(SCRIPTS / name, repo / 'scripts' / name)
        fw = self.root / 'firmware'
        etc = fw / 'system/system/etc'
        (etc / 'devicestate').mkdir(parents=True)
        flags = '<SecFloatingFeatureSet><SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_FOLDABLE_TYPE_FLIP>TRUE</SEC_FLOATING_FEATURE_FRAMEWORK_SUPPORT_FOLDABLE_TYPE_FLIP></SecFloatingFeatureSet>'
        (etc / 'floating_feature.xml').write_text(flags)
        (etc / 'devicestate/device_state_configuration.xml').write_text('<device-state-config/>')
        subprocess.run(['bash', str(repo / 'scripts/prepare_b2q_fold_cover.sh'), str(fw)], check=True, capture_output=True)
        work = self.root / 'work'
        (work / 'system/system/etc').mkdir(parents=True)
        (work / 'system/system/etc/floating_feature.xml').write_text(flags)
        patch = SCRIPTS.parent / 'target/b2q/patches/fold_cover_stock/customize.sh'
        subprocess.run(['bash', '-euc', 'LOG(){ echo "$*"; }; ABORT(){ echo "$*" >&2; return 1; }; source "$1"',
                        'test', str(patch)], check=True,
                       env={**__import__('os').environ, 'SRC_DIR': str(repo), 'WORK_DIR': str(work)}, capture_output=True)
        stage = repo / 'target/b2q/fold-cover'
        report = self.root / 'report.json'
        self.assertFalse(audit.verify(work, stage, report))
        (work / 'system/system/etc/devicestate/device_state_configuration.xml').write_text('<overwritten/>')
        self.assertTrue(audit.verify(work, stage, report))
        self.assertIn('Installed config changed', json.loads(report.read_text())['errors'][0])
        (work / 'system/system/etc/floating_feature.xml').write_text(flags.replace('TRUE', 'FALSE'))
        self.assertTrue(audit.verify(work, stage, report))
        self.assertTrue(any('Floating feature mismatch' in x for x in json.loads(report.read_text())['errors']))


if __name__ == '__main__':
    unittest.main()
