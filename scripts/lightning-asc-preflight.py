"""Read the existing research app without exporting any signing credentials."""
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

APP = '6815392502'
ROOT = Path(__file__).resolve().parent.parent
token = subprocess.check_output(['swift', str(ROOT / 'scripts/asc-jwt.swift'), os.environ['ASC_KEY_PATH'],
    os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID']], text=True).strip()


def get(path, optional=False):
    request = urllib.request.Request('https://api.appstoreconnect.apple.com/v1' + path,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if optional:
            return {'http_status': error.code, 'data': []}
        raise RuntimeError(f'App Store Connect returned HTTP {error.code}') from None


app = get('/apps/' + APP)['data']
assert app['attributes']['bundleId'] == 'com.btcswift.lightning'
builds = get('/apps/' + APP + '/builds?sort=-uploadedDate&limit=30&include=preReleaseVersion')
versions = {row['id']: row['attributes'].get('version') for row in builds.get('included', [])
            if row['type'] == 'preReleaseVersions'}
declarations = get('/apps/' + APP + '/appEncryptionDeclarations?limit=200', optional=True)
groups = get('/apps/' + APP + '/betaGroups?limit=200')
report = {'app': {'id': APP, 'bundle': app['attributes']['bundleId'], 'name': app['attributes']['name']},
    'builds': [], 'declarations_http_status': declarations.get('http_status', 200), 'declarations': [], 'groups': []}
for row in builds['data']:
    attributes = row['attributes']
    version = row.get('relationships', {}).get('preReleaseVersion', {}).get('data') or {}
    report['builds'].append(dict(id=row['id'], build=attributes.get('version'), version=versions.get(version.get('id')),
        processing=attributes.get('processingState'), nonexempt=attributes.get('usesNonExemptEncryption'),
        uploaded_at=attributes.get('uploadedDate'), expired=attributes.get('expired')))
for row in declarations['data']:
    allowed = {'appEncryptionDeclarationState', 'usesEncryption', 'exempt', 'containsProprietaryCryptography',
               'containsThirdPartyCryptography', 'availableOnFrenchStore', 'appDescription', 'createdDate', 'platform'}
    report['declarations'].append({'id': row['id'], **{k: v for k, v in row['attributes'].items() if k in allowed}})
for row in groups['data']:
    attributes = row['attributes']
    if attributes.get('name') != 'PQLNRegtestInternal':
        continue
    testers = get('/betaGroups/' + row['id'] + '/relationships/betaTesters?limit=200')
    report['groups'].append({'id': row['id'], 'name': attributes['name'], 'internal': attributes.get('isInternalGroup'),
        'tester_count': testers.get('meta', {}).get('paging', {}).get('total', len(testers['data']))})
destination = ROOT / 'control-output'
destination.mkdir(exist_ok=True)
(destination / 'app-state.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'app': report['app'], 'build_count': len(report['builds']), 'declaration_count': len(report['declarations']), 'groups': report['groups']}))
