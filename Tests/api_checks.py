"""Read-only HTTP boundary checks against an explicitly supplied running app."""
import http.client
import json
import sys
from urllib.parse import urlsplit

connection = json.load(open(sys.argv[1]))
url = urlsplit(connection['url'])
token = url.fragment

def request(path, *, method='GET', body=None, auth=True, origin=None, host=None):
    conn = http.client.HTTPConnection(url.hostname, url.port, timeout=30)
    headers = {'Host': host or url.netloc}
    if auth:
        headers['Authorization'] = 'Bearer ' + token
    if origin:
        headers['Origin'] = origin
    if body is not None:
        headers['Content-Type'] = 'application/json'
    conn.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
    response = conn.getresponse()
    payload = response.read()
    result = (response.status, payload, dict(response.getheaders()))
    conn.close()
    return result

assert request('/api/state', auth=False)[0] == 401
assert request('/api/state', origin='https://untrusted.example')[0] == 403
assert request('/api/state', host='untrusted.example')[0] == 403
status, body, headers = request('/api/state')
assert status == 200
state = json.loads(body)
assert state['items'] and state['total'] > state['free'] > 0
assert headers['Cache-Control'] == 'no-store'
assert headers['X-Frame-Options'] == 'DENY'
assert request('/../../Source/Chipspace.swift')[0] == 404
assert request('/api/execute', method='POST', body={'ticket': 'invalid', 'confirmation': 'DELETE', 'closed': True})[0] == 409
assert request('/api/prepare', method='POST', body={'id': 'missing', 'path': '/', 'mode': 'delete'})[0] == 409
protected = next(i for i in state['items'] if i['path'].startswith('/System/'))
assert request('/api/prepare', method='POST', body={'id': protected['id'], 'mode': 'delete'})[0] == 409
assert request('/api/prepare', method='POST', body={'id': protected['id'], 'mode': 'anything'})[0] == 409
after = json.loads(request('/api/state')[1])
assert not any(i['removed'] for i in after['items'])
print('PASS: authenticated state, host/origin rejection, missing-token rejection, traversal rejection, unknown IDs, protected folders, invalid actions, and invalid cleanup tickets. No data deleted.')
