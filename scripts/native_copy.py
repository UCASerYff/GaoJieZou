"""Opt-in, plan-bound native copy verification; never writes source metadata.

Only the three explicit Root rules are accepted. Inventories and source CAS stay
strict. Escrow belongs to each source archive; component move events are append
only, leaving receipt.components at its original prepared inventory.
"""
import base64
import copy
import ctypes
import errno
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

import native_copy_policy as policy_api

OWNERS = {'healthGroup': 'Health', 'healthSupport': 'Health', 'healthRestore': 'Health',
          'healthPreferences': 'Health', 'footprintsSupport': 'Footprints',
          'footprintsGroup': 'Footprints', 'footprintsRestore': 'Footprints',
          'footprintsPreferences': 'Footprints', 'rhythmLibrary': 'Rhythm'}
ARCHIVES = {'healthGroup': 'SourceArchives/Health/AppGroup',
            'healthSupport': 'SourceArchives/Health/ApplicationSupport',
            'healthRestore': 'SourceArchives/Health/PendingRestore',
            'healthPreferences': 'SourceArchives/Health/Preferences.plist',
            'footprintsSupport': 'SourceArchives/Footprints/ApplicationSupport',
            'footprintsGroup': 'SourceArchives/Footprints/AppGroup',
            'footprintsRestore': 'SourceArchives/Footprints/PendingRestore',
            'footprintsPreferences': 'SourceArchives/Footprints/Preferences.plist',
            'rhythmLibrary': 'SourceArchives/Rhythm/library.json'}
DBS = {'Modules/Health/health.sqlite': ('healthGroup', 'Health/health.sqlite'),
       'Modules/Footprints/footprints.sqlite': ('footprintsSupport', 'footprints.sqlite'),
       'SharedSleep/sleep-records.sqlite': ('healthGroup', 'SharedSleep/sleep-records.sqlite')}
PV = 'com.apple.provenance'


def _policy_call(api, fn, *args):
    try:
        return fn(*args)
    except (policy_api.CopyPolicyError, policy_api.native.PolicyError) as error:
        api.require(False, str(error))


def raw_attribute(api, path, attribute):
    api.safe_path(str(path))
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    size = libc.getxattr(os.fsencode(path), attribute.encode(), None, 0, 0, 1)
    if size < 0:
        api.require(ctypes.get_errno() == getattr(errno, 'ENOATTR', 93), 'native_xattr_read_failed')
        return {'present': False, 'length': 0, 'sha256': None, 'rawBase64': None}
    api.require(size <= 65536, 'native_xattr_size_unexpected')
    buf = ctypes.create_string_buffer(max(size, 1))
    api.require(libc.getxattr(os.fsencode(path), attribute.encode(), buf, size, 0, 1) == size,
                'native_xattr_changed_during_read')
    raw = buf.raw[:size]
    return {'present': True, 'length': size, 'sha256': api.sha(raw),
            'rawBase64': base64.b64encode(raw).decode('ascii')}


def _read(api, path):
    import json
    return json.loads(api.read_file(api.safe_path(str(path))))


def _load_policy(api, plan, value, check_evidence=False):
    value = _policy_call(api, policy_api.native.validate_policy, value, api.sha(api.canonical(plan)))
    if check_evidence:
        for item in value['diagnosticEvidence']:
            api.require(api.file_hash(api.safe_path(item['path'])) == item['sha256'],
                        'native_policy_evidence_changed')
    return value


def copy_specs(plan):
    specs = [(key, '.', path) for key, path in ARCHIVES.items()
             if plan['sourceConfig']['roots'][key] is not None]
    specs += [('healthGroup', 'Health', 'Modules/Health')]
    if plan['sourceConfig']['roots']['healthSupport'] is not None:
        specs += [('healthSupport', '.', 'Modules/Health/ImportedSupport')]
    return specs + [('footprintsSupport', '.', 'Modules/Footprints'),
                    ('footprintsGroup', '.', 'Modules/Footprints/WidgetData'),
                    ('healthGroup', 'SharedSleep', 'SharedSleep')]


def _database_source_metadata(api, copy_trees, local):
    anchor, filename = local.rsplit('/', 1)
    api.require(anchor in copy_trees, 'native_database_copy_proof_missing')
    node = _policy_call(api, policy_api.subtree, copy_trees[anchor], filename)
    api.require(node.get('type') == 'file', 'native_database_copy_proof_not_file')
    return node['metadata']


class NativeCopySession:
    def __init__(self, api, plan, policy_path, payload):
        self.api, self.plan, self.payload = api, plan, Path(payload)
        api.require(sys.platform == 'darwin', 'native_copy_requires_darwin')
        self.policy = _load_policy(api, plan, _read(api, policy_path), True)
        self.records = []
        self.copy_trees = {}
        self.pending_databases = {}
        self.database_metadata = {}
        self.database_temporaries = {}

    def create_database_temporary(self, source, target, key, relative):
        api = self.api; source = Path(source); target = Path(target)
        local = source.relative_to(self.payload).as_posix()
        parent = Path(self.plan['targetGroup']) / 'Integration/Transactions.noindex' / self.plan['transactionID']
        api.require(self.payload.parent == parent and re.fullmatch(r'Payload-[0-9a-f]{16}', self.payload.name) is not None,
                    'native_database_payload_boundary_refused')
        api.require(DBS.get(local) == (key, relative) and target.parent == source.parent and
                    re.fullmatch(re.escape(source.name) + r'\.coherent-[0-9a-f]{12}', target.name) is not None,
                    'native_database_boundary_refused')
        api.require(local not in self.database_temporaries and local not in self.database_metadata,
                    'native_database_temporary_already_owned')
        api.require(api.metadata(source) == _database_source_metadata(api, self.copy_trees, local),
                    'native_database_source_metadata_not_bound_to_copy')
        from private_database_metadata import DatabaseTemporary, PrivateDatabaseMetadataError
        try:
            temporary = DatabaseTemporary(api, source, target)
        except PrivateDatabaseMetadataError as error:
            api.require(False, str(error))
        self.database_temporaries[local] = temporary
        return temporary

    def _emit(self, key, record):
        api = self.api
        relative = 'SourceArchives/%s/NativeMetadata.noindex/%04d.json' % (OWNERS[key], len(self.records))
        path = self.payload / relative
        record.update(schemaVersion=1, planSHA256=api.sha(api.canonical(self.plan)),
                      policySHA256=api.sha(api.canonical(self.policy)))
        api.atomic_new(path, record)
        self.records.append({'path': relative, 'sha256': api.file_hash(path)})

    def copy(self, source, target, key, relative='.'):
        api = self.api; source = Path(source); target = Path(target)
        api.require((key, relative, target.relative_to(self.payload).as_posix()) in copy_specs(self.plan),
                    'native_copy_mapping_not_allowed')
        expected_source = Path(self.plan['sourceConfig']['roots'][key])
        if relative != '.': expected_source /= relative
        api.require(source == expected_source, 'native_copy_source_path_mismatch')
        context = _policy_call(api, policy_api.copy_context, self.plan, key, relative)
        api.require(api.inventory(source) == context['expectedTree'], 'native_copy_source_changed_before')
        api.safe_path(str(source)); api.safe_path(str(target), exists=False)
        api.require(not target.exists(), 'copy_target_exists')
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        result = subprocess.run(['/usr/bin/ditto', '--rsrc', '--extattr', '--acl', str(source), str(target)],
                                capture_output=True, check=False)
        api.require(result.returncode == 0, 'metadata_preserving_copy_failed')
        actual = api.inventory(target)
        def states(local, name):
            left = source if local == '.' else source / local
            right = target if local == '.' else target / local
            return raw_attribute(api, left, name), raw_attribute(api, right, name)
        projection = _policy_call(api, policy_api.project_copy, context, actual, self.policy, states)
        api.require(api.inventory(source) == context['expectedTree'], 'native_copy_source_changed_after')
        api.require(api.inventory(target) == actual, 'native_copy_target_changed_during_verification')
        self.copy_trees[target.relative_to(self.payload).as_posix()] = copy.deepcopy(actual)
        self._emit(key, {'stage': 'copy', 'sourceKey': key, 'sourceRelative': relative,
                        'target': target.relative_to(self.payload).as_posix(),
                        'sourceTreeSHA256': api.sha(api.canonical(context['expectedTree'])),
                        'nativeTree': actual, 'nativeTreeSHA256': api.sha(api.canonical(actual)),
                        'fullNativeExact': not projection['changes'], 'changes': projection['changes']})

    def check_database_metadata(self, source, target, key, relative, source_metadata):
        api = self.api; source = Path(source); target = Path(target)
        local = source.relative_to(self.payload).as_posix()
        api.require(DBS.get(local) == (key, relative) and target.parent == source.parent and
                    target.name.startswith(source.name + '.coherent-'), 'native_database_boundary_refused')
        api.require(source_metadata == _database_source_metadata(api, self.copy_trees, local),
                    'native_database_source_metadata_not_bound_to_copy')
        api.require(api.metadata(source) == source_metadata, 'staged_database_metadata_changed')
        api.require(local in self.database_temporaries, 'native_database_temporary_not_owned')
        from private_database_metadata import PrivateDatabaseMetadataError
        try:
            quarantine = self.database_temporaries[local].restore_quarantine()
        except PrivateDatabaseMetadataError as error:
            api.require(False, str(error))
        original = _policy_call(api, policy_api.copy_context, self.plan, key, relative)
        context = _policy_call(api, policy_api.metadata_context, original, '.', source_metadata)
        actual = api.metadata(target)
        projection = _policy_call(api, policy_api.project_metadata, context, actual, self.policy,
                                  lambda _, name: (raw_attribute(api, source, name),
                                                   raw_attribute(api, target, name)))
        api.require(api.metadata(source) == source_metadata and api.metadata(target) == actual,
                    'staged_database_metadata_changed_during_verification')
        api.require(local not in self.pending_databases and local not in self.database_metadata,
                    'native_database_metadata_already_checked')
        self.pending_databases[local] = {'key': key, 'relative': relative,
            'sourceMetadata': copy.deepcopy(source_metadata), 'sourcePV': raw_attribute(api, source, PV),
            'quarantinePreservation': quarantine}

    def finalize_database_metadata(self, path, key, relative):
        api = self.api; path = Path(path); local = path.relative_to(self.payload).as_posix()
        api.require(DBS.get(local) == (key, relative) and local in self.pending_databases,
                    'native_database_finalize_boundary_refused')
        pending = self.pending_databases[local]
        api.require((pending['key'], pending['relative']) == (key, relative),
                    'native_database_pending_context_changed')
        original = _policy_call(api, policy_api.copy_context, self.plan, key, relative)
        context = _policy_call(api, policy_api.metadata_context, original, '.', pending['sourceMetadata'])
        actual = api.metadata(path)
        def states(_, name):
            api.require(name == PV, 'native_database_unknown_final_xattr')
            return pending['sourcePV'], raw_attribute(api, path, name)
        projection = _policy_call(api, policy_api.project_metadata, context, actual, self.policy, states)
        api.require(api.metadata(path) == actual, 'native_database_changed_during_final_metadata_check')
        from private_database_metadata import verify_quarantine_proof, PrivateDatabaseMetadataError
        quarantine = pending['quarantinePreservation']
        api.require(_identity(path) == quarantine.get('targetIdentity'),
                    'native_database_final_identity_not_owned_temporary')
        try:
            verify_quarantine_proof(quarantine, pending['sourceMetadata'], actual)
        except PrivateDatabaseMetadataError as error:
            api.require(False, str(error))
        self._emit(key, {'stage': 'sqlite-metadata', 'sourceKey': key, 'sourceRelative': relative,
                        'target': local, 'sourceMetadata': pending['sourceMetadata'], 'nativeMetadata': actual,
                        'fullNativeExact': not projection['changes'], 'changes': projection['changes'],
                        'quarantinePreservation': quarantine, 'finalDatabaseIdentity': _identity(path)})
        self.database_metadata[local] = copy.deepcopy(actual)
        del self.pending_databases[local]

    def manifest(self, components=None):
        self.api.require(not self.pending_databases and set(self.database_metadata) == set(DBS),
                         'native_database_metadata_not_finalized')
        archive = (components['SourceArchives'] if components is not None else
                   self.api.inventory(self.payload / 'SourceArchives'))
        for target, tree in self.copy_trees.items():
            if target in ARCHIVES.values():
                actual = _policy_call(self.api, policy_api.subtree, archive, target[len('SourceArchives/'):])
                self.api.require(actual == tree, 'native_archived_copy_changed_before_seal')
        for local, metadata in self.database_metadata.items():
            anchor, filename = local.rsplit('/', 1)
            tree = components[anchor] if components is not None else self.api.inventory(self.payload / anchor)
            node = _policy_call(self.api, policy_api.subtree, tree, filename)
            self.api.require(node['metadata'] == metadata, 'native_database_metadata_not_bound_to_prepared')
        return {'schemaVersion': 1, 'kind': 'RhythmExactNativeCopyMetadata', 'policy': self.policy,
                'policySHA256': self.api.sha(self.api.canonical(self.policy)), 'records': self.records,
                'sourceInventoriesUnchanged': True,
                'fullNativeExact': all(not _read(self.api, self.payload / x['path'])['changes']
                                       for x in self.records)}


def verify_native_receipt(api, plan, root, receipt, archive_tree=None):
    manifest = receipt['nativeCopyMetadata']
    api.require(manifest.get('schemaVersion') == 1 and
                manifest.get('kind') == 'RhythmExactNativeCopyMetadata', 'invalid_native_copy_manifest')
    policy = _load_policy(api, plan, manifest.get('policy'))
    api.require(manifest.get('policySHA256') == api.sha(api.canonical(policy)), 'native_copy_policy_changed')
    if archive_tree is None:
        archive_tree = api.inventory(Path(root) / 'SourceArchives')
    wanted = {('copy', key, rel, dest) for key, rel, dest in copy_specs(plan)}
    wanted |= {('sqlite-metadata', key, rel, dest) for dest, (key, rel) in DBS.items()}
    seen = set(); paths = set(); full_exact = True; copy_trees = {}
    for item in manifest.get('records', []):
        local = item['path']; path = Path(local)
        api.require(not path.is_absolute() and '..' not in path.parts and local not in paths,
                    'unsafe_or_duplicate_native_copy_record')
        paths.add(local)
        record_path = api.safe_path(str(Path(root) / path))
        api.require(api.file_hash(record_path) == item['sha256'], 'native_copy_escrow_changed')
        record = _read(api, record_path)
        key = record['sourceKey']; rel = record['sourceRelative']
        api.require(key in OWNERS and str(path.parent) == 'SourceArchives/%s/NativeMetadata.noindex' % OWNERS[key],
                    'native_copy_escrow_owner_mismatch')
        identity = (record['stage'], key, rel, record['target'])
        api.require(identity in wanted and identity not in seen, 'native_copy_record_scope_changed')
        seen.add(identity)
        api.require(record.get('schemaVersion') == 1 and record.get('planSHA256') == api.sha(api.canonical(plan)) and
                    record.get('policySHA256') == manifest['policySHA256'], 'native_copy_record_binding_changed')
        context = _policy_call(api, policy_api.copy_context, plan, key, rel)
        if record['stage'] == 'copy':
            api.require(record['sourceTreeSHA256'] == api.sha(api.canonical(context['expectedTree'])) and
                        record['nativeTreeSHA256'] == api.sha(api.canonical(record['nativeTree'])),
                        'native_copy_record_tree_changed')
            projection = _policy_call(api, policy_api.verify_copy, context, record['nativeTree'], policy, record['changes'])
            if record['target'] in ARCHIVES.values():
                local = record['target'][len('SourceArchives/'):]
                prepared = _policy_call(api, policy_api.subtree, receipt['components']['SourceArchives'], local)
                actual = _policy_call(api, policy_api.subtree, archive_tree, local)
                api.require(prepared == actual == record['nativeTree'], 'native_archived_copy_not_bound_to_component')
            copy_trees[record['target']] = record['nativeTree']
        else:
            api.require(record['sourceMetadata'] == _database_source_metadata(api, copy_trees, record['target']),
                        'native_database_source_metadata_not_bound_to_copy')
            anchor, filename = record['target'].rsplit('/', 1)
            node = _policy_call(api, policy_api.subtree, receipt['components'][anchor], filename)
            api.require(record['nativeMetadata'] == node['metadata'],
                        'native_database_metadata_not_bound_to_prepared')
            from private_database_metadata import verify_quarantine_proof, PrivateDatabaseMetadataError
            quarantine = record.get('quarantinePreservation')
            api.require(isinstance(quarantine, dict) and
                        record.get('finalDatabaseIdentity') == quarantine.get('targetIdentity'),
                        'native_database_final_identity_proof_changed')
            try:
                verify_quarantine_proof(quarantine, record['sourceMetadata'], record['nativeMetadata'])
            except PrivateDatabaseMetadataError as error:
                api.require(False, str(error))
            context = _policy_call(api, policy_api.metadata_context, context, '.', record['sourceMetadata'])
            projection = _policy_call(api, policy_api.verify_metadata, context, record['nativeMetadata'], policy,
                                      record['changes'])
        api.require(record['fullNativeExact'] is (not projection['changes']), 'native_copy_exactness_changed')
        full_exact = full_exact and not projection['changes']
    api.require(seen == wanted and manifest.get('sourceInventoriesUnchanged') is True and
                manifest.get('fullNativeExact') is full_exact, 'native_copy_records_incomplete')


def _identity(path):
    value = path.lstat()
    return {'device': value.st_dev, 'inode': value.st_ino}


def _move_paths(api, plan, root, relative):
    api.require(relative in ('Modules/Health', 'Modules/Footprints', 'SharedSleep', 'SourceArchives'),
                'native_component_not_allowed')
    api.require(re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', plan['transactionID']) is not None,
                'invalid_native_component_transaction')
    folder = Path(root) / 'Transactions.noindex' / plan['transactionID'] / 'NativeMoves.noindex'
    name = relative.replace('/', '-')
    return folder / (name + '.intent.json'), folder / (name + '.observed.json')


def _payload(api, receipt):
    value = receipt.get('payload', '')
    api.require(isinstance(value, str) and re.fullmatch(r'Payload-[0-9a-f]{16}', value) is not None,
                'unsafe_native_component_payload')
    return value


def _move_projection(api, expected, actual, policy, before, after):
    context = {'sourceKey': 'rhythmLibrary', 'sourceRelative': '.', 'expectedTree': expected}
    result = _policy_call(api, policy_api.project_copy, context, actual, policy,
                          lambda local, name: (before, after) if local == '.' and name == PV else (None, None))
    api.require(all(x['relative'] == '.' and x['attribute'] == PV for x in result['changes']) and
                len(result['changes']) <= 1, 'native_component_changed_outside_single_root_provenance')
    return result


def move_component(api, plan, root, receipt, relative, source, destination):
    source, destination = Path(source), Path(destination)
    expected_source = Path(root) / 'Transactions.noindex' / plan['transactionID'] / _payload(api, receipt) / relative
    api.require(source == expected_source and destination == Path(root) / relative,
                'native_component_move_path_mismatch')
    api.safe_path(str(source)); api.safe_path(str(destination), exists=False)
    api.require(not destination.exists() and not destination.is_symlink(), 'component_destination_exists')
    expected = receipt['components'][relative]
    api.require(api.inventory(source) == expected, 'staged_component_changed')
    before_identity = _identity(source); before = raw_attribute(api, source, PV)
    intent_path, observed_path = _move_paths(api, plan, root, relative)
    api.require(not intent_path.exists() and not observed_path.exists(), 'native_component_move_already_attempted')
    intent = {'schemaVersion': 1, 'kind': 'RhythmNativeComponentMoveIntent', 'component': relative,
              'transactionID': plan['transactionID'], 'planSHA256': api.sha(api.canonical(plan)),
              'source': str(source), 'destination': str(destination), 'identity': before_identity,
              'preparedTreeSHA256': api.sha(api.canonical(expected)), 'rootProvenance': before,
              'actionNotYetPerformed': True}
    api.atomic_new(intent_path, intent)
    api.require(api.inventory(source) == expected and _identity(source) == before_identity,
                'component_changed_before_move')
    os.rename(source, destination)
    api.require(not source.exists() and _identity(destination) == before_identity, 'component_move_identity_changed')
    actual = api.inventory(destination); after = raw_attribute(api, destination, PV)
    policy = _load_policy(api, plan, receipt['nativeCopyMetadata']['policy'])
    result = _move_projection(api, expected, actual, policy, before, after)
    api.require(api.inventory(destination) == actual and _identity(destination) == before_identity,
                'component_changed_during_move_verification')
    api.atomic_new(observed_path, {'schemaVersion': 1, 'kind': 'RhythmNativeComponentMoveObserved',
        'component': relative, 'transactionID': plan['transactionID'],
        'planSHA256': api.sha(api.canonical(plan)), 'intentSHA256': api.file_hash(intent_path),
        'identity': before_identity, 'preparedTreeSHA256': intent['preparedTreeSHA256'],
        'nativeTreeSHA256': api.sha(api.canonical(actual)), 'rootProvenance': after,
        'changes': result['changes'], 'allOtherNodesAndMetadataExact': True})


def component_matches(api, plan, root, receipt, relative, actual):
    payload = _payload(api, receipt)
    expected = receipt['components'][relative]
    intent_path, observed_path = _move_paths(api, plan, root, relative)
    if actual == expected and not observed_path.exists():
        return True  # Legacy exact move/recovery; no metadata exception is used.
    api.require(intent_path.is_file() and observed_path.is_file(), 'native_component_move_observation_missing')
    intent, observed = _read(api, intent_path), _read(api, observed_path)
    api.require(intent.get('schemaVersion') == observed.get('schemaVersion') == 1 and
                intent.get('kind') == 'RhythmNativeComponentMoveIntent' and
                observed.get('kind') == 'RhythmNativeComponentMoveObserved' and
                intent.get('component') == observed.get('component') == relative and
                intent.get('transactionID') == observed.get('transactionID') == plan['transactionID'] and
                intent.get('planSHA256') == observed.get('planSHA256') == api.sha(api.canonical(plan)) and
                intent.get('actionNotYetPerformed') is True and
                observed.get('intentSHA256') == api.file_hash(intent_path) and
                intent.get('preparedTreeSHA256') == observed.get('preparedTreeSHA256') == api.sha(api.canonical(expected)) and
                observed.get('nativeTreeSHA256') == api.sha(api.canonical(actual)) and
                observed.get('identity') == intent.get('identity') == _identity(Path(root)/relative) and
                intent.get('source') == str(Path(root) / 'Transactions.noindex' / plan['transactionID'] /
                                           payload / relative) and
                intent.get('destination') == str(Path(root)/relative) and
                observed.get('allOtherNodesAndMetadataExact') is True, 'native_component_move_binding_changed')
    policy = _load_policy(api, plan, receipt['nativeCopyMetadata']['policy'])
    result = _move_projection(api, expected, actual, policy, intent['rootProvenance'], observed['rootProvenance'])
    api.require(result['changes'] == observed.get('changes'), 'native_component_move_escrow_changed')
    return True
