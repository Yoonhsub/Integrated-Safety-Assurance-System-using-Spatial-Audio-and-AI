"""Explicit cloud-test stages and a local, non-secret resource ownership journal.

No SDK, credentials or network activity is performed on import. A journal is not
an IAM boundary: callers still need separately approved short-lived IAM grants.
"""
from __future__ import annotations

from contextlib import contextmanager
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from uuid import uuid4

from app.cloud_test import CloudTestConfigurationError, account_allowed

STAGES = ('preflight', 'auth-bootstrap', 'rtdb-bootstrap', 'backend-smoke',
          'flutter-smoke', 'cleanup', 'auth-reuse-check', 'ride-smoke')
NAMES = ('passenger-a', 'passenger-b', 'driver-a', 'driver-b')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True)


def conditional_delete_rest(reference, url, credential, expected):
    """Public SDK read + REST CAS delete (SDK 6.6 transaction rejects None).

    The caller pins the URL and identity. No redirect, retry, unconditional delete
    or exception containing a provider response is exposed to the CLI.
    """
    from google.auth.transport.requests import Request
    import requests
    from requests.adapters import HTTPAdapter
    raw, etag = reference.get(etag=True)
    if raw is None:
        return
    if canonical(raw) != canonical(expected) or not isinstance(etag, str) or not etag:
        raise CloudTestConfigurationError('Record changed or ETag is missing; deletion refused')
    headers = {'If-Match': etag}
    credential.before_request(Request(), 'DELETE', url, headers)
    with requests.Session() as session:
        session.trust_env = False
        session.mount('https://', HTTPAdapter(max_retries=0))
        session.mount('http://', HTTPAdapter(max_retries=0))
        response = session.delete(url, headers=headers, timeout=(5, 10), allow_redirects=False)
        if response.status_code != 200:
            raise CloudTestConfigurationError('Conditional record deletion failed; no retry')
        if response.json() is not None:
            raise CloudTestConfigurationError('Unexpected conditional deletion response')


def exact_accounts(config):
    run = config.get('authRunId',config['runId'])
    result = []
    for name in NAMES:
        uid = f'ct-{run}-{name}'
        role = 'passenger' if name.startswith('passenger') else 'driver'
        claims = {'mobi_role': role, 'mobi_cloud_test_run': run}
        if role == 'driver':
            claims['mobi_driver_id'] = f'ct-{run}-driver-' + ('502' if name == 'driver-a' else '105')
        result.append({'uid': uid, 'email': uid + '@example.test', 'claims': claims})
    return result


class Journal:
    """Atomic local snapshots plus an exclusive lock across whole stage runs.

    Intent is flushed BEFORE a remote mutation. A lost create acknowledgement is
    recorded as uncertain; it is never permission to adopt a pre-existing user.
    Markers and configHash are diagnostic only, never independent deletion authority.
    """
    def __init__(self, path, config, case_id, repository):
        self.path = Path(path).resolve()
        repo = Path(repository).resolve()
        if self.path.is_relative_to(repo) or repo.is_relative_to(self.path):
            raise CloudTestConfigurationError('Keep the private execution journal outside the repository')
        self.identity = {'version': 1, 'projectId': config['projectId'],
                         'databaseUrl': config['databaseUrl'], 'runId': config['runId'], 'caseId': case_id}
        self.config_hash = hashlib.sha256(canonical(config).encode()).hexdigest()
        self.data = None

    @contextmanager
    def locked(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        lock = self.path.with_suffix(self.path.suffix + '.lock')
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise CloudTestConfigurationError('A stage is running or a stale journal lock needs manual review') from None
        try:
            os.close(fd)
            if self.path.exists():
                self.data = json.loads(self.path.read_text(encoding='utf-8'))
                if (self.data.get('identity') != self.identity
                        or self.data.get('configHash') != self.config_hash
                        or not re.fullmatch(r'[0-9a-f]{32}', self.data.get('executionId', ''))):
                    raise CloudTestConfigurationError('Journal does not match this exact project/run/config/case')
            else:
                self.data = {'identity': self.identity, 'configHash': self.config_hash,
                             'executionId': uuid4().hex, 'accounts': {}, 'records': {},
                             'stages': {}, 'pendingSession': False}
                self.save()
            yield self
        finally:
            lock.unlink()

    def save(self):
        fd, name = tempfile.mkstemp(prefix=self.path.name + '.', dir=self.path.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                json.dump(self.data, handle, sort_keys=True, indent=2)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


class Lifecycle:
    def __init__(self, cli, config, case_id, journal_path, *, auth_client=None, storage=None):
        self.cli, self.config, self.case_id = cli, config, case_id
        self.scope = cli.configure(config)
        self.accounts = exact_accounts(config)
        supplied, drivers, manifest = cli.fixture(config)
        if canonical(supplied) != canonical(self.accounts) or not all(
                account_allowed(a['uid'], a['claims'], self.scope) for a in self.accounts):
            raise CloudTestConfigurationError('Exactly two passengers and two drivers are required; admin is forbidden')
        self.drivers, self.manifest = drivers, manifest
        self.journal = Journal(journal_path, config, case_id, cli.ROOT.parent)
        self._auth, self._storage = auth_client, storage
        # Volatile evidence from a successful absent->created transaction in THIS
        # process. Never serialize or reconstruct it from journal fields/markers.
        # A separate cleanup CLI process has no evidence and must fail closed.
        self._record_receipts = {}

    @property
    def auth(self):
        if self._auth is None:
            from firebase_admin import auth
            from app.security import firebase_auth_app
            app = firebase_auth_app()
            class BoundAuth:
                pass
            self._auth = BoundAuth()
            for name in ('get_user', 'get_user_by_email', 'create_user', 'set_custom_user_claims'):
                method = getattr(auth, name)
                setattr(self._auth, name, lambda *a, _method=method, **kw: _method(*a, app=app, **kw))
        return self._auth

    @property
    def storage(self):
        if self._storage is None:
            from app.services.firebase_client import get_firebase_client
            self._storage = get_firebase_client()
            if not self._storage.initialize() or self._storage.using_mock:
                raise CloudTestConfigurationError('Real storage is required; memory fallback is forbidden')
        return self._storage

    @property
    def marker(self):
        return 'MOBI isolated cloud-test ' + self.scope.run_id + ' ' + self.journal.data['executionId']

    def lookup(self, method, value):
        from firebase_admin.auth import UserNotFoundError
        try:
            return getattr(self.auth, method)(value)
        except UserNotFoundError:
            return None

    def owned_user(self, account, user, entry):
        if not isinstance(entry, dict) or entry.get('account') != account:
            return False
        created = getattr(getattr(user, 'user_metadata', None), 'creation_timestamp', None)
        return (getattr(user, 'uid', None) == account['uid']
                and user.email == account['email'] and user.display_name == self.marker
                and (entry.get('createdAt') is None or created == entry['createdAt'])
                and canonical(user.custom_claims or {}) in (canonical({}), canonical(account['claims'])))

    def auth_preflight(self):
        for account in self.accounts:
            uid, email = account['uid'], account['email']
            user = self.lookup('get_user', uid)
            by_email = self.lookup('get_user_by_email', email)
            entry = self.journal.data['accounts'].get(uid)
            if user is not None:
                if (not self.owned_user(account, user, entry) or entry.get('state') != 'claims-set'
                        or canonical(user.custom_claims) != canonical(account['claims'])
                        or user.disabled or by_email is None or by_email.uid != uid):
                    raise CloudTestConfigurationError('Existing UID collision or incomplete prior creation; do not overwrite claims')
            elif by_email is not None:
                raise CloudTestConfigurationError('Existing email collision; no account will be created')
            elif entry is not None:
                raise CloudTestConfigurationError('Journal account is absent; use a new run after cleanup')

    def initial_records(self):
        tag = {'_cloudTestExecution': self.journal.data['executionId']}
        return {self.scope.path: {**deepcopy(self.manifest), **tag},
                **{'/drivers/' + key: {**deepcopy(value), **tag} for key, value in self.drivers.items()}}

    def allow_path(self, logical):
        if logical in self.initial_records():
            return
        rid = self.cli.plan(self.config, self.case_id)['requestId']
        if logical == '/rideRequests/' + rid:
            return
        if not self.scope.ride_only and re.fullmatch(r'/v3GuidanceSessions/v3-[0-9a-f]{32}', logical or ''):
            return
        raise CloudTestConfigurationError('Record path is outside this exact execution allowlist')

    def database_preflight(self):
        if self.scope.ride_only:
            paths = [*self.initial_records(), '/rideRequests/' + self.scope.request_id]
            for logical in paths:
                if self.storage.get(logical) is not None:
                    raise CloudTestConfigurationError('Existing RTDB collision at ' + self.scope.storage_path(logical))
            return
        for logical, value in self.initial_records().items():
            existing = self.storage.get(logical)
            entry = self.journal.data['records'].get(logical)
            if existing is not None and (entry is None or canonical(existing) != canonical(value)
                                         or canonical(entry.get('expected')) != canonical(value)):
                raise CloudTestConfigurationError('Existing RTDB record collision; no write performed')

    def preflight(self):
        if self.scope.ride_only:
            self.auth_reuse_check()
        else:
            self.auth_preflight()
        self.database_preflight()
        return {'status': 'PASS', 'checkedAccounts': 4, 'checkedRecords': 4 if self.scope.ride_only else 3, 'writes': 0}

    def auth_reuse_check(self):
        if not self.scope.ride_only:
            raise CloudTestConfigurationError('Existing Auth check requires reviewed ride-only mode')
        for account in self.accounts:
            user = self.lookup('get_user', account['uid'])
            email_user = self.lookup('get_user_by_email', account['email'])
            if (user is None or email_user is None or user.uid != account['uid']
                    or user.email != account['email'] or email_user.uid != user.uid
                    or user.disabled or canonical(user.custom_claims or {}) != canonical(account['claims'])):
                raise CloudTestConfigurationError('Existing approved account differs; no mutation allowed')
        return {'status':'PASS','accountsVerified':4,'authMutations':0}

    def auth_bootstrap(self, password):
        if self.scope.ride_only:
            raise CloudTestConfigurationError('Auth creation and Claims changes forbidden in reuse mode')
        # Firebase Auth exposes no conditional Claims update tied to creation
        # identity/version. Rechecking cannot close the final TOCTOU interval.
        # Do not expose that write race in the shared main project.
        if self.scope.main_project_test:
            raise CloudTestConfigurationError(
                'Main-project Auth provisioning is blocked: atomic claims ownership cannot be guaranteed')
        if not isinstance(password, str) or len(password) < 20:
            raise CloudTestConfigurationError('Use a unique test password of at least 20 characters')
        self.auth_preflight()  # Check ALL UID/email collisions before the FIRST mutation.
        for account in self.accounts:
            uid = account['uid']
            if uid in self.journal.data['accounts']:
                continue  # Exact completed retries are read-only. Never rewrite existing claims.
            entry = {'account': account, 'state': 'intent'}
            self.journal.data['accounts'][uid] = entry
            self.journal.save()
            user = self.auth.create_user(uid=uid, email=account['email'], password=password,
                                         display_name=self.marker)
            entry['createdAt'] = getattr(getattr(user, 'user_metadata', None), 'creation_timestamp', None)
            entry['state'] = 'created'
            self.journal.save()
            if type(entry['createdAt']) is not int or entry['createdAt'] <= 0:
                raise CloudTestConfigurationError('Account creation timestamp is unconfirmed; claims not changed')
            user = self.lookup('get_user', uid)
            if user is None or not self.owned_user(account, user, entry) or user.custom_claims:
                raise CloudTestConfigurationError('New account changed before provisioning; claims not overwritten')
            self.auth.set_custom_user_claims(uid, account['claims'])
            user = self.lookup('get_user', uid)
            if (user is None or not self.owned_user(account, user, entry)
                    or canonical(user.custom_claims) != canonical(account['claims'])):
                raise CloudTestConfigurationError('Custom claims read-back failed')
            entry['state'] = 'claims-set'
            self.journal.save()
        return {'status': 'PASS', 'accounts': 4, 'passwordsPrinted': False}

    def create_record(self, logical, expected):
        self.allow_path(logical)
        records = self.journal.data['records']
        entry = records.get(logical)
        if entry is not None and canonical(entry.get('expected')) != canonical(expected):
            raise CloudTestConfigurationError('Journal record payload changed')
        if entry is not None and entry.get('state') == 'verified':
            if canonical(self.storage.get(logical)) != canonical(expected):
                raise CloudTestConfigurationError('Previously verified record changed; refusing recreation')
            return  # A completed duplicate stage verifies only; it does not write again.
        if entry is None:
            records[logical] = entry = {'state': 'intent', 'expected': deepcopy(expected),
                                       'physicalPath': self.scope.storage_path(logical)}
            self.journal.save()
        created_absent = False
        def create(raw):
            nonlocal created_absent
            created_absent = raw is None
            if raw is not None and (self.scope.ride_only or canonical(raw) != canonical(expected)):
                raise CloudTestConfigurationError('RTDB create collision; refusing overwrite')
            return expected
        self.storage.transaction(logical, create)
        if canonical(self.storage.get(logical)) != canonical(expected):
            raise CloudTestConfigurationError('RTDB create read-back failed')
        entry['state'] = 'verified'
        self.journal.save()
        if created_absent:
            self._record_receipts[logical] = (
                self.journal.data['executionId'], self.scope.storage_path(logical), canonical(expected))

    def rtdb_bootstrap(self):
        if self.scope.ride_only:
            self.auth_reuse_check()  # Do not trust a journal stage flag as identity evidence.
        elif self.journal.data['stages'].get('auth-bootstrap') != 'PASS':
            raise CloudTestConfigurationError('Complete auth-bootstrap first')
        self.database_preflight()
        records = self.initial_records()
        for logical in records:
            if logical != self.scope.path:
                self.create_record(logical, records[logical])
        self.create_record(self.scope.path, records[self.scope.path])
        return {'status': 'PASS', 'records': 3}

    def record_backend_result(self, logical, response_value):
        self.allow_path(logical)
        entry = self.journal.data['records'].get(logical)
        if entry is None:
            raise CloudTestConfigurationError('Backend mutation has no prior execution intent')
        raw = self.storage.get(logical)
        if logical.startswith('/v3GuidanceSessions/'):
            if canonical(raw) != canonical(response_value):
                raise CloudTestConfigurationError('Session HTTP success did not persist its RTDB snapshot')
        else:
            if not isinstance(raw, dict) or any(raw.get(k) != response_value.get(k) for k in
                    ('userId', 'stopId', 'routeId', 'busNo', 'targetDriverId', 'status')):
                raise CloudTestConfigurationError('Ride HTTP success did not persist the approved record')
            if raw.get('userId') != self.accounts[0]['uid']:
                raise CloudTestConfigurationError('Ride ownership mismatch')
        entry['expected'] = raw
        entry['state'] = 'verified'
        self.journal.save()

    def backend_intent(self, logical):
        self.allow_path(logical)
        self.journal.data['records'].setdefault(logical, {
            'state': 'intent', 'expected': None, 'physicalPath': self.scope.storage_path(logical)})
        self.journal.save()

    def flutter_smoke(self, evidence=None):
        # An HTTP test cannot assert browser login/visual behaviour.
        if evidence is None:
            return {'status': 'NOT_VERIFIED', 'reason': 'Manual browser verification required',
                    'passengerUrl': f'http://127.0.0.1:{self.config["passengerPort"]}',
                    'driverUrl': f'http://127.0.0.1:{self.config["driverPort"]}'}
        raise CloudTestConfigurationError('Automatic/manual evidence import is not supported')

    def has_creation_receipt(self, logical, expected):
        # Session snapshots and backend readbacks have no independent durable
        # creation receipt. Their IDs remain diagnostic/manual recovery targets.
        return self._record_receipts.get(logical) == (
            self.journal.data['executionId'], self.scope.storage_path(logical), canonical(expected))

    def delete_record(self, logical, expected):
        self.allow_path(logical)
        if not self.has_creation_receipt(logical, expected):
            raise CloudTestConfigurationError('Independent creation evidence missing; manual cleanup approval required')
        if hasattr(self.storage, 'delete_if_unchanged'):
            return self.storage.delete_if_unchanged(logical, expected)
        from app.services.firebase_client import FirebaseClient, InMemoryRealtimeDatabase
        if isinstance(self.storage, InMemoryRealtimeDatabase) or (
                isinstance(self.storage, FirebaseClient) and self.storage.using_mock):
            def delete(current):
                if current is not None and canonical(current) != canonical(expected):
                    raise CloudTestConfigurationError('Record changed during cleanup; deletion refused')
                return None
            return self.storage.transaction(logical, delete)
        if not isinstance(self.storage, FirebaseClient):
            raise CloudTestConfigurationError('Storage has no safe conditional deletion implementation')
        import google.auth
        from google.auth import impersonated_credentials
        credential, project = google.auth.default(scopes=[
            'https://www.googleapis.com/auth/firebase.database', 'https://www.googleapis.com/auth/userinfo.email'])
        target = f'mobi-ct-cleanup@{self.scope.project_id}.iam.gserviceaccount.com'
        if (not isinstance(credential, impersonated_credentials.Credentials)
                or credential.service_account_email != target or project != self.scope.project_id):
            raise CloudTestConfigurationError('Cleanup requires the approved Cleanup impersonated identity')
        reference = self.storage._real_reference(logical)  # Reuses project/URL/path revalidation.
        url = self.scope.database_url.rstrip('/') + self.scope.storage_path(logical) + '.json'
        return conditional_delete_rest(reference, url, credential, expected)

    def cleanup(self):
        outcomes = []
        allowed_accounts = {a['uid']: a for a in self.accounts}
        # Validate the WHOLE journal before any destructive operation.
        if len(self.journal.data['accounts']) > 4:
            raise CloudTestConfigurationError('Journal exceeds the four-account limit')
        for uid, entry in self.journal.data['accounts'].items():
            if uid not in allowed_accounts or entry.get('account') != allowed_accounts[uid]:
                raise CloudTestConfigurationError('Journal contains an unapproved account')
        for logical, entry in self.journal.data['records'].items():
            self.allow_path(logical)
            physical = self.scope.storage_path(logical)
            if physical.rstrip('/') in {'', '/'}:
                raise CloudTestConfigurationError('Deleting a run parent is forbidden; review legacy storage layouts separately')
            if entry.get('physicalPath') != physical:
                raise CloudTestConfigurationError('Journal contains an invalid physical path')
        if (len(self.journal.data['records']) > 5
                or sum(p.startswith('/v3GuidanceSessions/') for p in self.journal.data['records']) > 1):
            raise CloudTestConfigurationError('Journal exceeds the approved five records or single session')
        for logical, entry in self.journal.data['records'].items():
            if (entry['physicalPath'].rstrip('/') == self.scope.path.rstrip('/')
                    or not self.has_creation_receipt(logical, entry.get('expected'))):
                outcomes.append({'kind': 'rtdb', 'target': entry['physicalPath'],
                                 'status': 'MANUAL_REQUIRED', 'reason': 'No independent creation evidence'})
                continue  # Do not let an edited journal authorize a data request.
            try:
                raw = self.storage.get(logical)
                if raw is not None:
                    expected = entry.get('expected')
                    if expected is None or canonical(raw) != canonical(expected):
                        raise CloudTestConfigurationError('Record ownership/read-back is unconfirmed; deletion refused')
                    self.delete_record(logical, expected)
                if self.storage.get(logical) is not None:
                    raise CloudTestConfigurationError('Record deletion is unconfirmed')
                entry['state'] = 'deleted'
                self.journal.save()
                outcomes.append({'kind': 'rtdb', 'target': entry['physicalPath'], 'status': 'PASS'})
            except Exception as exc:
                outcomes.append({'kind': 'rtdb', 'target': entry['physicalPath'], 'status': 'FAILED', 'errorType': type(exc).__name__})
        for uid in self.journal.data['accounts']:
            # No Auth GET/DELETE is attempted. Firebase Auth has no conditional
            # delete; even a fresh ownership lookup cannot prevent UID replacement.
            outcomes.append({'kind': 'auth', 'target': uid, 'status': 'MANUAL_REQUIRED',
                             'reason': 'Automatic Auth deletion disabled; separate approval required'})
        if self.journal.data['pendingSession']:
            outcomes.append({'kind': 'session', 'target': 'unacknowledged-session-creation', 'status': 'FAILED'})
        failed = sum(item['status'] != 'PASS' for item in outcomes)
        status = 'PASS' if not failed else 'FAILED' if all(item['status'] == 'FAILED' for item in outcomes) else 'PARTIAL'
        result = {'status': status, 'resources': outcomes}
        self.journal.data['cleanupResult'] = result
        self.journal.save()
        return result

    def run(self, stage, password=None):
        if stage not in STAGES:
            raise CloudTestConfigurationError('Unknown lifecycle stage')
        with self.journal.locked():
            try:
                if self.journal.data.get('cleanupStarted') and stage != 'cleanup':
                    raise CloudTestConfigurationError('Cleanup started; this run cannot create or replay resources')
                if stage == 'cleanup':
                    self.journal.data['cleanupStarted'] = True
                    self.journal.save()
                if stage == 'auth-bootstrap':
                    result = self.auth_bootstrap(password)
                elif stage in {'backend-smoke','ride-smoke'}:
                    if (stage == 'ride-smoke') != self.scope.ride_only:
                        raise CloudTestConfigurationError('Smoke stage differs from the approved execution mode')
                    if self.scope.ride_only:
                        self.auth_reuse_check()
                    if self.journal.data['stages'].get('rtdb-bootstrap') != 'PASS':
                        raise CloudTestConfigurationError('Complete rtdb-bootstrap first')
                    if self.journal.data['stages'].get(stage) == 'PASS':
                        result = {'status': 'HISTORICAL_PASS', 'currentVerification': 'NOT_VERIFIED', 'reused': True, 'newRequests': 0}
                        self.journal.data['lastAttempt'] = {'stage': stage, **result}
                        self.journal.save()
                        return result
                    result = self.cli.smoke(self.config, password, self.case_id, lifecycle=self)
                    result['status'] = 'PASS'
                else:
                    result = getattr(self, stage.replace('-', '_'))()
                self.journal.data['lastAttempt'] = {'stage': stage, 'status': result['status']}
                self.journal.data['stages'][stage] = result['status']
                self.journal.save()
                return result
            except Exception as exc:
                self.journal.data['stages'][stage] = 'FAILED'
                self.journal.data['lastFailure'] = {'stage': stage, 'errorType': type(exc).__name__}
                self.journal.save()
                raise
