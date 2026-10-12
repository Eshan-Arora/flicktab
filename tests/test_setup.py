"""Run with python3 -m unittest discover -s tests. No apps are installed or opened."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'config with spaces'
        self.config.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.mock('uname', 'echo Darwin')
        self.mock('open', 'exit 0')
        self.env = dict(os.environ, HAMMERSPOON_CONFIG_DIR=str(self.config),
                        PATH=f'{self.bin}:/usr/bin:/bin')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_setup(self, success=True):
        result = subprocess.run(['/bin/bash', str(ROOT / 'setup')], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_preserves_config_and_is_repeatable(self):
        initial = '-- My other scripts\nother = require("other")'  # no final newline
        init = self.config / 'init.lua'
        init.write_text(initial)
        self.run_setup()
        self.run_setup()
        self.assertTrue(init.read_text().startswith(initial + '\n'))
        self.assertEqual(init.read_text().count('hs.loadSpoon("FlickTab"):start()'), 1)
        self.assertTrue(any(p.read_text() == initial for p in self.config.glob('flicktab-backup.*/init.lua')))
        self.assertEqual((self.config / 'Spoons/FlickTab.spoon/init.lua').read_bytes(),
                         (ROOT / 'FlickTab.spoon/init.lua').read_bytes())

    def test_new_config(self):
        self.run_setup()
        self.assertIn('hs.loadSpoon', (self.config / 'init.lua').read_text())

    def test_symlinked_config_preserved(self):
        target = self.root / 'dotfiles.lua'
        target.write_text('-- kept\n')
        init = self.config / 'init.lua'
        init.symlink_to(target)
        self.run_setup()
        self.assertTrue(init.is_symlink())
        self.assertTrue(target.read_text().startswith('-- kept\n'))

    def test_legacy_switcher_rejected_without_mutation(self):
        init = self.config / 'init.lua'
        original = "searchSwitcher = require('search_switcher'):start()\n"
        init.write_text(original)
        self.run_setup(False)
        self.assertEqual(init.read_text(), original)
        self.assertFalse((self.config / 'Spoons').exists())

    def test_symlinked_spoon_not_overwritten(self):
        target = self.root / 'old.lua'
        target.write_text('-- keep\n')
        spoon = self.config / 'Spoons/FlickTab.spoon'
        spoon.mkdir(parents=True)
        (spoon / 'init.lua').symlink_to(target)
        self.run_setup(False)
        self.assertEqual(target.read_text(), '-- keep\n')

    def test_installs_hammerspoon_when_missing(self):
        self.mock('open', 'if [[ "$1" == -Ra ]]; then exit 1; fi')
        self.mock('brew', f'printf "%s\\n" "$*" > "{self.root}/brew-call"')
        self.run_setup()
        self.assertEqual((self.root / 'brew-call').read_text(), 'install --cask hammerspoon\n')

    def test_missing_homebrew_leaves_config_untouched(self):
        self.mock('open', 'exit 1')
        result = self.run_setup(False)
        self.assertIn('Install Hammerspoon', result.stderr)
        self.assertFalse((self.config / 'init.lua').exists())

    def test_failed_install_leaves_config_untouched(self):
        self.mock('open', 'exit 1')
        self.mock('brew', 'exit 1')
        self.run_setup(False)
        self.assertFalse((self.config / 'init.lua').exists())

    def test_incomplete_startup_block_rejected(self):
        (self.config / 'init.lua').write_text('-- FlickTab\n')
        self.run_setup(False)
        self.assertFalse((self.config / 'Spoons').exists())


if __name__ == '__main__':
    unittest.main()
