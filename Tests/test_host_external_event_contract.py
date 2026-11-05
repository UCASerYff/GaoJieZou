#!/usr/bin/env python3
"""Read-only source regression for URL scene reuse; not UI acceptance.

No Swift compilation, application launch, registry query, or user-data access.
The negative control recreates the two relevant parts of the old 9a42 shape
in memory: no View preference, followed by reopening main from onOpenURL.
"""
from pathlib import Path
import re
import sys
import unittest

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]


def swift_masks(source):
    """Keep offsets while masking comments, then comments and string literals."""
    comments = list(source)
    code = list(source)

    def blank(target, start, end):
        for index in range(start, end):
            if target[index] != '\n':
                target[index] = ' '

    index = 0
    while index < len(source):
        start = index
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
            blank(comments, start, index)
            blank(code, start, index)
        elif source.startswith('/*', index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith('/*', index):
                    depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError('Unterminated Swift comment')
            blank(comments, start, index)
            blank(code, start, index)
        elif source[index] == '"':
            delimiter = '"""' if source.startswith('"""', index) else '"'
            index += len(delimiter)
            while index < len(source):
                if source[index] == '\\':
                    index += 2
                elif source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                else:
                    index += 1
            else:
                raise ValueError('Unterminated Swift string')
            blank(code, start, index)
        else:
            index += 1
    return ''.join(comments), ''.join(code)


def swift_block(source, pattern):
    """Return a declaration/closure body and its original half-open offsets."""
    _, code = swift_masks(source)
    match = re.search(pattern, code)
    if match is None:
        raise ValueError('Missing Swift block: ' + pattern)
    opening = code.find('{', match.end())
    if opening < 0:
        raise ValueError('Missing opening brace')
    depth = 1
    for end in range(opening + 1, len(code)):
        if code[end] == '{':
            depth += 1
        elif code[end] == '}':
            depth -= 1
            if depth == 0:
                return source[opening + 1:end], opening + 1, end
    raise ValueError('Unterminated Swift block')


VIEW_POLICY = re.compile(
    r'\.handlesExternalEvents\s*\(\s*preferring\s*:\s*\[\s*"\*"\s*\]'
    r'\s*,\s*allowing\s*:\s*\[\s*"\*"\s*\]\s*\)')
SCENE_POLICY = re.compile(
    r'\.handlesExternalEvents\s*\(\s*matching\s*:\s*\[\s*"\*"\s*\]\s*\)')


def root_modifier(body, pattern):
    comments, code = swift_masks(body)
    return any(code[:match.start()].count('{') == code[:match.start()].count('}')
               for match in pattern.finditer(comments))


def contract_violations(host, resident):
    """Check the production boundary that let one scene foreground another."""
    errors = set()
    main, _, _ = swift_block(host, r'\bstruct\s+MainWindowContent\s*:\s*View\b')
    view, _, _ = swift_block(main, r'\bvar\s+body\s*:\s*some\s+View\b')
    app, _, _ = swift_block(host, r'\bstruct\s+StandaloneApp\s*:\s*App\b')
    scene, _, _ = swift_block(app, r'\bvar\s+body\s*:\s*some\s+Scene\b')
    receiver, _, _ = swift_block(view, r'\.onOpenURL\b')
    delegate, _, _ = swift_block(host, r'\bclass\s+AppDelegate\b')
    counter, _, _ = swift_block(delegate, r'\bfunc\s+nextIntegratedRouteRevision\s*\(')
    show, _, _ = swift_block(main, r'\bfunc\s+showMainWindow\s*\(')
    reopen, _, _ = swift_block(delegate, r'\bfunc\s+applicationShouldHandleReopen\s*\(')
    menu, _, _ = swift_block(resident, r'\bstruct\s+ResidentMenuContent\s*:\s*View\b')
    _, receiving_code = swift_masks(receiver)
    _, main_code = swift_masks(main)
    _, host_code = swift_masks(host)
    _, counter_code = swift_masks(counter)

    if not root_modifier(view, VIEW_POLICY):
        errors.add('existing-scene-view-preference-missing')
    if not root_modifier(scene, SCENE_POLICY):
        errors.add('cold-open-scene-matching-missing')
    parameter = re.match(r'\s*(\w+)\s+in\b', receiving_code)
    if parameter is None or not re.search(
            r'\broute\s*=\s*integratedURL\s*\(\s*' + re.escape(parameter[1]) + r'\s*\)',
            receiving_code):
        errors.add('incoming-url-not-normalized')
    if not re.search(r'\brevision\s*=\s*delegate\.nextIntegratedRouteRevision\s*\(\s*\)', receiving_code):
        errors.add('incoming-url-not-using-process-revision')
    if re.search(r'\b(?:showMainWindow|openWindow)\s*\(|\bStandaloneApp\s*\.\s*activate\s*\('
                 r'|\b(?:NSApp|NSApplication\.shared)\s*\.\s*windows\b'
                 r'|\bmakeKeyAndOrderFront\s*\(', receiving_code):
        errors.add('incoming-url-reopens-or-selects-another-window')
    if not (re.search(r'@State\s+private\s+var\s+route\s*:\s*URL\s*\?', main_code)
            and re.search(r'@State\s+private\s+var\s+revision\s*=\s*0\b', main_code)):
        errors.add('scene-local-route-state-missing')
    if not (re.search(r'private\s+var\s+integratedRouteRevision\s*=\s*0\b', delegate)
            and len(re.findall(r'\bintegratedRouteRevision\s*=\s*0\b', host_code)) == 1
            and re.search(r'\bintegratedRouteRevision\s*&\+=\s*1\b', counter_code)
            and re.search(r'\breturn\s+integratedRouteRevision\b', counter_code)
            and 'integratedRouteRevision' not in main_code):
        errors.add('process-route-counter-reset-or-missing')

    # Manual menu/Dock/resident presentation is intentionally independent of URL reception.
    scene_comments, _ = swift_masks(scene)
    show_comments, _ = swift_masks(show)
    menu_comments, _ = swift_masks(menu)
    if not re.search(r'delegate\.showMainWindow\?\s*\(\s*\)', scene_comments):
        errors.add('command-menu-show-entry-missing')
    if not (re.search(r'openWindow\s*\(\s*id:\s*"main"\s*,\s*value:\s*"main"\s*\)', show_comments)
            and re.search(r'delegate\.showMainWindow\s*=\s*showMainWindow', main_code)
            and re.search(r'\bshowMainWindow\?\s*\(\s*\)', reopen)):
        errors.add('manual-or-dock-show-entry-missing')
    if not (re.search(r'openWindow\s*\(\s*id:\s*"main"\s*,\s*value:\s*"main"\s*\)', menu_comments)
            and re.search(r'StandaloneApp\.activate\s*\(\s*\)', menu_comments)):
        errors.add('resident-show-entry-missing')
    return errors


class HostExternalEventContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = (REPO / 'Host/AppMain.swift').read_text()
        cls.resident = (REPO / 'Host/ResidentAppController.swift').read_text()

    def test_production_scene_reuse_contract(self):
        self.assertEqual(contract_violations(self.host, self.resident), set())

    def test_original_9a42_shape_exposes_both_defects(self):
        # Only memory is changed; no old application/archive is opened or launched.
        old = VIEW_POLICY.sub('', self.host)
        _, start, end = swift_block(old, r'\.onOpenURL\b')
        old = old[:start] + ''' url in
                route = integratedURL(url)
                revision = delegate.nextIntegratedRouteRevision()
                showMainWindow()
            ''' + old[end:]
        errors = contract_violations(old, self.resident)
        self.assertEqual(errors, {'existing-scene-view-preference-missing',
                                  'incoming-url-reopens-or-selects-another-window'})

    def test_comment_cannot_supply_view_preference(self):
        decoy = VIEW_POLICY.sub('', self.host).replace(
            '.onOpenURL', '// .handlesExternalEvents(preferring: ["*"], allowing: ["*"])\n            .onOpenURL', 1)
        self.assertIn('existing-scene-view-preference-missing', contract_violations(decoy, self.resident))

    def test_each_old_foreground_path_is_rejected_inside_receiver(self):
        _, start, end = swift_block(self.host, r'\.onOpenURL\b')
        for call in ('showMainWindow()', 'openWindow(id: "main", value: "main")',
                     'StandaloneApp.activate()', 'NSApp.windows.first { _ in true }'):
            with self.subTest(call=call):
                mutated = self.host[:end] + '\n' + call + '\n' + self.host[end:]
                self.assertIn('incoming-url-reopens-or-selects-another-window',
                              contract_violations(mutated, self.resident))

    def test_scene_must_not_reset_process_counter(self):
        _, _, end = swift_block(self.host, r'\.onOpenURL\b')
        mutated = self.host[:end] + '\n delegate.integratedRouteRevision = 0\n' + self.host[end:]
        self.assertIn('process-route-counter-reset-or-missing', contract_violations(mutated, self.resident))


if __name__ == '__main__':
    unittest.main()
