#!/usr/bin/env python3
"""Real private regular FDs; fake xattrs only. No SQL, system xattrs or source data."""
import base64
import copy
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import private_database_metadata as d

SOURCE = b'0042;1234abcd;FixtureAgent;'
NORMALIZED = b'0042;2345bcde;;'


class FakeAttributes:
    def __init__(self):
        self.values = {}; self.writes = []; self.bad_readback = False; self.before_write = None

    def key(self, fd):
        x = os.fstat(fd); return x.st_dev, x.st_ino

    def read(self, fd):
        return self.values.get(self.key(fd))

    def write(self, fd, raw):
        self.writes.append((fd, raw))
        if self.before_write: self.before_write()
        self.values[self.key(fd)] = b'wrong' if self.bad_readback else raw


class FakeAPI:
    def __init__(self, backend):
        self.backend = backend; self.extra = {}

    def safe_path(self, value, exists=True):
        p = Path(value)
        if p.is_symlink(): raise d.PrivateDatabaseMetadataError('fixture_symlink')
        if exists and not p.exists(): raise d.PrivateDatabaseMetadataError('fixture_missing')
        return p

    def metadata(self, path):
        x = Path(path).lstat(); raw = self.backend.values.get((x.st_dev, x.st_ino))
        attrs = {'com.apple.provenance': 'f' * 64}
        if raw is not None: attrs[d.QUARANTINE.decode()] = hashlib.sha256(raw).hexdigest()
        return {'mode': x.st_mode & 0o777, 'uid': x.st_uid, 'gid': x.st_gid,
                'mtimeNs': x.st_mtime_ns, 'bsdFlags': getattr(x, 'st_flags', 0),
                'aclSHA256': 'e' * 64, 'xattrs': attrs, **self.extra.get(str(path), {})}


class PrivateTemporaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='private-db-q-mock-', dir='/private/tmp')
        self.root = Path(self.directory.name); self.source = self.root/'health.sqlite'
        self.source.write_bytes(b'fixture-original')
        self.target = self.root/'health.sqlite.coherent-123456abcdef'
        self.backend = FakeAttributes(); self.api = FakeAPI(self.backend)
        s = self.source.stat(); self.backend.values[(s.st_dev, s.st_ino)] = SOURCE
        self.temporary = None

    def tearDown(self):
        if self.temporary: self.temporary.close()
        self.directory.cleanup()

    def create(self, before=NORMALIZED):
        self.temporary = d.DatabaseTemporary(self.api, self.source, self.target, self.backend)
        self.backend.values[self.backend.key(self.temporary.fd)] = before
        return self.temporary

    def test_same_flags_restores_only_owned_target_fd_and_pure_proof(self):
        temp = self.create(); original = self.source.read_bytes()
        proof = temp.restore_quarantine()
        self.assertEqual(self.backend.writes, [(temp.fd, SOURCE)])
        self.assertEqual(self.backend.read(temp.source_fd), SOURCE)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(proof['outcome'], 'restored_exact_source_raw_same_initial_flags')
        self.assertTrue(d.verify_quarantine_proof(proof, self.api.metadata(self.source),
                                                self.api.metadata(self.target)))

    def test_equal_raw_is_no_write(self):
        temp = self.create(SOURCE); proof = temp.restore_quarantine()
        self.assertEqual(proof['outcome'], 'already_exact'); self.assertFalse(self.backend.writes)

    def test_both_absent_is_no_write(self):
        s = self.source.stat(); self.backend.values[(s.st_dev, s.st_ino)] = None
        temp = self.create(None); proof = temp.restore_quarantine()
        self.assertEqual(proof['outcome'], 'both_absent'); self.assertFalse(self.backend.writes)
        self.assertTrue(d.verify_quarantine_proof(proof, self.api.metadata(self.source), self.api.metadata(self.target)))

    def test_absent_source_cannot_remove_target(self):
        s = self.source.stat(); self.backend.values[(s.st_dev, s.st_ino)] = None
        temp = self.create()
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'presence_mismatch'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_absent_target_cannot_create_attribute(self):
        temp = self.create(None)
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'presence_mismatch'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_flags_exact_bytes_required(self):
        temp = self.create(b'0043;2345bcde;;')
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'flags_mismatch'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_case_change_is_not_flag_equality(self):
        s = self.source.stat(); self.backend.values[(s.st_dev, s.st_ino)] = b'00a2;1234abcd;FixtureAgent;'
        temp = self.create(b'00A2;2345bcde;;')
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'flags_mismatch'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_unknown_or_malformed_changed_pair_refused(self):
        for bad in (b'0042', b';2345bcde;;', b'NOPE;2345bcde;;', b'0042;nothex;;', b'0042;2345bcde;\0;'):
            with self.subTest(raw=bad):
                temp = self.create(bad)
                with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'malformed'): temp.restore_quarantine()
                self.assertFalse(self.backend.writes)
                temp.close(); self.temporary = None; self.target.unlink()

    def test_readback_must_equal_full_original_raw(self):
        temp = self.create(); self.backend.bad_readback = True
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'readback_mismatch'): temp.restore_quarantine()
        self.assertEqual(self.backend.read(temp.source_fd), SOURCE)

    def test_changed_source_after_creation_stops(self):
        temp = self.create(); self.source.write_bytes(b'other')
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'source_changed'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_fd_path_identity_swap_stops(self):
        temp = self.create(); self.target.rename(self.root/'retained-old-target')
        self.target.write_bytes(b'swapped')
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'fd_or_path_changed'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_target_hardlink_stops(self):
        temp = self.create(); os.link(self.target, self.root/'another-link')
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'hardlink'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_source_readonly_claim_is_rechecked(self):
        temp = self.create(); real = d.fcntl.fcntl
        def flags(fd, command):
            return os.O_RDWR if fd == temp.source_fd else real(fd, command)
        with mock.patch.object(d.fcntl, 'fcntl', side_effect=flags):
            with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'not_readonly'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_target_readwrite_claim_is_rechecked(self):
        temp = self.create(); real = d.fcntl.fcntl
        def flags(fd, command):
            return os.O_RDONLY if fd == temp.fd else real(fd, command)
        with mock.patch.object(d.fcntl, 'fcntl', side_effect=flags):
            with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'not_readwrite'): temp.restore_quarantine()
        self.assertFalse(self.backend.writes)

    def test_existing_target_not_reused(self):
        self.target.write_bytes(b'existing')
        with self.assertRaises(FileExistsError): self.create()
        self.assertEqual(self.target.read_bytes(), b'existing'); self.assertFalse(self.backend.writes)

    def test_target_path_boundary(self):
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'path_boundary'):
            d.DatabaseTemporary(self.api, self.source, self.root/'other.sqlite', self.backend)
        self.assertFalse(self.backend.writes)

    def test_other_target_metadata_change_is_rejected(self):
        temp = self.create()
        self.backend.before_write = lambda: self.api.extra.update({str(self.target): {'mode': 0o777}})
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'other_metadata'): temp.restore_quarantine()

    def test_restore_is_single_use_and_close_is_idempotent(self):
        temp = self.create(); temp.restore_quarantine()
        with self.assertRaisesRegex(d.PrivateDatabaseMetadataError, 'already_attempted'): temp.restore_quarantine()
        self.assertEqual(len(self.backend.writes), 1)
        temp.close(); temp.close(); self.assertIsNone(temp.fd); self.assertIsNone(temp.source_fd)

    def test_pure_proof_rejects_raw_hash_flags_or_scope_gate_tamper(self):
        temp = self.create(); proof = temp.restore_quarantine()
        source, target = self.api.metadata(self.source), self.api.metadata(self.target)
        for field in ('raw', 'hash', 'flags', 'readonly', 'sameinode', 'outcome', 'nativehash'):
            with self.subTest(field=field):
                bad = copy.deepcopy(proof); native = copy.deepcopy(target)
                if field == 'raw': bad['source']['rawBase64'] = base64.b64encode(b'forged').decode()
                if field == 'hash': bad['after']['sha256'] = '0' * 64
                if field == 'flags': bad['firstFlagsBase64'] = base64.b64encode(b'0087').decode()
                if field == 'readonly': bad['sourceFDReadOnly'] = False
                if field == 'sameinode': bad['targetIdentity'] = bad['sourceIdentity']
                if field == 'outcome': bad['outcome'] = 'already_exact'
                if field == 'nativehash': native['xattrs'][d.QUARANTINE.decode()] = '0' * 64
                with self.assertRaises(d.PrivateDatabaseMetadataError): d.verify_quarantine_proof(bad, source, native)


if __name__ == '__main__':
    unittest.main(verbosity=2)
