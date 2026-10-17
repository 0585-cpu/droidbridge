"""Exercise recovery/update failures against fake launchd/files, never the host network."""
import os
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest


class RecoveryScriptTests(unittest.TestCase):
    def run_recovery(self, failure):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper_dir = root / 'helpers'
            daemon_dir = root / 'daemons'
            helper_dir.mkdir()
            daemon_dir.mkdir()
            destination = helper_dir / 'io.droidbridge.helper'
            destination.write_text('#!/bin/sh\n# previous helper\nexit 0\n')
            destination.chmod(0o755)
            original = destination.read_bytes()
            plist = daemon_dir / 'io.droidbridge.helper.plist'
            plist.write_bytes(plistlib.dumps({'Label': 'io.droidbridge.helper', 'RunAtLoad': True}))
            old_plist = plist.read_bytes()
            source = root / 'new-helper'
            source.write_text('#!/bin/sh\n# new helper\nexit ' + ('1' if failure == 'recover' else '0') + '\n')
            source.chmod(0o755)
            (root / 'registered').write_text('1')
            mock = root / 'mock'
            mock.write_text('''#!/usr/bin/env python3
import os, pathlib, shutil, sys
r = pathlib.Path(os.environ['RECOVERY_FIXTURE'])
cmd, *args = sys.argv[1:]
with (r / 'events').open('a') as f: f.write(cmd + ' ' + ' '.join(args) + '\\n')
if cmd == 'codesign':
    if '-dv' in args: print('TeamIdentifier=ABCDEFGHIJ')
elif cmd == 'shlock':
    pathlib.Path(args[args.index('-f') + 1]).write_text('fixture lock')
elif cmd == 'install':
    shutil.copy2(args[-2], args[-1])
elif cmd == 'launchctl':
    state = r / 'registered'
    if args[0] == 'print': sys.exit(0 if state.read_text() == '1' else 1)
    if args[0] == 'bootout': state.write_text('0')
    if args[0] == 'bootstrap':
        state.write_text('1')
        marker = r / 'bootstrap-failed'
        if os.environ['RECOVERY_FAILURE'] == 'bootstrap' and not marker.exists():
            marker.touch(); sys.exit(1)
''')
            mock.chmod(0o755)
            script = Path(__file__).resolve().parents[2] / 'scripts/recover-macos-network.sh'
            text = script.read_text()
            text = text.replace('"$EUID" -ne 0', '1 -ne 1')
            text = text.replace('/Library/PrivilegedHelperTools', str(helper_dir))
            text = text.replace('/Library/LaunchDaemons', str(daemon_dir))
            for command in ('codesign', 'shlock', 'install'):
                text = text.replace('/usr/bin/' + command, f'"{mock}" {command}')
            text = text.replace('/bin/launchctl', f'"{mock}" launchctl')
            fixture_script = root / 'recover.sh'
            fixture_script.write_text(text)
            env = dict(os.environ, RECOVERY_FIXTURE=str(root), RECOVERY_FAILURE=failure)
            result = subprocess.run(['/bin/bash', str(fixture_script), str(source)],
                                    capture_output=True, text=True, env=env, timeout=10)
            self.assertEqual('1', (root / 'registered').read_text(), result.stderr)
            self.assertFalse((helper_dir / '.io.droidbridge.operation.lock').exists())
            self.assertFalse(list(helper_dir.glob('.io.droidbridge.recovery-helper.*')))
            self.assertFalse(list(daemon_dir.glob('.io.droidbridge.recovery-plist.*')))
            if failure:
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(original, destination.read_bytes())
                self.assertEqual(old_plist, plist.read_bytes())
            else:
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(source.read_bytes(), destination.read_bytes())
                self.assertEqual({"SuccessfulExit": False}, plistlib.loads(plist.read_bytes()).get("KeepAlive"))
                self.assertEqual(original, destination.with_suffix('.helper.previous').read_bytes())

    def test_success_installs_helper_and_leaves_tunnel_stopped(self):
        self.run_recovery('')

    def test_recovery_failure_restarts_existing_helper(self):
        self.run_recovery('recover')

    def test_partial_bootstrap_failure_restores_previous_helper(self):
        self.run_recovery('bootstrap')


if __name__ == '__main__':
    unittest.main()
