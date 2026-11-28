"""Optional hosted-runner observation of the isolated unsigned application."""

import json
import os
from pathlib import Path
import subprocess
import time


TERMINATOR = '''
import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid),
      let bundleURL = app.bundleURL?.resolvingSymlinksInPath(),
      bundleURL == URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath(),
      app.terminate() else { exit(77) }
'''


def report(text):
    print(text, flush=True)
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with Path(summary).open('a', encoding='utf-8') as file:
            file.write(f'- {text}\n')


def lifecycle(path):
    if not path.is_file():
        return set()
    events = set()
    for line in path.read_text(encoding='utf-8').splitlines():
        try:
            events.add(json.loads(line)['event'])
        except (json.JSONDecodeError, KeyError):
            # The application may still be appending its newest entry.
            continue
    return events


def main():
    if not os.environ.get('RHYTHM_QA_GUI_WORK'):
        report('GUI observation skipped: unsigned verification output is unavailable.')
        return 0
    work = Path(os.environ['RHYTHM_QA_GUI_WORK']).resolve()
    runner = Path(os.environ['RUNNER_TEMP']).resolve()
    assert work.name == 'runtime.noindex' and work.parent.parent == runner
    assert work.parent.name.startswith('rhythm-candidate-gui.')
    bundle = work / '搞节奏.app'
    executable = bundle / 'Contents/MacOS/GaoJieZou'
    if not executable.is_file():
        report('GUI observation skipped: the optional staging copy is unavailable.')
        return 0
    aqua = subprocess.run(['/bin/launchctl', 'print', f'gui/{os.getuid()}'], capture_output=True, timeout=7)
    if aqua.returncode:
        report('GUI observation skipped: this hosted runner has no accessible Aqua session.')
        return 0

    terminator_source = work / 'RequestApplicationTermination.swift'
    terminator_source.write_text(TERMINATOR, encoding='utf-8')
    terminator = work / 'request-application-termination'
    compiled = subprocess.run(['xcrun', 'swiftc', str(terminator_source), '-o', str(terminator)], timeout=90)
    data = work / 'SyntheticData'
    output = work / 'application-output.log'
    lifecycle_log = data / 'Lifecycle/lifecycle.log'
    environment = {**os.environ, 'GAOJIEZOU_DATA_DIR': str(data)}
    required = {'launch', 'window.opened', 'menubar.visible'}
    with output.open('wb') as console:
        app = subprocess.Popen([str(executable)], env=environment, cwd=work, stdout=console, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 38
            while not required <= lifecycle(lifecycle_log) and app.poll() is None and time.monotonic() < deadline:
                time.sleep(0.35)
            observed = lifecycle(lifecycle_log)
            if not required <= observed:
                report('GUI observation incomplete. Missing lifecycle events: ' + ', '.join(sorted(required - observed)))
                print(output.read_text(encoding='utf-8', errors='replace')[-4000:], flush=True)
                return 1
            report('GUI resident startup passed: launch, window.opened and menubar.visible were recorded.')

            if compiled.returncode or app.poll() is not None:
                report('Graceful exit could not be observed with NSRunningApplication on this runner.')
                return 0
            result = subprocess.run([str(terminator), str(app.pid), str(bundle)], timeout=10)
            if result.returncode:
                report('Graceful exit unavailable: this runner could not terminate the owned bundle via NSRunningApplication.')
                return 0
            try:
                app.wait(timeout=12)
            except subprocess.TimeoutExpired:
                report('Graceful exit request did not complete before the timeout.')
                return 0
            if app.returncode == 0 and 'terminate_clean' in lifecycle(lifecycle_log):
                report('GUI resident exit passed: the owned process recorded terminate_clean and returned zero.')
            else:
                report('Graceful exit was requested but a clean lifecycle receipt was unavailable.')
            return 0
        finally:
            if app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    app.kill()
                    app.wait(timeout=4)


if __name__ == '__main__':
    raise SystemExit(main())
