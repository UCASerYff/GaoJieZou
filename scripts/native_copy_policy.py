"""Pure copy-context projection for the frozen native metadata adapter.

Imports only the adjacent vendored pure adapter code. No source/copy file reads, writes, xattr,
SQLite or process calls. The caller pins both code files, validates the original
Root policy and evidence, and supplies raw states from the two exact copy roots.
All change paths returned below remain relative to those copy roots.
"""
import copy
import json
from pathlib import PurePosixPath

import native_metadata_policy as native

METADATA_DATABASES = {('healthGroup', 'Health/health.sqlite'),
                      ('footprintsSupport', 'footprints.sqlite'),
                      ('healthGroup', 'SharedSleep/sleep-records.sqlite')}


class CopyPolicyError(Exception):
    """Public error code only."""


def _need(ok, code):
    if not ok:
        raise CopyPolicyError(code)


def _relative(value):
    _need(isinstance(value, str) and value and '\0' not in value, 'invalid_copy_relative')
    if value == '.':
        return value
    p = PurePosixPath(value)
    _need(not p.is_absolute() and '..' not in p.parts and str(p) == value,
          'invalid_copy_relative')
    return value


def _join(base, relative):
    _relative(base); _relative(relative)
    return relative if base == '.' else base if relative == '.' else base + '/' + relative


def _canonical(value):
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                          allow_nan=False)
    except (ValueError, TypeError):
        raise CopyPolicyError('invalid_copy_policy_value')


def subtree(tree, relative='.'):
    """Extract one flat-inventory subtree without losing directory metadata."""
    _relative(relative)
    _need(isinstance(tree, dict) and tree.get('type') in ('file', 'directory'),
          'invalid_copy_source_tree')
    if tree['type'] == 'file':
        _need(relative == '.', 'file_copy_has_no_descendants')
        return copy.deepcopy(tree)
    entries = tree.get('entries')
    _need(isinstance(entries, dict), 'invalid_copy_source_entries')
    for name, node in entries.items():
        _relative(name)
        _need(name != '.' and isinstance(node, dict) and node.get('type') in ('file', 'directory'),
              'invalid_copy_source_node')
    if relative == '.':
        return copy.deepcopy(tree)
    _need(relative in entries, 'copy_subtree_missing')
    result = copy.deepcopy(entries[relative])
    prefix = relative + '/'
    descendants = {name[len(prefix):]: copy.deepcopy(node)
                   for name, node in entries.items() if name.startswith(prefix)}
    if result['type'] == 'directory':
        _need('entries' not in result, 'nested_source_inventory_refused')
        result['entries'] = descendants
    else:
        _need(not descendants, 'file_copy_has_descendants')
    return result


def copy_context(plan, source_key, source_relative='.'):
    _relative(source_relative)
    _need(isinstance(source_key, str) and source_key and isinstance(plan, dict),
          'invalid_copy_source_key')
    sources = plan.get('sources')
    _need(isinstance(sources, dict) and source_key in sources, 'copy_source_not_in_plan')
    source = sources[source_key]
    _need(isinstance(source, dict) and source.get('explicitlyAbsent') is False and
          isinstance(source.get('tree'), dict), 'copy_source_absent_or_invalid')
    return {'sourceKey': source_key, 'sourceRelative': source_relative,
            'expectedTree': subtree(source['tree'], source_relative)}


def _scoped_policy(context, policy):
    """Translate only the exact-node rule whose original path is in this copy."""
    _need(isinstance(context, dict) and set(context) <=
          {'sourceKey', 'sourceRelative', 'expectedTree', 'metadataOnly'} and
          {'sourceKey', 'sourceRelative', 'expectedTree'} <= set(context) and
          isinstance(context['sourceKey'], str) and context['sourceKey'], 'invalid_copy_context')
    base = _relative(context['sourceRelative'])
    if 'metadataOnly' in context:
        _need(context['metadataOnly'] is True and
              (context['sourceKey'], base) in METADATA_DATABASES and
              context['expectedTree'].get('type') == 'file' and
              context['expectedTree'].get('sha256') == '0' * 64 and
              context['expectedTree'].get('bytes') == 0,
              'invalid_metadata_only_context')
    _need(isinstance(policy, dict) and isinstance(policy.get('transitions'), list),
          'copy_policy_required')
    transitions = policy['transitions']
    _need(all(isinstance(x, dict) and isinstance(x.get('id'), str) for x in transitions),
          'invalid_copy_policy_rules')
    _need(_canonical(sorted(transitions, key=lambda x: x['id'])) ==
          _canonical(sorted(native.expected_transitions(), key=lambda x: x['id'])),
          'unapproved_copy_policy_rules')
    result = copy.deepcopy(policy)
    rules = []
    for rule in result['transitions']:
        scope = rule['scope']
        if scope['kind'] != 'exact_node':
            rules.append(rule)
            continue
        # Never let an unchanged copy-relative rule match an unrelated subtree.
        if scope['itemKey'] != context['sourceKey']:
            continue
        original = _relative(scope['relative'])
        if base == '.':
            local = original
        elif original == base:
            local = '.'
        elif original.startswith(base + '/'):
            local = original[len(base) + 1:]
        else:
            continue
        rule['scope']['relative'] = local
        rules.append(rule)
    result['transitions'] = rules
    return result


def _call_adapter(function, *args):
    try:
        return function(*args)
    except native.PolicyError as error:
        raise CopyPolicyError(str(error))


def project_copy(context, actual_tree, policy, get_states):
    scoped = _scoped_policy(context, policy)
    item = {'key': context['sourceKey'], 'program': False, 'tree': context['expectedTree']}
    return _call_adapter(native.project_archive, item, actual_tree, scoped, get_states)


def verify_copy(context, actual_tree, policy, changes):
    scoped = _scoped_policy(context, policy)
    item = {'key': context['sourceKey'], 'program': False, 'tree': context['expectedTree']}
    return _call_adapter(native.verify_archive, item, actual_tree, scoped, changes)


def metadata_context(context, file_relative='.', source_metadata=None):
    """Metadata-only copyfile check after independent SQLite logical proof.

    source_metadata may be the caller's already verified private-copy metadata;
    passing it does not assert it equals the original source plan. SQL/data bytes
    are intentionally represented by fixed constants on both sides of this
    metadata-only comparison, never used for ordinary copy verification.
    """
    selected = subtree(context['expectedTree'], file_relative)
    _need(selected['type'] == 'file', 'metadata_copy_requires_file_context')
    original_relative = _join(context['sourceRelative'], file_relative)
    _need((context['sourceKey'], original_relative) in METADATA_DATABASES,
          'metadata_copy_not_one_of_three_databases')
    metadata = selected.get('metadata') if source_metadata is None else source_metadata
    _need(isinstance(metadata, dict), 'invalid_metadata_copy_source')
    return {'sourceKey': context['sourceKey'],
            'sourceRelative': original_relative,
            'metadataOnly': True,
            'expectedTree': {'type': 'file', 'sha256': '0' * 64, 'bytes': 0,
                             'metadata': copy.deepcopy(metadata)}}


def project_metadata(context, actual_metadata, policy, get_states):
    _need(context.get('metadataOnly') is True, 'metadata_only_context_required')
    actual = {'type': 'file', 'sha256': '0' * 64, 'bytes': 0,
              'metadata': copy.deepcopy(actual_metadata)}
    return project_copy(context, actual, policy, get_states)


def verify_metadata(context, actual_metadata, policy, changes):
    _need(context.get('metadataOnly') is True, 'metadata_only_context_required')
    actual = {'type': 'file', 'sha256': '0' * 64, 'bytes': 0,
              'metadata': copy.deepcopy(actual_metadata)}
    return verify_copy(context, actual, policy, changes)
