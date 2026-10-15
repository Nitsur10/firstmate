#!/usr/bin/env bash
# Public dashboard transport: read-only HTTP, missing sources, history and forge failure.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 -B - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile, urllib.request, urllib.error
root = pathlib.Path(sys.argv[1])
script = root / 'bin/fm-fleet-dashboard.sh'
with tempfile.TemporaryDirectory(prefix='fm-dashboard-test-') as tmp:
    home = pathlib.Path(tmp)
    (home/'state').mkdir(); (home/'config').mkdir()
    snap = home/'sample.json'
    sample = {'schema':'fm-fleet-snapshot.v1','generated':'2000-01-01T00:00:00Z','tasks':[],
              'backlog':{'present':True,'records':[]},'secondmate_current':{'records':[]}}
    snap.write_text(json.dumps(sample))
    args = [str(script),'--home',str(home),'--snapshot',str(snap)]
    def data(extra=()):
        return json.loads(subprocess.check_output(args+['--json']+list(extra)))
    d=data(); assert d['snapshot']==sample and 'off' in d['history']['notice'] and d['forge']=={}
    event={'v':1,'ts':1,'event':'task.status','task':'safe','state':'done','text':'<script>alert(1)</script>'}
    ledger=home/'state/fleet-ledger.jsonl'
    ledger.write_text(json.dumps(event)+'\n'+json.dumps(event)+'\n{"partial":\n')
    before=ledger.read_bytes(); d=data()
    assert len(d['history']['events'])==1 and 'skipped' in d['history']['notice']
    assert ledger.read_bytes()==before and not (home/'config/fleet-ledger').exists()
    sample['tasks']=[{'id':'x','pr':{'url':'https://evil.example/a/pull/1'}}]
    snap.write_text(json.dumps(sample)); d=data(['--forge'])
    assert d['forge']['https://evil.example/a/pull/1']['ci']=='Unavailable'
    fakebin=home/'fakebin';fakebin.mkdir()
    fake=fakebin/'gh-axi'
    fake.write_text("#!/usr/bin/env python3\nimport sys\nassert sys.argv[1:4]==['api','POST','/graphql']\nassert any(a.startswith('query=query {') for a in sys.argv)\nprint('errors: 0\\nstate: OPEN\\nhead: abc123\\nreview: APPROVED\\nci: SUCCESS')\n")
    fake.chmod(0o755)
    os.environ['PATH']=str(fakebin)+os.pathsep+os.environ['PATH']
    url='https://github.com/example/project/pull/123'
    sample['tasks']=[{'id':'x','pr':{'url':url}}];snap.write_text(json.dumps(sample))
    f=data(['--forge'])['forge'][url]
    assert f['ci']=='Passing' and f['review']=='Approved' and f['head']=='abc123'
    fake.write_text('#!/usr/bin/env bash\nexit 1\n')
    assert 'Forge call failed' in data(['--forge'])['forge'][url]['notice']
    sample['schema']='unsupported';snap.write_text(json.dumps(sample))
    assert 'unavailable' in data()['error']
    snap.write_text(json.dumps({'schema':'fm-fleet-snapshot.v1','tasks':[]}))
    proc=subprocess.Popen(args,stdout=subprocess.PIPE,text=True)
    try:
        url=proc.stdout.readline().strip().split('Fleet dashboard: ')[1]
        def request(suffix='',method='GET',headers=None):
            req=urllib.request.Request(url+suffix,method=method,headers=headers or {})
            try:
                return urllib.request.urlopen(req)
            except urllib.error.HTTPError as e:
                return e
        page=request(); assert page.status==200 and page.headers['Cache-Control']=='no-store'
        assert "frame-ancestors 'none'" in page.headers['Content-Security-Policy']
        assert request('data').status==200
        assert request('data',method='POST').status==501
        assert request('data',headers={'Origin':'https://evil.example'}).status==403
        assert request('data',headers={'Host':'evil.example'}).status==403
        assert request('../../etc/passwd').status==404
        assert urllib.request.urlopen(url+'data').headers.get('Access-Control-Allow-Origin') is None
    finally:
        proc.terminate();proc.wait(timeout=5)
print('PASS: dashboard sources, ledger deduplication, forge refusal and private read-only HTTP')
PY
