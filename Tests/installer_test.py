import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = next((ROOT/'skill').glob('*/scripts/install_support.py'))
spec = importlib.util.spec_from_file_location('installer', SCRIPT)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.base = Path(self.temp.name)
        self.source = self.base/'source'; self.source.mkdir(); (self.source/'new').write_text('new')
        self.target = self.base/'installed'; self.target.mkdir(); (self.target/'old').write_text('old')
        self.support = self.base/'support'; self.support.mkdir(); (self.support/'config.json').write_text('{"mine":true}')
    def tearDown(self): self.temp.cleanup()
    def test_replaces_tree_without_stale_files_and_preserves_configuration(self):
        result = m.install([(self.source,self.target)], self.support)
        self.assertFalse((self.target/'old').exists()); self.assertTrue((self.target/'new').exists())
        self.assertEqual((self.support/'config.json').read_text(), '{"mine":true}')
        self.assertIn(str(self.target/'new'), result['files'])
    def test_failure_restores_all_targets(self):
        source2=self.base/'source2';source2.write_text('new2')
        target2=self.base/'installed2';target2.write_text('old2')
        with self.assertRaises(OSError):
            m.install([(self.source,self.target),(source2,target2)],self.support,fail_after=1)
        self.assertEqual((self.target/'old').read_text(),'old'); self.assertFalse((self.target/'new').exists())
        self.assertEqual(target2.read_text(),'old2')
    def test_interrupted_install_is_recovered_before_new_attempt(self):
        backup=self.base/'backup';self.target.rename(backup);self.target.mkdir();(self.target/'broken').write_text('bad')
        m.atomic_json(self.support/'install-transaction.json',dict(state='prepared',entries=[dict(target=str(self.target),backup=str(backup),stage=str(self.base/'stage'),existed=True)]))
        with self.assertRaises(ValueError):m.install([(self.base/'missing',self.target)],self.support)
        self.assertEqual((self.target/'old').read_text(),'old'); self.assertFalse((self.target/'broken').exists())
    def test_existing_manifest_survives_failed_upgrade(self):
        m.install([(self.source,self.target)],self.support)
        manifest=(self.support/'installation.json').read_bytes()
        (self.source/'new').write_text('changed')
        with self.assertRaises(OSError):m.install([(self.source,self.target)],self.support,fail_after=1)
        self.assertEqual((self.support/'installation.json').read_bytes(),manifest)
        self.assertEqual((self.target/'new').read_text(),'new')

if __name__=='__main__':unittest.main()
