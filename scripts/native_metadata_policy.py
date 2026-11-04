# Adapted pure adapter from native_metadata_policy_20261104.py.
# Upstream SHA-256: c4e15dace3840e7cad19ae9f3a3993aaadb7b7ee944238eb9b5e82102e338bd2
# Approval identity validation is generic; callers may bind an expected reviewer.
"""Pure-data adapter for Root's three exact native metadata transitions.

No filesystem, process, xattr, UI or copy operations. Call validate_policy before
using an external policy. The source tree is never changed. Raw-to-restored must
be checked strictly by the caller, without this source-to-native projection.
"""
import base64
import copy
import hashlib
import json
from pathlib import PurePosixPath
import re

_HEX = re.compile(r'[0-9a-f]{64}\Z')
_APPROVER = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.:@-]{0,127}\Z')
_PROVENANCE_SOURCE = 'a1db8481a6bb3102388bb498ba35c47187fc3763791da305607c2a17e1d9e183'
_PROVENANCE_NATIVE = 'f2caee8421af8ddb46a313f613280cc9cca039ede4cdc231a562c77ec1654cd1'
_QUARANTINE_SOURCE = 'e561ed109b4a27633b570b3d6d178abc7752472e647a1357782129585a9445d2'
_QUARANTINE_NATIVE = 'c8e8c26b2c20be4ee91e8a3e4939a517bd7de4f2f5ad02b63d41c821c239e58c'


class PolicyError(Exception):
    """Public error codes only; never include private paths or raw values."""


def _need(ok, code):
    if not ok:
        raise PolicyError(code)


def _canonical(value):
    try:
        return json.dumps(value, sort_keys=True, separators=(',', ':'),
                          ensure_ascii=False, allow_nan=False).encode('utf-8')
    except (TypeError, ValueError):
        raise PolicyError('noncanonical_metadata_value')


def _equal(left, right):
    return _canonical(left) == _canonical(right)


def expected_transitions():
    """Fresh rule objects; only these three are accepted in production policy."""
    native = {'present': True, 'length': 11, 'sha256': _PROVENANCE_NATIVE}
    return [
        {'id': 'provenance-present', 'attribute': 'com.apple.provenance',
         'scope': {'kind': 'frozen_plan_nodes'},
         'source': {'present': True, 'length': 11, 'sha256': _PROVENANCE_SOURCE},
         'native': copy.deepcopy(native)},
        {'id': 'provenance-absent', 'attribute': 'com.apple.provenance',
         'scope': {'kind': 'frozen_plan_nodes'},
         'source': {'present': False, 'length': 0, 'sha256': None},
         'native': copy.deepcopy(native)},
        {'id': 'footprints-diagnostics-quarantine', 'attribute': 'com.apple.quarantine',
         'scope': {'kind': 'exact_node', 'itemKey': 'footprintsGroup',
                   'relative': 'widget-diagnostics', 'nodeType': 'directory'},
         'source': {'present': True, 'length': 29, 'sha256': _QUARANTINE_SOURCE},
         'native': {'present': True, 'length': 15, 'sha256': _QUARANTINE_NATIVE}},
    ]


def validate_policy(value, plan_sha, expected_approver=None):
    """Validate explicit policy; callers bind reviewer and evidence separately.

    Existing reviewer identifiers are preserved verbatim. This field describes
    the reviewer; authorization is established by the caller's review protocol.
    """
    _need(isinstance(value, dict), 'invalid_native_metadata_policy')
    required = {'schemaVersion', 'kind', 'authority', 'approvedBy', 'planSHA256',
                'diagnosticEvidence', 'transitions'}
    _need(required <= set(value) and set(value) <= required | {'approvedAt', 'notes'},
          'invalid_native_metadata_policy_fields')
    approver = value.get('approvedBy')
    _need(isinstance(approver, str) and _APPROVER.fullmatch(approver) is not None,
          'invalid_native_metadata_approver')
    if expected_approver is not None:
        _need(isinstance(expected_approver, str) and _APPROVER.fullmatch(expected_approver) is not None and
              approver == expected_approver, 'native_metadata_approver_mismatch')
    _need(type(value.get('schemaVersion')) is int and value['schemaVersion'] == 1 and
          value.get('kind') == 'RootExactNativeMetadataPolicy' and
          value.get('authority') == 'RootMaintenanceDecision' and
          isinstance(plan_sha, str) and
          _HEX.fullmatch(plan_sha) and value.get('planSHA256') == plan_sha,
          'native_metadata_policy_not_bound')
    evidence = value.get('diagnosticEvidence')
    _need(isinstance(evidence, list) and evidence, 'native_metadata_evidence_required')
    paths = []
    for item in evidence:
        _need(isinstance(item, dict) and set(item) == {'path', 'sha256'},
              'invalid_native_metadata_evidence')
        path, digest = item['path'], item['sha256']
        _need(isinstance(path, str) and path.startswith('/') and '\0' not in path and
              '..' not in PurePosixPath(path).parts and isinstance(digest, str) and
              _HEX.fullmatch(digest), 'invalid_native_metadata_evidence')
        paths.append(path)
    _need(len(set(paths)) == len(paths) and any(PurePosixPath(p).name ==
          'Root-actual-copy-difference-leaves.json' for p in paths),
          'original_native_diagnostic_required')
    rules = value.get('transitions')
    _need(isinstance(rules, list) and len(rules) == 3 and
          all(isinstance(r, dict) and isinstance(r.get('id'), str) for r in rules),
          'invalid_exact_native_metadata_transitions')
    _need(_equal(sorted(rules, key=lambda r: r['id']),
                 sorted(expected_transitions(), key=lambda r: r['id'])),
          'unapproved_native_metadata_transition')
    for key in ('approvedAt', 'notes'):
        if key in value:
            _need(isinstance(value[key], str), 'invalid_native_metadata_policy_note')
    return copy.deepcopy(value)


def _relative(relative, root_allowed=True):
    _need(isinstance(relative, str) and relative and '\0' not in relative,
          'invalid_inventory_relative_path')
    if root_allowed and relative == '.':
        return
    path = PurePosixPath(relative)
    _need(not path.is_absolute() and '..' not in path.parts and
          relative != '.' and str(path) == relative, 'invalid_inventory_relative_path')


def _nodes(tree, program):
    _need(isinstance(tree, dict), 'invalid_inventory_tree')
    if program:
        _need('.' in tree, 'program_inventory_root_missing')
        result = tree
    else:
        _need(tree.get('type') in ('file', 'directory'), 'invalid_data_inventory_type')
        result = {'.': tree}
        if tree['type'] == 'directory':
            entries = tree.get('entries')
            _need(isinstance(entries, dict) and '.' not in entries, 'invalid_inventory_entries')
            result = {'.': tree, **entries}
    for relative, node in result.items():
        _relative(relative)
        allowed = ('file', 'directory', 'symlink') if program else ('file', 'directory')
        _need(isinstance(node, dict) and node.get('type') in allowed, 'invalid_inventory_node')
    return result


def _metadata(node):
    metadata = node if node['type'] == 'symlink' else node.get('metadata')
    _need(isinstance(metadata, dict) and isinstance(metadata.get('xattrs'), dict),
          'invalid_inventory_xattrs')
    _need(all(isinstance(k, str) and k and isinstance(v, str) and _HEX.fullmatch(v)
              for k, v in metadata['xattrs'].items()), 'invalid_inventory_xattr_digest')
    return metadata


def _raw_state(value):
    _need(isinstance(value, dict) and set(value) == {'present', 'length', 'sha256', 'rawBase64'},
          'invalid_raw_metadata_state')
    _need(type(value['present']) is bool and type(value['length']) is int and value['length'] >= 0,
          'invalid_raw_metadata_state')
    if not value['present']:
        _need(value['length'] == 0 and value['sha256'] is None and value['rawBase64'] is None,
              'absent_metadata_is_not_empty_bytes')
    else:
        _need(isinstance(value['sha256'], str) and _HEX.fullmatch(value['sha256']) and
              isinstance(value['rawBase64'], str), 'invalid_raw_metadata_state')
        try:
            raw = base64.b64decode(value['rawBase64'], validate=True)
        except (ValueError, TypeError):
            raise PolicyError('invalid_raw_metadata_base64')
        _need(base64.b64encode(raw).decode('ascii') == value['rawBase64'] and
              len(raw) == value['length'] and hashlib.sha256(raw).hexdigest() == value['sha256'],
              'raw_metadata_bytes_do_not_match_digest')
    return copy.deepcopy(value)


def _signature(state):
    return {k: state[k] for k in ('present', 'length', 'sha256')}


def _state_matches_inventory(state, xattrs, name):
    return state['present'] == (name in xattrs) and state['sha256'] == xattrs.get(name)


def _scope_matches(scope, key, relative, node_type):
    if scope == {'kind': 'frozen_plan_nodes'}:
        return True  # Caller iterates only the bound original inventory nodes.
    return scope == {'kind': 'exact_node', 'itemKey': key, 'relative': relative,
                     'nodeType': node_type}


def project_archive(item, actual_tree, policy, get_states):
    """Compare source->native; get_states reads or supplies exact original/raw bytes.

    get_states(relative, attribute) returns (source_state, native_state), each
    including rawBase64. No state callback is used when the trees are exact.
    This pure comparator deliberately accepts synthetic rule fixtures in tests;
    the production boundary MUST call validate_policy before passing a policy.
    """
    _need(isinstance(item, dict) and isinstance(item.get('key'), str) and
          type(item.get('program')) is bool and 'tree' in item, 'invalid_inventory_item')
    expected = copy.deepcopy(item['tree'])
    original_nodes = _nodes(expected, item['program'])
    actual_nodes = _nodes(actual_tree, item['program'])
    _need(set(original_nodes) == set(actual_nodes), 'native_inventory_node_set_changed')
    transitions = [] if policy is None else policy.get('transitions', [])
    _need(isinstance(transitions, list), 'invalid_exact_native_metadata_transitions')
    changes = []
    for relative in sorted(original_nodes):
        original_node, actual_node = original_nodes[relative], actual_nodes[relative]
        _need(original_node['type'] == actual_node['type'], 'native_inventory_node_type_changed')
        source_xattrs = _metadata(original_node)['xattrs']
        native_xattrs = _metadata(actual_node)['xattrs']
        for name in sorted(set(source_xattrs) | set(native_xattrs)):
            if source_xattrs.get(name) == native_xattrs.get(name):
                continue
            candidates = [rule for rule in transitions if isinstance(rule, dict) and
                          rule.get('attribute') == name and _scope_matches(rule.get('scope'),
                          item['key'], relative, original_node['type'])]
            _need(candidates, 'unapproved_native_xattr_difference')
            states = get_states(relative, name)
            _need(isinstance(states, (tuple, list)) and len(states) == 2, 'raw_metadata_pair_required')
            source_state, native_state = map(_raw_state, states)
            _need(_state_matches_inventory(source_state, source_xattrs, name) and
                  _state_matches_inventory(native_state, native_xattrs, name),
                  'raw_metadata_state_inventory_mismatch')
            rules = [rule for rule in candidates if _equal(rule.get('source'), _signature(source_state))
                     and _equal(rule.get('native'), _signature(native_state))]
            _need(len(rules) == 1, 'native_metadata_pair_not_uniquely_approved')
            rule = rules[0]
            _need(isinstance(rule.get('id'), str) and rule['id'], 'native_metadata_rule_id_missing')
            if native_state['present']:
                source_xattrs[name] = native_state['sha256']
            else:
                del source_xattrs[name]
            changes.append({'relative': relative, 'nodeType': original_node['type'],
                            'attribute': name, 'ruleID': rule['id'],
                            'source': source_state, 'native': native_state})
    _need(_equal(expected, actual_tree), 'unapproved_native_nonxattr_difference')
    return {'archiveTree': expected, 'changes': changes}


def verify_archive(item, actual_tree, policy, changes):
    """Re-derive projection using escrow; reject missing, extra or forged entries."""
    _need(isinstance(changes, list), 'invalid_native_metadata_escrow')
    fields = {'relative', 'nodeType', 'attribute', 'ruleID', 'source', 'native'}
    entries = {}
    for change in changes:
        _need(isinstance(change, dict) and set(change) == fields and
              isinstance(change.get('attribute'), str), 'invalid_native_metadata_escrow')
        _relative(change['relative'])
        key = (change['relative'], change['attribute'])
        _need(key not in entries, 'duplicate_native_metadata_escrow_entry')
        entries[key] = change
    used = set()
    def states(relative, attribute):
        key = (relative, attribute)
        _need(key in entries, 'native_metadata_escrow_entry_missing')
        used.add(key)
        return entries[key]['source'], entries[key]['native']
    result = project_archive(item, actual_tree, policy, states)
    _need(used == set(entries), 'unused_native_metadata_escrow_entry')
    for change in result['changes']:
        _need(_equal(change, entries[(change['relative'], change['attribute'])]),
              'native_metadata_escrow_does_not_match_projection')
    return result
