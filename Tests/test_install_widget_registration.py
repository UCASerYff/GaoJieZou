#!/usr/bin/env python3
"""Pure PlugInKit replies and a fake-command rollback trap; no system changes."""
import contextlib
import io
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
INSTALL = Path(__file__).resolve().parents[1] / 'scripts/install.sh'
SOURCE = INSTALL.read_text()
PARSER = SOURCE.split("<<'PYWIDGETREG'\n", 1)[1].split('\nPYWIDGETREG', 1)[0]
UUID = '11111111-2222-4333-8444-555555555555'
BID = 'com.gaojiezou.rhythm.widgets'


class WidgetRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhythm-installer-', suffix='.noindex', dir='/private/tmp')
        self.base = Path(self.tmp.name)
        self.extension = self.base / 'Formal.app/Contents/PlugIns/GaoJieZouWidgets.appex'
        self.extension.mkdir(parents=True)
        self.addCleanup(self.tmp.cleanup)

    def header(self, path=None, version='4.09', identifier=UUID):
        return '- %s(%s)\n    UUID = %s\n    Path = %s\n' % (BID, version, identifier, path or self.extension)

    def parse(self, output='', code=0, error='', bid=BID, extension=None):
        reply = SimpleNamespace(returncode=code, stdout=output, stderr=error)
        out = io.StringIO()
        with mock.patch.object(sys, 'argv', ['parser', str(extension or self.extension), bid, '4.09']), \
             mock.patch.object(subprocess, 'run', return_value=reply) as query, contextlib.redirect_stdout(out):
            exec(compile(PARSER, '<installer-widget-parser>', 'exec'), {'__name__': '__main__'})
            query.assert_called_once_with(['/usr/bin/pluginkit', '-m', '-A', '-D', '-vv', '-i', bid],
                                          capture_output=True, text=True)
        return out.getvalue().strip()

    def test_known_empty_replies(self):
        for text in ('', '  (no matches)\n', '0 plug-in(s)\n'):
            with self.subTest(text=text): self.assertEqual(self.parse(text), 'absent')

    def test_unique_formal_instance(self):
        self.assertEqual(self.parse(self.header()), 'present')

    def test_query_failure_is_not_absence(self):
        with self.assertRaises(RuntimeError): self.parse('  (no matches)\n', code=1)

    def test_stderr_is_not_absence(self):
        with self.assertRaises(RuntimeError): self.parse('  (no matches)\n', error='query unavailable')

    def test_unknown_empty_output_refused(self):
        with self.assertRaises(RuntimeError): self.parse('unreadable registry')

    def test_multiple_instances_refused(self):
        with self.assertRaises(RuntimeError): self.parse(self.header() + self.header())

    def test_nonformal_instance_is_absent_for_exact_target(self):
        reply = self.header(path=self.base / 'Other.app/Contents/PlugIns/GaoJieZouWidgets.appex')
        self.assertEqual(self.parse(reply), 'absent')

    def test_other_version_refused(self):
        with self.assertRaises(RuntimeError): self.parse(self.header(version='4.10'))

    def test_invalid_or_nil_uuid_refused(self):
        for identifier in ('invalid', '00000000-0000-0000-0000-000000000000'):
            with self.subTest(identifier=identifier), self.assertRaises(RuntimeError): self.parse(self.header(identifier=identifier))

    def test_unknown_bid_refused(self):
        with self.assertRaises(RuntimeError): self.parse(bid='com.gaojiezou.rhythm.unexpected')

    def test_missing_identity_field_refused(self):
        with self.assertRaises(RuntimeError): self.parse(self.header().replace('    UUID = ' + UUID + '\n', ''))

    def test_symlink_extension_refused(self):
        target = self.base / 'Other/GaoJieZouWidgets.appex'; target.mkdir(parents=True)
        link = self.base / 'Alias/GaoJieZouWidgets.appex'; link.parent.mkdir(); link.symlink_to(target)
        with self.assertRaises(RuntimeError): self.parse(extension=link)

    def test_before_program_replacement_trap_preserves_formal_inode(self):
        body = re.search(r'finish_install\(\) \{\n(.*?)\n\}\ntrap', SOURCE, re.S).group(0).rsplit('\ntrap', 1)[0]
        formal = self.base / 'Formal.app'; inode = formal.stat().st_ino
        log = self.base / 'commands.log'
        script = '''set -u
ROOT=$1
COMMAND_LOG=$2
UNPACKED=$3
rm() { print -r -- "rm:$*" >> "$COMMAND_LOG"; }
rmdir() { print -r -- "rmdir:$*" >> "$COMMAND_LOG"; }
''' + body + '\nfinish_install 1\n'
        stage = self.base / '.install.noindex'
        for unpacked, expected in ((0, []), (1, [f'rm:-rf {stage / "搞节奏.app"}', f'rmdir:{stage}'])):
            with self.subTest(unpacked=unpacked):
                result = subprocess.run(['/bin/zsh', '-c', script, 'test', str(self.base), str(log), str(unpacked)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(formal.stat().st_ino, inode)
                commands = log.read_text().splitlines() if log.exists() else []
                self.assertEqual(commands, expected)

    def test_replacement_phase_starts_after_precise_unregister(self):
        self.assertIn('set -euo pipefail', SOURCE.splitlines()[:4])
        body = SOURCE.split("trap 'finish_install $?' EXIT", 1)[1]
        unregister = body.index('    unregister_formal_widgets\n')
        unregister_services = body.index('"$LSREGISTER" -u "$TARGET"')
        remove = body.index('rm -rf "$TARGET"')
        copy = body.index('ditto "$SOURCE" "$TARGET"')
        verify = body.index('verify_bundle "$TARGET"', copy)
        register = body.index('\nregister_formal', verify)
        self.assertTrue(unregister < unregister_services < remove < copy < verify < register)


if __name__ == '__main__':
    unittest.main()
