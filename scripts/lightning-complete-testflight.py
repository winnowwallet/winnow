"""Submit source-grounded encryption facts and enable only the existing internal beta."""
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

if not __debug__:
    raise RuntimeError('Release checks require assertions')
ROOT = Path(__file__).resolve().parent.parent
APP = '6815392502'
BUNDLE = 'com.btcswift.lightning'
SOURCE = 'ac1f6e72a490bfb6413bcfda6730756856329095'
receipt = json.loads((ROOT / 'lightning-release-evidence/upload-receipt.json').read_text())
assert receipt['source'] == SOURCE and receipt['bundle'] == BUNDLE
assert receipt['version'] == '0.2.0' and receipt['build'] == '2'
assert receipt['uploaded'] is True and receipt['processed'] is True
build_id = receipt['app_store_connect_build']
draft = json.loads((ROOT / 'lightning-release-evidence/encryption-questionnaire.json').read_text())
assert draft['source'] == SOURCE and draft['bundle'] == BUNDLE
assert draft['distribution_scope'] == 'International internal TestFlight beta; no public App Store release requested'


class AppleError(RuntimeError):
    def __init__(self, method, endpoint, status, details):
        self.status, self.details = status, details
        super().__init__(f'Apple {method} {endpoint}: HTTP {status}: {json.dumps(details)}')


def asc(method, endpoint, data=None):
    token = subprocess.check_output(['swift', str(ROOT / 'scripts/asc-jwt.swift'), os.environ['ASC_KEY_PATH'],
        os.environ['ASC_KEY_ID'], os.environ['ASC_ISSUER_ID']], text=True).strip()
    request = urllib.request.Request('https://api.appstoreconnect.apple.com/v1' + endpoint, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        details = json.loads(error.read())
        raise AppleError(method, endpoint, error.code, details) from None


assert asc('GET', '/apps/' + APP)['data']['attributes']['bundleId'] == BUNDLE
builds = asc('GET', '/builds?filter[app]=' + APP + '&filter[version]=2&filter[preReleaseVersion.version]=0.2.0&limit=2')['data']
assert len(builds) == 1 and builds[0]['id'] == build_id and builds[0]['attributes']['processingState'] == 'VALID'
# This is an internal beta, with no public App Store rollout. Do not infer the
# French-store answer if the app has any submitted or released store version.
versions = asc('GET', '/apps/' + APP + '/appStoreVersions?limit=200')['data']
assert all(v['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION' for v in versions), 'public store distribution needs a separate availability review'
attributes = dict(appDescription=draft['app_description'], availableOnFrenchStore=False,
                  containsProprietaryCryptography=False, containsThirdPartyCryptography=True)
assert len(attributes['appDescription']) <= 300
assert draft['french_store_answer']['value'] is False
assert draft['technical_answers'] == dict(uses_encryption=True, containsProprietaryCryptography=False, containsThirdPartyCryptography=True)
existing = asc('GET', '/appEncryptionDeclarations?filter[app]=' + APP + '&limit=200')['data']
matching = [d for d in existing if all(d['attributes'].get(k) == v for k, v in attributes.items())]
assert len(matching) <= 1, 'ambiguous existing declaration'
no_document_response = None
if matching:
    declaration = matching[0]
else:
    try:
        declaration = asc('POST', '/appEncryptionDeclarations', {'data': {
            'type': 'appEncryptionDeclarations', 'attributes': attributes,
            'relationships': {'app': {'data': {'type': 'apps', 'id': APP}}}}})['data']
    except AppleError as error:
        # Apple documents that standard outside-OS crypto needs an encryption
        # document only for French App Store distribution. Its API refuses to
        # create a declaration for the other cases. Match only that response;
        # permission, validation and unrelated 409 errors must still fail.
        errors = error.details.get('errors', [])
        expected = 'Cannot create appEncryptionDeclarations unless either containsProprietaryCryptography is True or containsThirdPartyCryptography and availableOnFrenchStore are both True'
        assert error.status == 409 and len(errors) == 1 and errors[0]['code'] == 'ENTITY_ERROR.ATTRIBUTE.INVALID' and errors[0]['detail'] == expected, str(error)
        no_document_response = {'http_status': error.status, 'response': error.details}
        declaration = None
result = dict(receipt, distribution_scope=draft['distribution_scope'], declaration=declaration,
              questionnaire_answers=attributes, apple_no_document_response=no_document_response,
              documentation_basis='https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/',
              available_to_internal_testers=False)
destination = ROOT / 'control-output/finalization.json'
destination.parent.mkdir(exist_ok=True)
destination.write_text(json.dumps(result, indent=2) + '\n')
state = declaration['attributes']['appEncryptionDeclarationState'] if declaration else 'DOCUMENTATION_NOT_REQUIRED'
if declaration and state != 'APPROVED':
    print('Apple declaration state: ' + state + '; tester assignment remains pending.')
    raise SystemExit(0)
if declaration:
    assert declaration['attributes']['usesEncryption'] is True
exempt = declaration['attributes']['exempt'] if declaration else True
assert isinstance(exempt, bool), 'Apple did not return a determination'
nonexempt = not exempt
current = asc('GET', '/builds/' + build_id)['data']['attributes']['usesNonExemptEncryption']
if current is None:
    asc('PATCH', '/builds/' + build_id, {'data': {'type': 'builds', 'id': build_id,
        'attributes': {'usesNonExemptEncryption': nonexempt}}})
else:
    assert current is nonexempt, 'build declaration disagrees with Apple determination'
if nonexempt:
    asc('PATCH', '/builds/' + build_id + '/relationships/appEncryptionDeclaration',
        {'data': {'type': 'appEncryptionDeclarations', 'id': declaration['id']}})
    assert asc('GET', '/builds/' + build_id + '/appEncryptionDeclaration')['data']['id'] == declaration['id']
assert asc('GET', '/builds/' + build_id)['data']['attributes']['usesNonExemptEncryption'] is nonexempt
environment = dict(os.environ, TESTFLIGHT_BUNDLE_ID=BUNDLE, TESTFLIGHT_MARKETING_VERSION='0.2.0',
                   TESTFLIGHT_BUILD_NUMBER='2', TESTFLIGHT_BUILD_ID=build_id)
subprocess.run([str(ROOT.parent / 'tooling/scripts/testflight.sh'), 'internal'], env=environment, check=True)
result.update(available_to_internal_testers=True, internal_group='PQLN Regtest Internal',
              apple_encryption_determination={'exempt_from_documentation': exempt, 'declaration_id': declaration['id'] if declaration else None, 'state': state})
destination.write_text(json.dumps(result, indent=2) + '\n')
print('Verified existing internal group can install version 0.2.0 build 2.')
