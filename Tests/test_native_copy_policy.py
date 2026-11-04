#!/usr/bin/env python3
"""Pure synthetic fixtures only. No sources, xattrs, SQL, copies or apply."""
import base64
import copy
import hashlib
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import native_copy_policy as p
rules = p.native.expected_transitions()
policy = {'transitions': rules}
checks = 0


def state(raw):
    return {'present': raw is not None, 'length': len(raw) if raw is not None else 0,
            'sha256': hashlib.sha256(raw).hexdigest() if raw is not None else None,
            'rawBase64': base64.b64encode(raw).decode() if raw is not None else None}


def synthetic_policy():
    # Keep the frozen rules in production. Substitute only native module rule
    # factory within this fixture so test bytes can prove escrow integrity.
    adapted = copy.deepcopy(rules)
    adapted[0]['source'] = {k: state(b'source')[k] for k in ('present','length','sha256')}
    adapted[0]['native'] = {k: state(b'native')[k] for k in ('present','length','sha256')}
    adapted[1]['native'] = copy.deepcopy(adapted[0]['native'])
    adapted[2]['source'] = {k: state(b'quarantine-source')[k] for k in ('present','length','sha256')}
    adapted[2]['native'] = {k: state(b'quarantine-native')[k] for k in ('present','length','sha256')}
    return adapted


# Validate reviewer binding with fixed production rule digests and synthetic
# identities. This fixture never contains a private policy or original raw data.
validation = {'schemaVersion': 1, 'kind': 'RootExactNativeMetadataPolicy',
              'authority': 'RootMaintenanceDecision', 'approvedBy': 'fixture-reviewer',
              'planSHA256': '1' * 64, 'diagnosticEvidence': [
                  {'path': '/fixture/Root-actual-copy-difference-leaves.json', 'sha256': '2' * 64}],
              'transitions': copy.deepcopy(rules)}
assert p.native.validate_policy(validation, '1' * 64, 'fixture-reviewer') == validation
checks += 1
try: p.native.validate_policy(validation, '1' * 64, 'different-reviewer')
except p.native.PolicyError: pass
else: raise AssertionError('mismatched expected reviewer accepted')
checks += 1
legacy = copy.deepcopy(validation)
legacy['approvedBy'] = '11111111-2222-4333-8444-555555555555'
legacy_bytes = p.native._canonical(legacy)
assert p.native.validate_policy(legacy, '1' * 64) == legacy
assert p.native.validate_policy(legacy, '1' * 64, legacy['approvedBy']) == legacy
assert p.native._canonical(legacy) == legacy_bytes
checks += 1
for invalid in ('', ' reviewer', 'reviewer name', '../reviewer', 'reviewer\0', 'a' * 129):
    bad = dict(validation, approvedBy=invalid)
    try: p.native.validate_policy(bad, '1' * 64)
    except p.native.PolicyError: pass
    else: raise AssertionError('invalid reviewer identifier accepted')
    checks += 1
bad = copy.deepcopy(validation); bad['transitions'][2]['native']['sha256'] = '3' * 64
try: p.native.validate_policy(bad, '1' * 64)
except p.native.PolicyError: pass
else: raise AssertionError('production transition digest changed')
checks += 1

# Exercise quarantine projection only with synthetic rule bytes. The production
# factory is restored afterwards, and its fixed rule set must remain unchanged.
original_factory = p.native.expected_transitions
fixture_rules = synthetic_policy()
p.native.expected_transitions = lambda: copy.deepcopy(fixture_rules)
policy = {'transitions': fixture_rules}
real_source = b'quarantine-source'
real_native = b'quarantine-native'
assert {k: state(real_source)[k] for k in ('present','length','sha256')} == fixture_rules[2]['source']
assert {k: state(real_native)[k] for k in ('present','length','sha256')} == fixture_rules[2]['native']
real_metadata = {'xattrs': {'com.apple.quarantine': state(real_source)['sha256']}, 'mode': 448}
real_context = {'sourceKey':'footprintsGroup', 'sourceRelative':'widget-diagnostics',
                'expectedTree':{'type':'directory','metadata':real_metadata,'entries':{}}}
real_actual = copy.deepcopy(real_context['expectedTree'])
real_actual['metadata']['xattrs']['com.apple.quarantine'] = state(real_native)['sha256']
real_result = p.project_copy(real_context, real_actual, policy,
                            lambda *_: (state(real_source),state(real_native)))
assert p.verify_copy(real_context, real_actual, policy, real_result['changes']) == real_result
checks += 1

pv = 'com.apple.provenance'; q = 'com.apple.quarantine'
meta = {'mode': 448, 'mtimeNs': 123456789, 'uid': 501, 'gid': 20,
        'bsdFlags': 0, 'aclSHA256': 'unchanged', 'xattrs': {pv: state(b'source')['sha256']}}
node = {'type': 'file', 'sha256': 'unchanged-file-bytes', 'bytes': 42, 'metadata': copy.deepcopy(meta)}
directory = {'type': 'directory', 'metadata': copy.deepcopy(meta)}
tree = {'type': 'directory', 'metadata': copy.deepcopy(meta), 'entries': {
    'Health': copy.deepcopy(directory), 'Health/health.sqlite': copy.deepcopy(node),
    'Health/empty': copy.deepcopy(directory), 'SharedSleep': copy.deepcopy(directory),
    'SharedSleep/sleep-records.sqlite': copy.deepcopy(node),
    'widget-diagnostics': copy.deepcopy(directory),
    'nested': copy.deepcopy(directory), 'nested/widget-diagnostics': copy.deepcopy(directory)}}
plan = {'sources': {'healthGroup': {'explicitlyAbsent': False, 'tree': tree},
                    'footprintsGroup': {'explicitlyAbsent': False, 'tree': tree}}}
original = copy.deepcopy(plan)


def rejected(fn):
    global checks
    try: fn()
    except p.CopyPolicyError: pass
    else: raise AssertionError('invalid fixture was accepted')
    checks += 1


context = p.copy_context(plan, 'healthGroup', 'Health')
assert set(context['expectedTree']['entries']) == {'health.sqlite', 'empty'}
assert context['expectedTree']['metadata'] == tree['entries']['Health']['metadata']
assert p.subtree(tree, 'SharedSleep/sleep-records.sqlite') == node
checks += 2
for relative in ('../Health', '/Health', 'Health//empty', ''):
    rejected(lambda relative=relative: p.copy_context(plan, 'healthGroup', relative))
rejected(lambda: p.copy_context(plan, 'missing'))
rejected(lambda: p.copy_context({'sources': {'healthGroup': {'explicitlyAbsent': True}}}, 'healthGroup'))

actual = copy.deepcopy(context['expectedTree'])
actual['entries']['health.sqlite']['metadata']['xattrs'][pv] = state(b'native')['sha256']
result = p.project_copy(context, actual, policy, lambda *_: (state(b'source'), state(b'native')))
assert result['archiveTree'] == actual and plan == original
assert result['changes'][0]['relative'] == 'health.sqlite'
assert p.verify_copy(context, actual, policy, result['changes']) == result
checks += 2
absent_context = copy.deepcopy(context)
absent_context['expectedTree']['metadata']['xattrs'] = {}
absent_actual = copy.deepcopy(absent_context['expectedTree'])
absent_actual['metadata']['xattrs'][pv] = state(b'native')['sha256']
assert p.project_copy(absent_context, absent_actual, policy, lambda *_: (state(None), state(b'native')))['changes']
checks += 1
for mutation in ('mtime', 'content', 'node-set', 'unknown-xattr'):
    bad = copy.deepcopy(actual)
    if mutation == 'mtime': bad['metadata']['mtimeNs'] += 1
    elif mutation == 'content': bad['entries']['health.sqlite']['sha256'] = 'different'
    elif mutation == 'node-set': bad['entries']['new'] = copy.deepcopy(node)
    else: bad['metadata']['xattrs']['unknown'] = '0' * 64
    rejected(lambda bad=bad: p.project_copy(context, bad, policy, lambda *_: (state(b'source'), state(b'native'))))
for mutation in ('missing', 'extra', 'forged'):
    escrow = copy.deepcopy(result['changes'])
    if mutation == 'missing': escrow = []
    elif mutation == 'extra': escrow.append(dict(escrow[0], relative='empty'))
    else: escrow[0]['native']['rawBase64'] = base64.b64encode(b'forged').decode()
    rejected(lambda escrow=escrow: p.verify_copy(context, actual, policy, escrow))

# Exact original quarantine directory remains valid when copied as its own root.
q_context = p.copy_context(plan, 'footprintsGroup', 'widget-diagnostics')
q_context['expectedTree']['metadata']['xattrs'][q] = state(b'quarantine-source')['sha256']
q_actual = copy.deepcopy(q_context['expectedTree'])
q_actual['metadata']['xattrs'][q] = state(b'quarantine-native')['sha256']
q_result = p.project_copy(q_context, q_actual, policy,
                          lambda *_: (state(b'quarantine-source'), state(b'quarantine-native')))
assert q_result['changes'][0]['relative'] == '.'
assert p.verify_copy(q_context, q_actual, policy, q_result['changes']) == q_result
checks += 1
for key, relative in (('healthGroup','widget-diagnostics'),
                       ('footprintsGroup','nested'), ('footprintsGroup','nested/widget-diagnostics')):
    ctx = p.copy_context(plan, key, relative)
    local = 'widget-diagnostics' if relative == 'nested' else '.'
    src_meta = ctx['expectedTree']['metadata'] if local == '.' else ctx['expectedTree']['entries'][local]['metadata']
    src_meta['xattrs'][q] = state(b'quarantine-source')['sha256']
    bad = copy.deepcopy(ctx['expectedTree'])
    dst_meta = bad['metadata'] if local == '.' else bad['entries'][local]['metadata']
    dst_meta['xattrs'][q] = state(b'quarantine-native')['sha256']
    rejected(lambda ctx=ctx,bad=bad: p.project_copy(ctx, bad, policy,
             lambda *_: (state(b'quarantine-source'), state(b'quarantine-native'))))

metadata = p.metadata_context(context, 'health.sqlite')
assert metadata['sourceRelative'] == 'Health/health.sqlite'
dst = copy.deepcopy(meta); dst['xattrs'][pv] = state(b'native')['sha256']
m = p.project_metadata(metadata, dst, policy, lambda *_: (state(b'source'), state(b'native')))
assert p.verify_metadata(metadata, dst, policy, m['changes']) == m
assert m['archiveTree']['sha256'] == '0' * 64 and m['archiveTree']['bytes'] == 0
checks += 1
bad = copy.deepcopy(dst); bad['mode'] = 511
rejected(lambda: p.project_metadata(metadata, bad, policy, lambda *_: (state(b'source'), state(b'native'))))
rejected(lambda: p.metadata_context(context, 'empty'))
unknown = copy.deepcopy(context)
unknown['expectedTree']['entries']['another.sqlite'] = copy.deepcopy(node)
rejected(lambda: p.metadata_context(unknown, 'another.sqlite'))
rejected(lambda: p.project_metadata(dict(metadata, sourceRelative='Health/another.sqlite'),
                                   dst, policy, lambda *_: (state(b'source'), state(b'native'))))
bad_policy = copy.deepcopy(policy); bad_policy['transitions'][2]['scope']['relative'] = 'nested/widget-diagnostics'
rejected(lambda: p.project_copy(context, actual, bad_policy, lambda *_: (state(b'source'), state(b'native'))))
p.native.expected_transitions = original_factory
assert p.native.expected_transitions() == rules
print('PASS: %d pure fixtures; no live sources, xattrs, SQL, copy or apply' % checks)
