#!/usr/bin/env python3
"""Synthetic mock tests only: no Darwin copy/xattr, SQL, app or user sources."""
import base64
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import integrate_sources as base
import native_copy as native
import private_database_metadata as database_metadata


class Refused(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode()


def sha(value):
    return hashlib.sha256(value).hexdigest()


def require(ok, code):
    if not ok:
        raise Refused(code)


def raw(value):
    return {'present': value is not None, 'length': len(value) if value is not None else 0,
            'sha256': sha(value) if value is not None else None,
            'rawBase64': base64.b64encode(value).decode() if value is not None else None}


def metadata():
    return {'mode': 448, 'mtimeNs': 123456789, 'uid': 501, 'gid': 20,
            'bsdFlags': 0, 'aclSHA256': sha(b'fixture-acl'),
            'xattrs': {native.PV: sha(b'fixture-source')}}


def file_node():
    return {'type': 'file', 'sha256': sha(b'fixture-content'), 'bytes': 15,
            'metadata': metadata()}


def directory(entries=None):
    return {'type': 'directory', 'metadata': metadata(), 'entries': entries or {}}


def directory_node():
    return {'type': 'directory', 'metadata': metadata()}


class Fixture:
    def __init__(self, folder):
        self.folder = folder
        self.payload = folder / 'target/Integration/Transactions.noindex/fixture/Payload-0123456789abcdef'
        self.payload.mkdir(parents=True)
        self.root = folder / 'target/Integration'
        self.trees = {}
        self.identities = {}
        health = directory({'Health': directory_node(), 'Health/health.sqlite': file_node(),
                            'SharedSleep': directory_node(), 'SharedSleep/sleep-records.sqlite': file_node()})
        footprints = directory({'footprints.sqlite': file_node(), 'Photos': directory_node(),
                                'Photos/fixture.jpg': file_node()})
        group = directory({'widget-diagnostics': directory_node()})
        group['entries']['widget-diagnostics']['metadata']['xattrs']['com.apple.quarantine'] = sha(b'fixture-q-source')
        values = {'healthGroup': health, 'healthSupport': directory({'fixture.txt': file_node()}),
                  'healthRestore': directory(), 'healthPreferences': file_node(),
                  'footprintsSupport': footprints, 'footprintsGroup': group,
                  'footprintsRestore': None, 'footprintsPreferences': file_node(), 'rhythmLibrary': file_node()}
        roots = {key: str(folder / 'sources' / key) if tree is not None else None
                 for key, tree in values.items()}
        self.plan = {'schemaVersion': 1, 'transactionID': 'fixture',
                     'targetGroup': str(folder / 'target'),
                     'sourceConfig': {'roots': roots, 'explicitAbsences': ['footprintsRestore'],
                                      'absentPaths': {'footprintsRestore': str(folder / 'absent-restore')}},
                     'databases': {key: {'summary': {}} for key in ('health', 'footprints', 'sharedSleep')},
                     'sources': {key: {'explicitlyAbsent': tree is None, 'tree': tree}
                                 for key, tree in values.items()}}
        for key, tree in values.items():
            if tree is not None:
                self.register(Path(roots[key]), tree)
        rules = copy.deepcopy(native.policy_api.native.expected_transitions())
        replacements = [(b'fixture-source', b'fixture-native'), (None, b'fixture-native'),
                        (b'fixture-q-source', b'fixture-q-native')]
        for rule, (left, right) in zip(rules, replacements):
            rule['source'] = {key: raw(left)[key] for key in ('present', 'length', 'sha256')}
            rule['native'] = {key: raw(right)[key] for key in ('present', 'length', 'sha256')}
        self.rules = rules
        evidence = folder / 'Root-actual-copy-difference-leaves.json'
        evidence.write_bytes(b'fixture-evidence')
        self.policy = {'schemaVersion': 1, 'kind': 'RootExactNativeMetadataPolicy',
                       'authority': 'RootMaintenanceDecision',
                       'approvedBy': 'fixture-reviewer',
                       'planSHA256': sha(canonical(self.plan)),
                       'diagnosticEvidence': [{'path': str(evidence), 'sha256': sha(evidence.read_bytes())}],
                       'transitions': rules}
        self.policy_path = folder / 'policy.json'
        self.policy_path.write_bytes(canonical(self.policy))
        self.api = SimpleNamespace(require=require, canonical=canonical, sha=sha,
            safe_path=self.safe_path, inventory=self.inventory,
            metadata=lambda p: self.inventory(p)['metadata'], read_file=lambda p: Path(p).read_bytes(),
            file_hash=lambda p: sha(Path(p).read_bytes()), atomic_new=self.atomic_new)

    def safe_path(self, value, exists=True):
        path = Path(value)
        require(path.is_absolute() and self.folder in path.parents and '..' not in path.parts, 'fixture_path_escape')
        if exists:
            require(path.exists(), 'fixture_path_missing')
        return path

    def register(self, path, tree):
        self.trees[path] = copy.deepcopy(tree)
        if tree['type'] == 'directory':
            path.mkdir(parents=True, exist_ok=True)
            for rel in sorted(tree['entries'], key=lambda p: (p.count('/'), p)):
                self.register(path / rel, native.policy_api.subtree(tree, rel))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture-file')

    def inventory(self, path):
        require(Path(path) in self.trees, 'fixture_inventory_missing')
        return copy.deepcopy(self.trees[Path(path)])

    def atomic_new(self, path, value):
        path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('xb') as handle:
            handle.write(canonical(value))

    def raw_attribute(self, api, path, attribute):
        value = self.inventory(path)['metadata']['xattrs'].get(attribute)
        values = (None, b'fixture-source', b'fixture-native', b'fixture-q-source', b'fixture-q-native')
        for candidate in values:
            if raw(candidate)['sha256'] == value:
                return raw(candidate)
        raise AssertionError('unexpected synthetic raw state')

    def fake_ditto(self, args, **kwargs):
        assert args[:4] == ['/usr/bin/ditto', '--rsrc', '--extattr', '--acl']
        source, target = map(Path, args[-2:])
        result = self.inventory(source)
        nodes = [result] + list(result.get('entries', {}).values())
        for node in nodes:
            attrs = node['metadata']['xattrs']
            if attrs.get(native.PV) in (None, sha(b'fixture-source')):
                attrs[native.PV] = sha(b'fixture-native')
            if attrs.get('com.apple.quarantine') == sha(b'fixture-q-source'):
                attrs['com.apple.quarantine'] = sha(b'fixture-q-native')
        self.register(target, result)
        return SimpleNamespace(returncode=0)

    def session(self):
        return native.NativeCopySession(api=self.api, plan=self.plan,
                                        policy_path=self.policy_path, payload=self.payload)

    def complete(self):
        session = self.session()
        for key, rel, destination in native.copy_specs(self.plan):
            source = Path(self.plan['sourceConfig']['roots'][key])
            if rel != '.':
                source /= rel
            session.copy(source, self.payload / destination, key, rel)
        for destination, (key, rel) in native.DBS.items():
            source = self.payload / destination
            temporary = source.with_name(source.name + '.coherent-0123456789ab')
            handle = session.create_database_temporary(source, temporary, key, rel)
            session.check_database_metadata(source, temporary, key, rel, self.inventory(source)['metadata'])
            session.finalize_database_metadata(source, key, rel)
            handle.close()
        archive = directory()
        for target, tree in session.copy_trees.items():
            if target not in native.ARCHIVES.values():
                continue
            local = target[len('SourceArchives/'):]
            for parent in reversed(Path(local).parents):
                if str(parent) != '.':
                    archive['entries'].setdefault(parent.as_posix(), directory_node())
            node = copy.deepcopy(tree); node.pop('entries', None)
            archive['entries'][local] = node
            for rel, node in tree.get('entries', {}).items():
                archive['entries'][local + '/' + rel] = copy.deepcopy(node)
        self.trees[self.payload / 'SourceArchives'] = copy.deepcopy(archive)
        components = {anchor: self.inventory(self.payload / anchor)
                      for anchor in ('Modules/Health', 'Modules/Footprints', 'SharedSleep')}
        components['SourceArchives'] = archive
        return session, {'nativeCopyMetadata': session.manifest(components), 'components': components}

    def edit_record(self, receipt, predicate, change):
        for item in receipt['nativeCopyMetadata']['records']:
            path = self.payload / item['path']
            value = json.loads(path.read_bytes())
            if predicate(value):
                change(value)
                path.write_bytes(canonical(value))
                item['sha256'] = sha(path.read_bytes())
                return
        raise AssertionError('fixture record not found')


class NativeSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rhythm-native-session-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.fixture = Fixture(Path(self.temp.name))
        f = self.fixture
        f.database_handles = []
        class FakeDatabaseTemporary:
            def __init__(self, api, source, target):
                require(not Path(target).exists(), 'fixture_temporary_exists')
                f.register(Path(target), f.inventory(source))
                target_identity = native._identity(Path(source))  # Model the final replaced inode.
                self.proof = {'schemaVersion': 1, 'kind': 'PrivateDatabaseQuarantinePreserved',
                    'source': raw(None), 'before': raw(None), 'after': raw(None),
                    'firstFlagsBase64': None, 'firstFlagsExact': True, 'outcome': 'both_absent',
                    'targetIdentity': target_identity,
                    'sourceIdentity': dict(target_identity, inode=target_identity['inode'] + 1),
                    'sourceUnchanged': True, 'allOtherMetadataUnchanged': True,
                    'sourceFDReadOnly': True, 'targetFDWasExclusivelyCreated': True}
                self.closed = False
                f.database_handles.append(self)
            def restore_quarantine(self):
                return copy.deepcopy(self.proof)
            def close(self):
                self.closed = True
        patches = (mock.patch.object(native.sys, 'platform', 'darwin'),
                   mock.patch.object(native.policy_api.native, 'expected_transitions', lambda: copy.deepcopy(f.rules)),
                   mock.patch.object(native.subprocess, 'run', side_effect=f.fake_ditto),
                   mock.patch.object(native, 'raw_attribute', side_effect=f.raw_attribute),
                   mock.patch.object(database_metadata, 'DatabaseTemporary', FakeDatabaseTemporary))
        for patch in patches:
            patch.start(); self.addCleanup(patch.stop)

    def verify(self, receipt):
        f = self.fixture
        return native.verify_native_receipt(f.api, f.plan, f.payload, receipt)

    def test_complete_copies_and_three_databases_verify(self):
        f = self.fixture; session, receipt = f.complete()
        self.assertEqual(len(session.records), len(native.copy_specs(f.plan)) + 3)
        self.assertFalse(receipt['nativeCopyMetadata']['fullNativeExact'])
        self.assertEqual(len(f.database_handles), 3)
        self.assertTrue(all(handle.closed for handle in f.database_handles))
        self.verify(receipt)

    def test_each_missing_database_or_copy_record_is_rejected(self):
        f = self.fixture; _, receipt = f.complete()
        for index in range(len(receipt['nativeCopyMetadata']['records'])):
            with self.subTest(index=index):
                altered = copy.deepcopy(receipt)
                del altered['nativeCopyMetadata']['records'][index]
                with self.assertRaises(Refused):
                    self.verify(altered)

    def test_duplicate_and_wrong_owner_are_rejected(self):
        f = self.fixture; _, receipt = f.complete()
        duplicate = copy.deepcopy(receipt)
        duplicate['nativeCopyMetadata']['records'].append(copy.deepcopy(duplicate['nativeCopyMetadata']['records'][0]))
        with self.assertRaises(Refused):
            self.verify(duplicate)
        item = receipt['nativeCopyMetadata']['records'][0]
        original = f.payload / item['path']
        changed = f.payload / 'SourceArchives/Rhythm/NativeMetadata.noindex/forged.json'
        changed.parent.mkdir(parents=True, exist_ok=True); changed.write_bytes(original.read_bytes())
        item['path'] = changed.relative_to(f.payload).as_posix()
        with self.assertRaisesRegex(Refused, 'owner_mismatch'):
            self.verify(receipt)

    def test_raw_escrow_forgery_rejected_even_with_new_outer_hash(self):
        f = self.fixture; _, receipt = f.complete()
        def change(record):
            record['changes'][0]['native']['rawBase64'] = base64.b64encode(b'forged').decode()
        f.edit_record(receipt, lambda r: r['stage'] == 'copy' and bool(r['changes']), change)
        with self.assertRaises(Refused):
            self.verify(receipt)

    def test_non_xattr_copy_metadata_forgery_rejected(self):
        f = self.fixture; _, receipt = f.complete()
        def change(record):
            record['nativeTree']['metadata']['mode'] ^= 1
            record['nativeTreeSHA256'] = sha(canonical(record['nativeTree']))
        f.edit_record(receipt, lambda r: r['stage'] == 'copy', change)
        with self.assertRaises(Refused):
            self.verify(receipt)

    def test_database_source_metadata_cannot_rebase_itself(self):
        f = self.fixture; _, receipt = f.complete()
        def change(record):
            record['sourceMetadata']['mtimeNs'] += 1
            record['nativeMetadata']['mtimeNs'] += 1
        f.edit_record(receipt, lambda r: r['stage'] == 'sqlite-metadata', change)
        with self.assertRaisesRegex(Refused, 'source_metadata_not_bound_to_copy'):
            self.verify(receipt)

    def test_database_final_metadata_is_bound_to_prepared_inventory(self):
        f = self.fixture; session, receipt = f.complete()
        altered = copy.deepcopy(receipt['components'])
        altered['Modules/Health']['entries']['health.sqlite']['metadata']['mode'] ^= 1
        with self.assertRaisesRegex(Refused, 'metadata_not_bound_to_prepared'):
            session.manifest(altered)
        receipt['components'] = altered
        with self.assertRaisesRegex(Refused, 'metadata_not_bound_to_prepared'):
            self.verify(receipt)

    def test_quarantine_raw_or_first_flags_forgery_is_rejected(self):
        f = self.fixture; _, receipt = f.complete()
        record_item = next(item for item in receipt['nativeCopyMetadata']['records']
                           if json.loads((f.payload / item['path']).read_bytes())['stage'] == 'sqlite-metadata')
        original = json.loads((f.payload / record_item['path']).read_bytes())['quarantinePreservation']
        for field in ('raw', 'flags'):
            with self.subTest(field=field):
                def change(record):
                    proof = copy.deepcopy(original)
                    if field == 'raw':
                        proof['after']['rawBase64'] = base64.b64encode(b'forged').decode()
                    else:
                        proof['firstFlagsBase64'] = base64.b64encode(b'0087').decode()
                    record['quarantinePreservation'] = proof
                f.edit_record(receipt, lambda r: r['stage'] == 'sqlite-metadata', change)
                with self.assertRaises(Refused):
                    self.verify(receipt)

    def test_final_database_identity_cannot_disagree_with_quarantine_owner(self):
        f = self.fixture; _, receipt = f.complete()
        def change(record):
            record['finalDatabaseIdentity']['inode'] += 1
        f.edit_record(receipt, lambda r: r['stage'] == 'sqlite-metadata', change)
        with self.assertRaisesRegex(Refused, 'final_identity_proof_changed'):
            self.verify(receipt)

    def test_unfinalized_database_metadata_cannot_be_sealed(self):
        f = self.fixture; session, _ = f.complete()
        local = next(iter(native.DBS))
        session.pending_databases[local] = {'fixture': 'incomplete'}
        with self.assertRaisesRegex(Refused, 'metadata_not_finalized'):
            session.manifest()

    def test_session_rejects_database_metadata_changed_after_copy(self):
        f = self.fixture; session, _ = f.complete()
        local, (key, relative) = next(iter(native.DBS.items()))
        source = f.payload / local; temporary = source.with_name(source.name + '.coherent-forged')
        altered = f.inventory(source); altered['metadata']['mode'] ^= 1
        f.register(source, altered); f.register(temporary, altered)
        with self.assertRaisesRegex(Refused, 'source_metadata_not_bound_to_copy'):
            session.check_database_metadata(source, temporary, key, relative, altered['metadata'])

    def test_archive_copy_is_bound_to_prepared_and_actual_tree(self):
        f = self.fixture; session, receipt = f.complete()
        altered = copy.deepcopy(receipt['components'])
        altered['SourceArchives']['entries']['Health/AppGroup']['metadata']['mode'] ^= 1
        with self.assertRaisesRegex(Refused, 'archived_copy_changed_before_seal'):
            session.manifest(altered)
        forged = copy.deepcopy(receipt); forged['components'] = altered
        with self.assertRaisesRegex(Refused, 'archived_copy_not_bound_to_component'):
            self.verify(forged)
        f.trees[f.payload / 'SourceArchives'] = altered['SourceArchives']
        with self.assertRaisesRegex(Refused, 'archived_copy_not_bound_to_component'):
            self.verify(receipt)

    def test_wrong_copy_context_is_rejected_before_copy(self):
        f = self.fixture; session = f.session()
        with self.assertRaises(Refused):
            session.copy(Path(f.plan['sourceConfig']['roots']['healthGroup']),
                         f.payload / 'Modules/Footprints', 'healthGroup')

    def move_fixture(self):
        f = self.fixture
        source = f.payload / 'Modules/Health'; destination = f.root / 'Modules/Health'
        tree = directory({'health.sqlite': file_node()})
        f.register(source, tree)
        receipt = {'payload': f.payload.name, 'components': {'Modules/Health': copy.deepcopy(tree)},
                   'nativeCopyMetadata': {'policy': f.policy}}
        ids = {source: {'device': 1, 'inode': 7}}
        def rename(left, right):
            left, right = Path(left), Path(right)
            altered = f.inventory(left)
            altered['metadata']['xattrs'][native.PV] = sha(b'fixture-native')
            f.trees[right] = altered; ids[right] = ids.pop(left)
            del f.trees[left]
            # Files remain synthetic; no OS rename or Darwin metadata call.
            right.mkdir(parents=True, exist_ok=True)
            for child in list(left.iterdir()):
                child.unlink()
            left.rmdir()
        return source, destination, receipt, ids, rename

    def test_component_root_event_is_append_only_same_inode_and_strict_elsewhere(self):
        f = self.fixture; source, destination, receipt, ids, rename = self.move_fixture()
        original = copy.deepcopy(receipt['components'])
        with mock.patch.object(native, '_identity', side_effect=lambda p: copy.deepcopy(ids[Path(p)])), \
                mock.patch.object(native.os, 'rename', side_effect=rename):
            native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health', source, destination)
            self.assertTrue(native.component_matches(f.api, f.plan, f.root, receipt,
                                                    'Modules/Health', f.inventory(destination)))
            self.assertEqual(receipt['components'], original)
            altered = f.inventory(destination); altered['entries']['health.sqlite']['metadata']['mtimeNs'] += 1
            with self.assertRaises(Refused):
                native.component_matches(f.api, f.plan, f.root, receipt, 'Modules/Health', altered)
            ids[destination]['inode'] += 1
            with self.assertRaises(Refused):
                native.component_matches(f.api, f.plan, f.root, receipt,
                                         'Modules/Health', f.inventory(destination))

    def test_exact_recovery_needs_no_metadata_exception(self):
        f = self.fixture; source, destination, receipt, ids, _ = self.move_fixture()
        f.register(destination, f.inventory(source))
        self.assertTrue(native.component_matches(f.api, f.plan, f.root, receipt,
                                                'Modules/Health', f.inventory(destination)))

    def test_component_payload_and_exact_paths_are_enforced_before_move(self):
        f = self.fixture; source, destination, receipt, ids, rename = self.move_fixture()
        with mock.patch.object(native.os, 'rename') as action:
            for value in ('../foreign', 'Payload-short', 'Payload-' + 'A' * 16, None, 123):
                with self.subTest(value=value):
                    altered = dict(receipt, payload=value)
                    with self.assertRaisesRegex(Refused, 'unsafe_native_component_payload'):
                        native.move_component(f.api, f.plan, f.root, altered,
                                              'Modules/Health', source, destination)
                    with self.assertRaisesRegex(Refused, 'unsafe_native_component_payload'):
                        native.component_matches(f.api, f.plan, f.root, altered,
                                                 'Modules/Health', receipt['components']['Modules/Health'])
            with self.assertRaisesRegex(Refused, 'move_path_mismatch'):
                native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health',
                                      source.with_name('foreign'), destination)
            with self.assertRaisesRegex(Refused, 'move_path_mismatch'):
                native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health',
                                      source, destination.with_name('foreign'))
            action.assert_not_called()

    def test_component_intent_source_and_raw_observation_cannot_be_forged(self):
        f = self.fixture; source, destination, receipt, ids, rename = self.move_fixture()
        with mock.patch.object(native, '_identity', side_effect=lambda p: copy.deepcopy(ids[Path(p)])), \
                mock.patch.object(native.os, 'rename', side_effect=rename):
            native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health', source, destination)
            intent_path, observed_path = native._move_paths(f.api, f.plan, f.root, 'Modules/Health')
            original_intent, original_observed = intent_path.read_bytes(), observed_path.read_bytes()
            intent = json.loads(original_intent); observed = json.loads(original_observed)
            intent['source'] = str(source.with_name('foreign'))
            intent_path.write_bytes(canonical(intent)); observed['intentSHA256'] = sha(intent_path.read_bytes())
            observed_path.write_bytes(canonical(observed))
            with self.assertRaisesRegex(Refused, 'move_binding_changed'):
                native.component_matches(f.api, f.plan, f.root, receipt,
                                         'Modules/Health', f.inventory(destination))
            intent_path.write_bytes(original_intent); observed = json.loads(original_observed)
            observed['rootProvenance']['rawBase64'] = base64.b64encode(b'forged').decode()
            observed_path.write_bytes(canonical(observed))
            with self.assertRaises(Refused):
                native.component_matches(f.api, f.plan, f.root, receipt,
                                         'Modules/Health', f.inventory(destination))

    def test_missing_observation_after_move_is_not_silently_blessed(self):
        f = self.fixture; source, destination, receipt, ids, rename = self.move_fixture()
        with mock.patch.object(native, '_identity', side_effect=lambda p: copy.deepcopy(ids[Path(p)])), \
                mock.patch.object(native.os, 'rename', side_effect=rename):
            intent, observed = native._move_paths(f.api, f.plan, f.root, 'Modules/Health')
            original_atomic = f.api.atomic_new
            def fail_observation(path, value):
                if Path(path) == observed:
                    raise Refused('fixture_observation_failure')
                original_atomic(path, value)
            with mock.patch.object(f.api, 'atomic_new', side_effect=fail_observation):
                with self.assertRaisesRegex(Refused, 'fixture_observation_failure'):
                    native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health', source, destination)
            saved = intent.read_bytes()
            self.assertFalse(observed.exists())
            with self.assertRaisesRegex(Refused, 'observation_missing'):
                native.component_matches(f.api, f.plan, f.root, receipt,
                                         'Modules/Health', f.inventory(destination))
            with self.assertRaises(Refused):
                native.move_component(f.api, f.plan, f.root, receipt, 'Modules/Health', source, destination)
            self.assertEqual(intent.read_bytes(), saved)

    def test_base_default_copy_remains_strict_without_native_projection(self):
        f = self.fixture
        source = Path(f.plan['sourceConfig']['roots']['healthSupport'])
        target = f.payload / 'default-copy'
        with mock.patch.object(base, 'inventory', side_effect=f.inventory):
            with self.assertRaisesRegex(base.MigrationError, 'copied_tree_verification_failed'):
                base.copy_exact(source, target)

    def test_base_verifier_reuses_its_single_archive_inventory(self):
        f = self.fixture; _, receipt = f.complete()
        with mock.patch.object(base, 'read_receipt', return_value=(f.payload.parent, receipt)), \
                mock.patch.object(base, 'inventory', side_effect=f.inventory) as inventory_call, \
                mock.patch.object(native, 'component_matches', return_value=True), \
                mock.patch.object(native, 'verify_native_receipt') as verify_call:
            self.assertIs(base.verify_prepared(f.payload, f.plan), receipt)
        self.assertEqual(sum(call.args[0] == f.payload / 'SourceArchives'
                             for call in inventory_call.call_args_list), 1)
        self.assertEqual(verify_call.call_args.kwargs['archive_tree'],
                         receipt['components']['SourceArchives'])

    def test_base_runtime_only_never_reads_archives_or_native_proof(self):
        f = self.fixture; _, receipt = f.complete()
        with mock.patch.object(base, 'active_for', return_value={'state': 'active'}), \
                mock.patch.object(base, 'read_receipt', return_value=(f.payload.parent, receipt)), \
                mock.patch.object(base, 'inventory') as inventory_call, \
                mock.patch.object(native, 'component_matches') as matches_call, \
                mock.patch.object(native, 'verify_native_receipt') as verify_call, \
                mock.patch.object(base, 'verify_current_runtime') as runtime_call:
            self.assertIs(base.verify_prepared(f.payload, f.plan, strict=False, runtime_only=True), receipt)
        inventory_call.assert_not_called(); matches_call.assert_not_called(); verify_call.assert_not_called()
        runtime_call.assert_called_once_with(f.payload)

    def test_base_payload_native_api_and_all_contexts_are_compatible(self):
        f = self.fixture; payload = f.payload.parent / 'Payload-fedcba9876543210'
        calls = []; database_calls = []
        class Session:
            def __init__(self, api, plan, policy_path, payload):
                self.payload = payload
                assert all(callable(getattr(api, name)) for name in
                           ('require', 'canonical', 'sha', 'safe_path', 'inventory', 'metadata',
                            'read_file', 'file_hash', 'atomic_new'))
                assert plan is f.plan and policy_path == f.policy_path
            def copy(self, source, target, key, relative='.'):
                calls.append((key, relative, target.relative_to(self.payload).as_posix()))
                f.register(target, f.inventory(source))
            def create_database_temporary(self, *args):
                return SimpleNamespace(close=lambda: None)
            def manifest(self, components=None):
                assert set(components) == set(base.COMPONENTS)
                return {'fixture': 'manifest'}
        result = {}
        with mock.patch.object(native, 'NativeCopySession', Session), \
                mock.patch.object(base, 'coherent_database', side_effect=lambda *args: database_calls.append(args)), \
                mock.patch.object(base, 'preferences', return_value={'standard': {}, 'module': {}}), \
                mock.patch.object(base, 'sync_tree'), mock.patch.object(base, 'inventory', return_value=directory()):
            components = base.build_payload(f.plan, payload, f.policy_path, result)
        self.assertEqual(calls, native.copy_specs(f.plan))
        self.assertEqual(set(components), set(base.COMPONENTS))
        self.assertEqual(result, {'fixture': 'manifest'})
        self.assertEqual({(call[0].relative_to(payload).as_posix(), call[3], call[4]) for call in database_calls},
                         {(local, key, rel) for local, (key, rel) in native.DBS.items()})

    def coherent_mock(self, *, native_enabled=True, copyfile_result=0, fail_finalize=False):
        f = self.fixture; events = []; path = f.payload / 'Modules/Health/health.sqlite'
        expected = {'fixture': 'summary'}; handle = SimpleNamespace(close=lambda: events.append('handle-close'))
        class Reader:
            def backup(self, writer): events.append('backup')
            def close(self): events.append('reader-close')
        class Writer:
            def execute(self, statement):
                assert statement == 'PRAGMA journal_mode=DELETE'
                events.append('journal-delete'); return SimpleNamespace(fetchone=lambda: ('delete',))
            def close(self): events.append('writer-close')
        def open_reader(value):
            events.append('read-source' if value == path else 'read-temp'); return Reader()
        def writer(value): events.append('sqlite-open'); return Writer()
        def create(*args): events.append('create'); return handle
        def finalize(*args):
            events.append('finalize')
            if fail_finalize: raise Refused('fixture_finalize_failure')
        mock_native = SimpleNamespace(create_database_temporary=create,
            check_database_metadata=lambda *args: events.append('check'), finalize_database_metadata=finalize)
        copyfile = mock.Mock(side_effect=lambda *args: events.append('copyfile') or copyfile_result)
        library = SimpleNamespace(copyfile=copyfile)
        patches = (mock.patch.object(base, 'metadata', return_value=metadata()),
                   mock.patch.object(base, 'open_ro', side_effect=open_reader),
                   mock.patch.object(base.sqlite3, 'connect', side_effect=writer),
                   mock.patch.object(base, 'sql_summary', return_value=expected),
                   mock.patch.object(base.ctypes, 'CDLL', return_value=library),
                   mock.patch.object(base.os, 'replace', side_effect=lambda *args: events.append('replace')))
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            try:
                base.coherent_database(path, expected, mock_native if native_enabled else None,
                                       'healthGroup', 'Health/health.sqlite')
            except Exception as error:
                return events, error
        return events, None

    def test_coherent_native_handle_covers_sql_copy_replace_and_finalize(self):
        events, error = self.coherent_mock()
        self.assertIsNone(error)
        critical = ['create', 'read-source', 'sqlite-open', 'backup', 'journal-delete',
                    'read-temp', 'copyfile', 'check', 'replace', 'finalize', 'handle-close']
        self.assertEqual([value for value in events if value in critical], critical)
        self.assertEqual(events.count('handle-close'), 1)

    def test_coherent_native_handle_closes_on_copy_or_finalize_failure(self):
        for options, code in (({'copyfile_result': 1}, 'sqlite_metadata_copy_failed'),
                              ({'fail_finalize': True}, 'fixture_finalize_failure')):
            with self.subTest(options=options):
                events, error = self.coherent_mock(**options)
                self.assertEqual(str(error), code)
                self.assertEqual(events.count('handle-close'), 1)
                self.assertEqual(events[-1], 'handle-close')

    def test_coherent_default_has_no_precreated_native_handle(self):
        events, error = self.coherent_mock(native_enabled=False)
        self.assertIsNone(error)
        self.assertNotIn('create', events); self.assertNotIn('handle-close', events)
        self.assertNotIn('check', events); self.assertNotIn('finalize', events)
        self.assertIn('copyfile', events); self.assertIn('replace', events)


if __name__ == '__main__':
    unittest.main()
