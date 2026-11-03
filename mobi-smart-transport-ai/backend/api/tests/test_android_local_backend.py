"""Fresh-process tests of explicit local host; no Firebase, ADC or data runs."""
import json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
SCRIPT=ROOT/'scripts/run_android_local_backend.py'

def run(*args):
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
    return subprocess.run([sys.executable,'-B',str(SCRIPT),*args],env=env,
                          capture_output=True,text=True,timeout=35)

def test_requires_explicit_fake_auth_switch(tmp_path):
    result=run('--trace',str(tmp_path/'denied.jsonl'))
    assert result.returncode!=0
    assert 'Explicit --enable-local-test-auth required' in result.stderr
    assert not (tmp_path/'denied.jsonl').exists()

def test_local_http_contract_and_no_safety_event_creation(tmp_path):
    trace=tmp_path/'http.jsonl'
    result=run('--enable-local-test-auth','--self-test','--trace',str(trace))
    assert result.returncode==0,result.stderr
    summary=json.loads(result.stdout.strip().splitlines()[-1])
    assert summary['result']=='LOCAL_HTTP_SELF_TEST_PASS'
    assert summary['androidRuntime'] is False and summary['safetyEventsCreated']==0
    rows=[json.loads(line) for line in trace.read_text().splitlines()]
    assert len(rows)==summary['checks']==15
    assert any(r['status']==401 for r in rows)
    assert any(r['status']==403 for r in rows)
    assert all(set(r)=={'utc','method','path','status','attemptId'} for r in rows)
