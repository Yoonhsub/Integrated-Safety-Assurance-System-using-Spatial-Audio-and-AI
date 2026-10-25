"""Explicit local-backend / real test-project boundary. No network on import."""
import hashlib
import json
from dataclasses import dataclass
import os
import re
from urllib.parse import urlsplit
from types import MappingProxyType

MAIN_PROJECT_ID = 'mobi-smart-transport'
MAIN_DATABASE_URL = 'https://mobi-smart-transport-default-rtdb.asia-southeast1.firebasedatabase.app/'
# Public registration identifiers recovered from the saved Console configuration.
# The full Driver value was reconfirmed by the user on 2026-10-21.
MAIN_WEB_APP_IDS = {
    'passenger': '1:882602390759:web:461d3d1331226ae71e1e42',
    'driver': '1:882602390759:web:d1c4863d29510afc1e1e42',
}

# Firebase Console configs supplied by the user on 2026-10-23 and reviewed
# offline. No Firebase metadata, Auth, RTDB or ADC calls were made to attest them.
# Only public Web identifiers are stored here, never Admin/ADC credentials.
# The run config, journal, CLI flags and environment cannot populate this map.
CONFIRMED_TEST_PROJECTS = MappingProxyType({
    'mobi-auth-cloud-test': {
        'projectId': 'mobi-auth-cloud-test',
        'databaseUrl': 'https://mobi-auth-cloud-test-default-rtdb.asia-southeast1.firebasedatabase.app',
        'passenger': {
            'MOBI_FIREBASE_API_KEY': 'AIzaSyAfKjXX3LtVE9iaVmcSjXKxl0VIu1x6hAU',
            'MOBI_FIREBASE_APP_ID': '1:189730626159:web:407d25db8c026703170b9a',
            'MOBI_FIREBASE_MESSAGING_SENDER_ID': '189730626159',
            'MOBI_FIREBASE_PROJECT_ID': 'mobi-auth-cloud-test',
            'MOBI_FIREBASE_AUTH_DOMAIN': 'mobi-auth-cloud-test.firebaseapp.com',
        },
        'driver': {
            'MOBI_FIREBASE_API_KEY': 'AIzaSyAfKjXX3LtVE9iaVmcSjXKxl0VIu1x6hAU',
            'MOBI_FIREBASE_APP_ID': '1:189730626159:web:b486ec4c18abf663170b9a',
            'MOBI_FIREBASE_MESSAGING_SENDER_ID': '189730626159',
            'MOBI_FIREBASE_PROJECT_ID': 'mobi-auth-cloud-test',
            'MOBI_FIREBASE_AUTH_DOMAIN': 'mobi-auth-cloud-test.firebaseapp.com',
        },
    },
})
# Reviewed existing identities may be reused only with this exact data run/case.
# CLI config, environment and journals cannot extend this source allowlist.
REVIEWED_REUSE_RUNS = MappingProxyType({
    ('mobi-auth-cloud-test', 'rtdb-20261025-6e9a7c42'):
        ('auth-20261023-919e07bd', 'ride-e2e-01'),
})
MAIN_SENDER_ID = '882602390759'
WEB_CONFIG_KEYS = {'MOBI_FIREBASE_API_KEY', 'MOBI_FIREBASE_APP_ID',
                   'MOBI_FIREBASE_MESSAGING_SENDER_ID', 'MOBI_FIREBASE_PROJECT_ID',
                   'MOBI_FIREBASE_AUTH_DOMAIN'}


OPERATIONS = {
    ('POST','/ride-requests'), ('GET','/ride-requests/{requestId}'),
    ('PATCH','/ride-requests/{requestId}/status'), ('GET','/drivers/{driverId}/ride-requests'),
    ('GET','/driver/ride-requests'), ('PATCH','/driver/ride-requests/{requestId}/status'),
    ('POST','/guidance/session'), ('GET','/guidance/state'), ('POST','/guidance/reset'),
    ('GET','/firebase/status'), ('POST','/firebase/initialize'),
    ('GET','/ai-vision/v2/sessions/{sessionId}/observations'), ('POST','/config/data-mode'),
}


class CloudTestConfigurationError(ValueError):
    """Only fixed, non-sensitive configuration messages may use this type."""


def confirmed_project(project_id: str) -> dict:
    """Offline reviewed registration, not a cloud metadata attestation.

    Trust comes from separately reviewing the source registry. A verified=true
    field or a hash in an execution config is not sufficient evidence.
    """
    entry = CONFIRMED_TEST_PROJECTS.get(project_id)
    if (not isinstance(entry, dict)
            or set(entry) != {'projectId', 'databaseUrl', 'passenger', 'driver'}
            or entry.get('projectId') != project_id):
        raise CloudTestConfigurationError('Test-project Console registration is unconfirmed; execution blocked')
    apps = [entry.get(name) for name in ('passenger', 'driver')]
    if any(not isinstance(app, dict) or set(app) != WEB_CONFIG_KEYS for app in apps):
        raise CloudTestConfigurationError('Reviewed Web registration is incomplete')
    for app in apps:
        app_id = app.get('MOBI_FIREBASE_APP_ID')
        match = re.fullmatch(r'1:([0-9]+):web:([a-fA-F0-9]+)', app_id) if isinstance(app_id, str) else None
        if (any(not isinstance(value, str) or not value.strip() or '<' in value for value in app.values())
                or match is None or match.group(1) != app['MOBI_FIREBASE_MESSAGING_SENDER_ID']
                or app['MOBI_FIREBASE_PROJECT_ID'] != project_id
                or app['MOBI_FIREBASE_AUTH_DOMAIN'] != project_id + '.firebaseapp.com'):
            raise CloudTestConfigurationError('Reviewed Web registration has inconsistent fields')
    ids = [app['MOBI_FIREBASE_APP_ID'] for app in apps]
    senders = [app['MOBI_FIREBASE_MESSAGING_SENDER_ID'] for app in apps]
    if ids[0] == ids[1] or senders[0] != senders[1] or MAIN_SENDER_ID in senders:
        raise CloudTestConfigurationError('Reviewed Web registrations have conflicting identities')
    if not isinstance(entry.get('databaseUrl'), str) or not entry['databaseUrl']:
        raise CloudTestConfigurationError('Reviewed database registration is missing')
    return entry


def validate_web_app(config: dict, app_name: str, project_id: str) -> None:
    """Validate public build identities offline; never authenticate or fetch config."""
    app_id = config.get('MOBI_FIREBASE_APP_ID')
    match = re.fullmatch(r'1:([0-9]+):web:([a-fA-F0-9]+)', app_id) if isinstance(app_id, str) else None
    if (app_name not in {'passenger', 'driver'} or match is None
            or config.get('MOBI_FIREBASE_MESSAGING_SENDER_ID') != match.group(1)
            or config.get('MOBI_FIREBASE_PROJECT_ID') != project_id
            or config.get('MOBI_FIREBASE_AUTH_DOMAIN') != project_id + '.firebaseapp.com'):
        raise CloudTestConfigurationError('Invalid or incomplete public Web app identity')
    if project_id == MAIN_PROJECT_ID:
        if app_id != MAIN_WEB_APP_IDS[app_name] or match.group(1) != MAIN_SENDER_ID:
            raise CloudTestConfigurationError('Web app identity differs from the registered passenger/driver mapping')
    else:
        if match.group(1) == MAIN_SENDER_ID or app_id in MAIN_WEB_APP_IDS.values():
            raise CloudTestConfigurationError('Main-project Web identity is forbidden in a test project')
        registered = confirmed_project(project_id)[app_name]
        if config != registered:
            raise CloudTestConfigurationError('Web settings differ from the reviewed project/app registration')


def requested() -> bool:
    return any(key.startswith('MOBI_CLOUD_TEST') and value for key, value in os.environ.items())


@dataclass(frozen=True)
class CloudTestScope:
    project_id: str
    database_url: str
    run_id: str
    main_project_test: bool = False
    auth_run_id: str | None = None
    ride_only: bool = False

    def storage_path(self, path: str) -> str:
        """Map logical application paths into this run; never touch main data."""
        if path == self.path:
            return self.path + '/manifest'
        if (not isinstance(path, str) or not path.startswith('/') or path.startswith('//')
                or path.endswith('/') or '//' in path):
            raise CloudTestConfigurationError('Invalid cloud-test logical storage path')
        parts = path[1:].split('/')
        if (not all(parts) or any(part in {'.', '..'} or
                any(c in part for c in '.#$[]\\') or
                any(ord(c) < 32 or ord(c) == 127 for c in part) for part in parts)
                or parts[0] == 'cloudTestRuns'):
            raise CloudTestConfigurationError('Invalid cloud-test logical storage path')
        if self.ride_only and path not in {
                '/drivers/' + self.uid('driver-502'), '/drivers/' + self.uid('driver-105'),
                '/rideRequests', '/rideRequests/' + self.request_id}:
            raise CloudTestConfigurationError('Path is outside the approved ride-only records')
        return self.path + '/data/' + '/'.join(parts)

    @property
    def path(self):
        return f'/cloudTestRuns/{self.run_id}'

    @property
    def identity_run(self):
        return self.auth_run_id or self.run_id

    @property
    def case_id(self):
        return REVIEWED_REUSE_RUNS[(self.project_id, self.run_id)][1]

    @property
    def idempotency_key(self):
        return f'cloud-test:{self.run_id}:{self.case_id}'

    @property
    def request_id(self):
        identity = json.dumps([self.uid('passenger-a'), self.idempotency_key],
                              ensure_ascii=True, separators=(',', ':'))
        return 'ride-i-' + hashlib.sha256(identity.encode()).hexdigest()

    def uid(self, name):
        return f'ct-{self.identity_run}-{name}'


def validate() -> CloudTestScope:
    # Main-project testing requires a separate exact opt-in, never a suffix bypass.
    # Actual cloud writes still require human approval of the concrete run plan.
    project = os.getenv('MOBI_CLOUD_TEST_PROJECT_ID', '')
    main_flag = os.getenv('MOBI_CLOUD_TEST_MAIN_PROJECT', '')
    main_test = main_flag == 'mobi-smart-transport' and project == main_flag
    if main_flag and not main_test:
        raise CloudTestConfigurationError('Main-project test opt-in must match mobi-smart-transport exactly')
    if not main_test and not re.fullmatch(r'[a-z][a-z0-9-]{3,18}-cloud-test', project):
        raise CloudTestConfigurationError('Cloud-test requires a dedicated project ID ending in -cloud-test')
    registration = None if main_test else confirmed_project(project)
    run = os.getenv('MOBI_CLOUD_TEST_RUN_ID', '')
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{7,23}', run):
        raise CloudTestConfigurationError('Invalid cloud-test run identifier')
    auth_run = os.getenv('MOBI_CLOUD_TEST_AUTH_RUN_ID', '')
    data_run = os.getenv('MOBI_CLOUD_TEST_DATA_RUN_ID', '')
    mode = os.getenv('MOBI_CLOUD_TEST_MODE', '')
    ride_only = bool(auth_run or data_run or mode)
    if not ride_only and (project, run) in REVIEWED_REUSE_RUNS:
        raise CloudTestConfigurationError('Reviewed data run requires explicit Auth reuse mode')
    if ride_only and (main_test or mode != 'ride-only' or data_run != run
            or REVIEWED_REUSE_RUNS.get((project, data_run), (None, None))[0] != auth_run):
        raise CloudTestConfigurationError('Unreviewed Auth/data run binding')
    expected = {
        'MOBI_CLOUD_TEST': '1', 'APP_ENV': 'staging',
        'FIREBASE_PROJECT_ID': project, 'GOOGLE_CLOUD_PROJECT': project,
        'FIREBASE_USE_ADC': 'true', 'FIREBASE_USE_MOCK': 'false',
        'PUBLIC_DATA_USE_MOCK': 'true', 'FCM_ENABLED': 'false', 'FCM_USE_MOCK': 'true',
    }
    if any(os.getenv(k) != v for k, v in expected.items()):
        raise CloudTestConfigurationError('Cloud-test environment is incomplete or inconsistent')
    if os.getenv('MOBI_LOCAL_DEMO') not in (None, '', '0', 'false'):
        raise CloudTestConfigurationError('Cloud-test cannot use the local demo')
    forbidden = ('FIREBASE_AUTH_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST',
                 'FIREBASE_SERVICE_ACCOUNT_PATH', 'K_SERVICE', 'GAE_ENV',
                 'OPENAI_API_KEY', 'GEMINI_API_KEY', 'GOOGLE_API_KEY')
    if any(os.getenv(key) for key in forbidden):
        raise CloudTestConfigurationError('Cloud-test cannot mix emulator, key-file, cloud runtime or paid AI settings')
    url = os.getenv('FIREBASE_DATABASE_URL', '')
    if url != os.getenv('MOBI_CLOUD_TEST_DATABASE_URL'):
        raise CloudTestConfigurationError('Cloud-test database URL differs from the explicit target')
    parsed = urlsplit(url)
    namespace = project + '-default-rtdb'
    regional = re.fullmatch(re.escape(namespace) + r'\.[a-z]+-[a-z]+[0-9]+\.firebasedatabase\.app', parsed.hostname or '')
    if (parsed.scheme != 'https' or not (parsed.hostname == namespace + '.firebaseio.com' or regional)
            or parsed.netloc != parsed.hostname or parsed.path not in ('', '/')
            or parsed.query or parsed.fragment):
        raise CloudTestConfigurationError('Cloud-test database must be the exact project default HTTPS database')
    if main_test and url.rstrip('/') != MAIN_DATABASE_URL.rstrip('/'):
        raise CloudTestConfigurationError('Main-project database differs from the explicitly confirmed Singapore instance')
    if registration is not None and url.rstrip('/') != registration['databaseUrl'].rstrip('/'):
        raise CloudTestConfigurationError('Database URL differs from the reviewed project registration')
    origins = os.getenv('BACKEND_CORS_ORIGINS', '').split(',')
    for origin in origins:
        p = urlsplit(origin)
        if (p.scheme != 'http' or p.hostname != '127.0.0.1' or not p.port
                or not 1024 <= p.port <= 65535 or p.netloc != f'127.0.0.1:{p.port}'
                or p.path or p.query or p.fragment or p.port in {5173,5174,8001,9000,9099}):
            raise CloudTestConfigurationError('Cloud-test requires separate explicit loopback Web origins')
    return CloudTestScope(project, url, run, main_test, auth_run or None, ride_only)


def account_allowed(uid: str, claims: dict, scope: CloudTestScope) -> bool:
    expected = {
        scope.uid('passenger-a'): ('passenger', None),
        scope.uid('passenger-b'): ('passenger', None),
        scope.uid('driver-a'): ('driver', scope.uid('driver-502')),
        scope.uid('driver-b'): ('driver', scope.uid('driver-105')),
    }
    # Real main-project Auth users must never receive the global admin role.
    if uid not in expected:
        return False
    role, driver = expected[uid]
    exact = {'mobi_cloud_test_run': scope.identity_run, 'mobi_role': role}
    if driver is not None:
        exact['mobi_driver_id'] = driver
    return claims == exact


def create_app():
    scope = validate()
    from app.main import app
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client
    # dotenv loading must not change the already-approved environment.
    validate()
    firebase_auth_app()
    storage = get_firebase_client()
    if not storage.initialize() or storage.using_mock:
        raise RuntimeError('Cloud-test real storage initialization failed')
    storage.get(scope.path)  # Read-only reachability check; never seed on startup.
    return app
