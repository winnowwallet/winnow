"""Bind candidate control, exact-source evidence, CI and live Apple readback.

This script never uploads, submits declarations, or assigns testers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
from datetime import datetime, timezone


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_apple_collection(get, path, *, first_page=None, max_pages=100):
    """Read one complete Apple collection; reject ambiguous or unbounded paging."""
    base = 'https://api.appstoreconnect.apple.com/v1'
    require(path.startswith('/') and not path.startswith('//'), 'Expected relative Apple collection path')
    collection = path.split('?', 1)[0]
    rows, visited = [], set()
    while path:
        require(path not in visited, 'Apple collection pagination repeated')
        require(len(visited) < max_pages, 'Apple collection pagination limit exceeded')
        visited.add(path)
        page = first_page if first_page is not None else get(path)
        first_page = None
        require(isinstance(page.get('data'), list), 'Invalid Apple collection page')
        rows.extend(page['data'])
        link = page.get('links', {}).get('next')
        if link is None:
            break
        require(isinstance(link, str) and link.startswith(base + collection + '?'),
                'Unexpected Apple collection pagination URL')
        path = link[len(base):]
    return rows


def validate_internal_store_scope(versions):
    require(all(row['attributes']['appStoreState'] == 'PREPARE_FOR_SUBMISSION' for row in versions),
            'public store distribution needs a separate availability review')


def contained(root, path):
    value = (root / path).resolve()
    require(value.is_relative_to(root.resolve()), 'Candidate path escapes control checkout')
    return value


def load_candidate(root):
    value = json.loads((root / 'lightning-release-candidate.json').read_text())
    require(value['repository'] == 'posix4e/winnow-lightning', 'Wrong app repository')
    require(value['app_id'] == '6815392502' and value['bundle'] == 'com.btcswift.lightning', 'Wrong research app')
    for name in ['source', 'release_tooling_source']:
        require(isinstance(value.get(name), str) and re.fullmatch('[0-9a-f]{40}', value[name]), name + ' is pending')
    require(type(value.get('ci_run')) is int and value['ci_run'] > 0, 'Exact CI run is pending')
    require(re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value['version']), 'Invalid candidate version')
    require(re.fullmatch('[1-9][0-9]*', value['build']), 'Invalid candidate build')
    return value


def validate_display(evidence_root, path, source, kind):
    proof = json.loads(contained(evidence_root, path).read_text())
    require(proof.get('result') == 'passed', kind + ' journey did not pass')
    manifest = proof['manifest']
    require(manifest['source'] == source and manifest['dirty'] is False, kind + ' journey source mismatch')
    require(manifest['bundle'] == 'com.btcswift.lightning', kind + ' journey has wrong app')
    if kind == 'ipad':
        require('iPad' in manifest['device']['device_type'], 'iPad evidence must use iPad')
    else:
        require(manifest['content_size'] == 'accessibility-extra-extra-extra-large', 'Maximum accessibility text evidence is required')


def validate_artifacts(evidence_root, evidence):
    require(bool(evidence['artifacts']), 'Evidence artifacts are pending')
    hashes = {}
    for artifact in evidence['artifacts']:
        path = contained(evidence_root, artifact['path'])
        require(hashlib.sha256(path.read_bytes()).hexdigest() == artifact['sha256'], 'Evidence artifact changed: ' + artifact['path'])
        hashes[artifact['path']] = artifact['sha256']
    return hashes


def validate_device_checks(evidence):
    require(evidence['physical_device'] is False and evidence['device_checks_deferred_to_testflight'] is True,
            'This candidate records physical checks deferred to internal TestFlight')
    for name in ['owner_authentication', 'cancelled_authentication', 'file_protection', 'exact_share']:
        require(evidence['checks'].get(name) == 'pending', 'Deferred device check must stay pending: ' + name)


def validate_crypto(evidence_root, evidence, candidate, hashes):
    require(evidence['encryption']['mode'] == 'pending', 'Candidate upload awaits source-grounded questionnaire')
    require(evidence['encryption']['artifact'] in hashes, 'Crypto inventory must be hashed')
    require('what-to-test.txt' in hashes, 'Tester notes must be hashed')
    draft = json.loads((evidence_root / 'encryption-questionnaire.json').read_text())
    require('encryption-questionnaire.json' in hashes, 'Questionnaire must be hashed')
    for name in ['source', 'bundle', 'version', 'build', 'distribution_scope']:
        require(draft[name] == candidate[name], 'Questionnaire binding mismatch: ' + name)
    validate_questionnaire_review(candidate, draft)
    require('crypto-comparison.json' in hashes, 'Source comparison must be hashed')
    comparison = json.loads((evidence_root / 'crypto-comparison.json').read_text())
    require(comparison['source'] == candidate['source'], 'Crypto comparison source mismatch')


def validate_questionnaire_review(candidate, draft):
    review = draft['facts_review']
    require(review['source'] == candidate['source'] and review['status'] == 'facts-reviewed', 'Final-source encryption facts review is pending')
    require(isinstance(review['reviewed_by'], str) and review['reviewed_by'].strip(), 'Responsible facts reviewer is pending')


def validate_evidence(root, candidate):
    path = contained(root, candidate['evidence'])
    evidence = json.loads(path.read_text())
    require(evidence['source'] == candidate['source'] and evidence['bundle'] == candidate['bundle'], 'Stale release evidence')
    require(evidence['ci_run'] == candidate['ci_run'], 'Evidence uses another CI run')
    hashes = validate_artifacts(path.parent, evidence)
    validate_device_checks(evidence)
    for kind in ['ipad', 'large_text']:
        require(evidence['checks'].get(kind) == 'passed', kind + ' display check is pending')
        proof_path = evidence['display_evidence'][kind]
        require(proof_path in hashes, kind + ' proof is not hashed')
        validate_display(path.parent, proof_path, candidate['source'], kind)
    validate_crypto(path.parent, evidence, candidate, hashes)
    return path


def validate_ci(candidate, run):
    require(run['head_sha'] == candidate['source'], 'CI run belongs to another source')
    require(run['id'] == candidate['ci_run'], 'Wrong CI run')
    require(run['name'] == 'CI', 'Required workflow must be CI')
    require(run['path'] == '.github/workflows/ci.yml', 'Wrong required CI workflow file')
    require(run['status'] == 'completed' and run['conclusion'] == 'success', 'Exact-source CI has not passed')


def verify_current_ci(candidate):
    endpoint = 'repos/' + candidate['repository'] + '/actions/runs/' + str(candidate['ci_run'])
    validate_ci(candidate, json.loads(subprocess.check_output(['gh', 'api', endpoint], text=True)))


def validate_apple(candidate, state, operation):
    require(state['app']['id'] == candidate['app_id'] and state['app']['bundle'] == candidate['bundle'], 'Apple readback has wrong app')
    observed = datetime.fromisoformat(state['observed_at_utc'])
    age = (datetime.now(timezone.utc) - observed).total_seconds()
    require(0 <= age < 900, 'A fresh live Apple readback is required')
    selection = state['candidate']
    require(selection['version'] == candidate['version'] and selection['build'] == candidate['build'], 'Apple readback has stale candidate')
    require(selection['all_builds_read'] is True, 'Next-build check is incomplete')
    if operation == 'upload':
        require(not selection['matching_build_ids'], 'Candidate build already exists in Apple')
        require(int(candidate['build']) > selection['highest_build_number'], 'Choose a build above existing Apple build numbers')
    else:
        require(len(selection['matching_build_ids']) == 1, 'Expected exactly one processed candidate build')


def github_outputs(candidate):
    values = {name: str(candidate[name]) for name in ['source', 'release_tooling_source', 'ci_run', 'version', 'build']}
    values['artifact_name'] = 'lightning-testflight-' + candidate['version'] + '-' + candidate['build']
    values['evidence'] = candidate['evidence']
    return ''.join(name + '=' + value + '\n' for name, value in values.items())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['validate', 'ci', 'apple'])
    parser.add_argument('--github-output', type=Path)
    parser.add_argument('--apple-state', type=Path)
    parser.add_argument('--release-operation', choices=['upload', 'declare-and-enable'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    candidate = load_candidate(root)
    validate_evidence(root, candidate)
    if args.operation == 'ci':
        verify_current_ci(candidate)
    if args.operation == 'apple':
        require(args.apple_state and args.release_operation, 'Apple readback and operation are required')
        validate_apple(candidate, json.loads(args.apple_state.read_text()), args.release_operation)
    if args.github_output:
        with args.github_output.open('a') as stream:
            stream.write(github_outputs(candidate))
    print('Candidate bindings verified for ' + candidate['source'] + ' / ' + candidate['version'] + '(' + candidate['build'] + ')')


if __name__ == '__main__':
    main()
