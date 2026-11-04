"""Preserve quarantine bytes only on an exclusively created private SQL temp FD.

The caller must authorize one of its three staged database boundaries before
constructing this object. This module neither removes xattrs nor writes a source
FD. No xattr operation happens during import or construction.
"""
import base64
import copy
import ctypes
import errno
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat

QUARANTINE = b'com.apple.quarantine'


class PrivateDatabaseMetadataError(Exception):
    """Public code only; no private values or paths."""


def _need(ok, code):
    if not ok:
        raise PrivateDatabaseMetadataError(code)


def _identity(value):
    return {'device': value.st_dev, 'inode': value.st_ino}


def _state(raw):
    return {'present': raw is not None, 'length': 0 if raw is None else len(raw),
            'sha256': None if raw is None else hashlib.sha256(raw).hexdigest(),
            'rawBase64': None if raw is None else base64.b64encode(raw).decode('ascii')}


def _flags(raw):
    _need(isinstance(raw, bytes) and len(raw) <= 65536 and b'\0' not in raw,
          'database_quarantine_malformed')
    parts = raw.split(b';')
    _need(len(parts) == 4 and re.fullmatch(rb'[0-9a-fA-F]{4,8}', parts[0]) is not None and
          re.fullmatch(rb'[0-9a-fA-F]{1,16}', parts[1]) is not None,
          'database_quarantine_malformed')
    return parts[0]


def _decode_state(value):
    _need(isinstance(value, dict) and set(value) == {'present', 'length', 'sha256', 'rawBase64'} and
          type(value['present']) is bool and type(value['length']) is int and
          0 <= value['length'] <= 65536, 'invalid_database_quarantine_proof_state')
    if not value['present']:
        _need(value['length'] == 0 and value['sha256'] is None and value['rawBase64'] is None,
              'invalid_database_quarantine_proof_absence')
        return None
    try:
        raw = base64.b64decode(value['rawBase64'], validate=True)
    except (ValueError, TypeError):
        raise PrivateDatabaseMetadataError('invalid_database_quarantine_proof_base64')
    _need(base64.b64encode(raw).decode('ascii') == value['rawBase64'] and _state(raw) == value,
          'database_quarantine_proof_raw_mismatch')
    return raw


def verify_quarantine_proof(proof, source_metadata, native_metadata):
    """Pure receipt verification; never compares an active database's inode."""
    fields = {'schemaVersion', 'kind', 'source', 'before', 'after', 'firstFlagsBase64',
              'firstFlagsExact', 'outcome', 'targetIdentity', 'sourceIdentity',
              'sourceUnchanged', 'allOtherMetadataUnchanged', 'sourceFDReadOnly',
              'targetFDWasExclusivelyCreated'}
    _need(isinstance(proof, dict) and set(proof) == fields and
          type(proof['schemaVersion']) is int and proof['schemaVersion'] == 1 and
          proof['kind'] == 'PrivateDatabaseQuarantinePreserved', 'invalid_database_quarantine_proof')
    for field in ('firstFlagsExact', 'sourceUnchanged', 'allOtherMetadataUnchanged',
                  'sourceFDReadOnly', 'targetFDWasExclusivelyCreated'):
        _need(proof[field] is True, 'database_quarantine_proof_gate_missing')
    for field in ('targetIdentity', 'sourceIdentity'):
        value = proof[field]
        _need(isinstance(value, dict) and set(value) == {'device', 'inode'} and
              all(type(v) is int and v >= 0 for v in value.values()) and value['inode'] > 0,
              'invalid_database_quarantine_proof_identity')
    _need(proof['targetIdentity'] != proof['sourceIdentity'], 'database_quarantine_proof_same_inode')
    source, before, after = [_decode_state(proof[x]) for x in ('source', 'before', 'after')]
    _need(after == source, 'database_quarantine_proof_after_not_original')
    for metadata in (source_metadata, native_metadata):
        _need(isinstance(metadata, dict) and isinstance(metadata.get('xattrs'), dict) and
              (QUARANTINE.decode() in metadata['xattrs']) == (source is not None) and
              metadata['xattrs'].get(QUARANTINE.decode()) == _state(source)['sha256'],
              'database_quarantine_proof_metadata_mismatch')
    if source == before:
        expected = 'both_absent' if source is None else 'already_exact'
        _need(proof['outcome'] == expected, 'database_quarantine_proof_false_write_claim')
        flags = None
        if source is not None:
            try: flags = _flags(source)
            except PrivateDatabaseMetadataError: pass
    else:
        _need(source is not None and before is not None,
              'database_quarantine_proof_presence_changed')
        flags = _flags(source)
        _need(flags == _flags(before) and
              proof['outcome'] == 'restored_exact_source_raw_same_initial_flags',
              'database_quarantine_proof_flags_or_outcome_changed')
    expected_flags = None if flags is None else base64.b64encode(flags).decode('ascii')
    _need(proof['firstFlagsBase64'] == expected_flags, 'database_quarantine_proof_flags_changed')
    return True


class _DarwinQuarantine:
    def __init__(self):
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.lib.fgetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                                      ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        self.lib.fgetxattr.restype = ctypes.c_ssize_t
        self.lib.fsetxattr.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p,
                                      ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        self.lib.fsetxattr.restype = ctypes.c_int

    def read(self, fd):
        size = self.lib.fgetxattr(fd, QUARANTINE, None, 0, 0, 0)
        if size < 0:
            _need(ctypes.get_errno() == getattr(errno, 'ENOATTR', 93),
                  'database_quarantine_read_failed')
            return None
        _need(size <= 65536, 'database_quarantine_size_unexpected')
        value = ctypes.create_string_buffer(max(size, 1))
        _need(self.lib.fgetxattr(fd, QUARANTINE, value, size, 0, 0) == size,
              'database_quarantine_changed_during_read')
        return value.raw[:size]

    def write(self, fd, raw):
        value = ctypes.create_string_buffer(raw, max(len(raw), 1))
        _need(self.lib.fsetxattr(fd, QUARANTINE, value, len(raw), 0, 0) == 0,
              'database_quarantine_restore_failed')


class DatabaseTemporary:
    """Own a readonly source FD and a fresh O_EXCL SQL target FD until close()."""
    def __init__(self, api, source, target, backend=None):
        self.api, self.source, self.target = api, Path(source), Path(target)
        self.source_fd = self.target_fd = None
        self._owned = {}; self.backend = backend
        self._restored = False
        try:
            api.safe_path(str(self.source))
            api.safe_path(str(self.target), exists=False)
            _need(self.source != self.target and self.source.parent == self.target.parent and
                  re.fullmatch(re.escape(self.source.name) + r'\.coherent-[0-9a-f]{12}', self.target.name)
                  is not None, 'database_temporary_path_boundary_refused')
            _need(stat.S_ISREG(self.source.lstat().st_mode), 'database_source_not_regular')
            self.source_fd = os.open(self.source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            self._owned[self.source_fd] = _identity(os.fstat(self.source_fd))
            _need(stat.S_ISREG(os.fstat(self.source_fd).st_mode), 'database_source_not_regular')
            _need(fcntl.fcntl(self.source_fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY,
                  'database_source_fd_not_readonly')
            self.source_identity = copy.deepcopy(self._owned[self.source_fd])
            source_stat = os.fstat(self.source_fd)
            self.source_revision = (source_stat.st_size, source_stat.st_mtime_ns)
            self.source_metadata = copy.deepcopy(api.metadata(self.source))
            self.target_fd = os.open(self.target, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            self._owned[self.target_fd] = _identity(os.fstat(self.target_fd))
            self.target_identity = copy.deepcopy(self._owned[self.target_fd])
            self.assert_bound()
        except BaseException:
            self.close()
            raise

    @property
    def fd(self):
        return self.target_fd

    def assert_bound(self):
        _need(self.source_fd is not None and self.target_fd is not None,
              'database_temporary_already_closed')
        try:
            _need(fcntl.fcntl(self.source_fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY,
                  'database_source_fd_not_readonly')
            _need(fcntl.fcntl(self.target_fd, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDWR,
                  'database_target_fd_not_readwrite')
        except OSError:
            raise PrivateDatabaseMetadataError('database_temporary_identity_unavailable')
        for fd, path, expected in ((self.source_fd, self.source, self.source_identity),
                                   (self.target_fd, self.target, self.target_identity)):
            try:
                held = os.fstat(fd); current = path.lstat()
            except OSError:
                raise PrivateDatabaseMetadataError('database_temporary_identity_unavailable')
            _need(stat.S_ISREG(held.st_mode) and stat.S_ISREG(current.st_mode) and
                  _identity(held) == _identity(current) == expected,
                  'database_temporary_fd_or_path_changed')
        _need(self.source_identity != self.target_identity and os.fstat(self.target_fd).st_nlink == 1,
              'database_temporary_hardlink_or_same_inode')
        source_stat = os.fstat(self.source_fd)
        _need((source_stat.st_size, source_stat.st_mtime_ns) == self.source_revision,
              'database_source_changed')
        _need(self.api.metadata(self.source) == self.source_metadata, 'database_source_metadata_changed')

    def restore_quarantine(self):
        _need(not self._restored, 'database_quarantine_restore_already_attempted')
        self._restored = True
        self.assert_bound()
        backend = self.backend if self.backend is not None else _DarwinQuarantine()
        source = backend.read(self.source_fd); before = backend.read(self.target_fd)
        source_metadata = copy.deepcopy(self.api.metadata(self.source))
        target_metadata = copy.deepcopy(self.api.metadata(self.target))
        _need(source_metadata == self.source_metadata, 'database_source_metadata_changed')
        source_hash = source_metadata.get('xattrs', {}).get(QUARANTINE.decode())
        target_hash = target_metadata.get('xattrs', {}).get(QUARANTINE.decode())
        _need(source_hash == _state(source)['sha256'] and target_hash == _state(before)['sha256'],
              'database_quarantine_metadata_state_mismatch')
        flags = None
        if source == before:
            outcome = 'both_absent' if source is None else 'already_exact'
        else:
            _need(source is not None and before is not None,
                  'database_quarantine_presence_mismatch')
            source_flags, target_flags = _flags(source), _flags(before)
            _need(source_flags == target_flags, 'database_quarantine_flags_mismatch')
            flags = source_flags
            self.assert_bound()
            _need(backend.read(self.source_fd) == source and backend.read(self.target_fd) == before,
                  'database_quarantine_changed_before_restore')
            # Only the newly owned target FD is writable. Never remove an attr.
            backend.write(self.target_fd, source)
            os.fsync(self.target_fd)
            outcome = 'restored_exact_source_raw_same_initial_flags'
        self.assert_bound()
        after = backend.read(self.target_fd)
        _need(backend.read(self.source_fd) == source and after == source,
              'database_quarantine_restore_readback_mismatch')
        after_metadata = copy.deepcopy(self.api.metadata(self.target))
        expected_metadata = copy.deepcopy(target_metadata)
        if source is None:
            _need(QUARANTINE.decode() not in expected_metadata.get('xattrs', {}),
                  'database_quarantine_absence_mismatch')
        else:
            expected_metadata['xattrs'][QUARANTINE.decode()] = _state(source)['sha256']
        _need(after_metadata == expected_metadata and self.api.metadata(self.source) == source_metadata,
              'database_quarantine_restore_changed_other_metadata')
        if flags is None and source is not None:
            try: flags = _flags(source)
            except PrivateDatabaseMetadataError: pass  # Exact raw equality requires no mutation.
        return {'schemaVersion': 1, 'kind': 'PrivateDatabaseQuarantinePreserved',
                'source': _state(source), 'before': _state(before), 'after': _state(after),
                'firstFlagsBase64': None if flags is None else base64.b64encode(flags).decode('ascii'),
                'firstFlagsExact': source == before or flags is not None, 'outcome': outcome,
                'targetIdentity': copy.deepcopy(self.target_identity),
                'sourceIdentity': copy.deepcopy(self.source_identity),
                'sourceUnchanged': True, 'allOtherMetadataUnchanged': True,
                'sourceFDReadOnly': True, 'targetFDWasExclusivelyCreated': True}

    def close(self):
        for name in ('target_fd', 'source_fd'):
            fd = getattr(self, name, None)
            setattr(self, name, None)
            if fd is not None:
                try:
                    if _identity(os.fstat(fd)) == self._owned.get(fd):
                        os.close(fd)
                except OSError:
                    pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
