#!/usr/bin/env python3
"""Host-only ephemeral runner controller. Never executes repository code on the host."""
import concurrent.futures
import json
import re
from pathlib import Path
import shutil
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET

REPO = 'winnowwallet/winnow'
FIRE_REPO = 'posix4e/fire-wallet-Josh-August26'
POOL = Path('/data/OSX-KVM/winnow-ci-pool')
BOOT_DISK = 'OpenCore-autoboot-v4.qcow2'
ROLES = {'package': (8, 24, 2241), 'build': (12, 32, 2242),
         'units': (8, 24, 2243), 'journey': (16, 32, 2244)}
WORKFLOWS = {'.github/workflows/ci.yml', '.github/workflows/tdx-trial.yml', '.github/workflows/release.yml'}
REPOSITORIES = {
    REPO: {'workflows': WORKFLOWS, 'roles': set(ROLES), 'prefix': 'winnow'},
    FIRE_REPO: {'workflows': {'.github/workflows/fork-tests.yml'},
                'roles': {'package'}, 'prefix': 'fire'},
}
QEMU = 'http://libvirt.org/schemas/domain/qemu/1.0'
ET.register_namespace('qemu', QEMU)


def command(args, **kwargs):
    return subprocess.check_output(args, timeout=kwargs.pop('timeout', 60), **kwargs)


def api(repo, path, body=None):
    if repo not in REPOSITORIES:
        raise ValueError('repository is not allowed')
    args = ['gh', 'api', f'repos/{repo}/{path}']
    if body is not None:
        args += ['--method', 'POST', '--input', '-']
    response = command(args, input=json.dumps(body).encode() if body is not None else None)
    return json.loads(response) if response.strip() else {}


def eligible(repo, run):
    return (repo in REPOSITORIES
            and run.get('path', '').split('@')[0] in REPOSITORIES[repo]['workflows']
            and (run.get('head_repository') or {}).get('full_name') == repo
            and (run.get('repository') or {}).get('full_name') == repo
            and run.get('event') in {'pull_request', 'push', 'workflow_dispatch', 'schedule'}
            and run.get('status') in {'queued', 'in_progress'}
            and all(type(run.get(field)) is int and run[field] > 0
                    for field in ['id', 'run_attempt']))


def same_run(repo, current, expected):
    return (eligible(repo, current)
            and current['id'] == expected['id']
            and current['run_attempt'] == expected['run_attempt']
            and current['path'] == expected['path'])


def role_for(repo, run, job):
    if (not eligible(repo, run) or job.get('status') != 'queued'
            or type(job.get('id')) is not int or job['id'] <= 0
            or job.get('run_id') != run['id']
            or job.get('run_attempt') != run['run_attempt']):
        return None
    policy = REPOSITORIES[repo]
    labels = job.get('labels', [])
    role_prefixes = tuple(value['prefix'] + '-tdx-' for value in REPOSITORIES.values())
    run_prefixes = tuple(value['prefix'] + '-run-' for value in REPOSITORIES.values())
    role_labels = [label for label in labels if label.startswith(role_prefixes)]
    run_labels = [label for label in labels if label.startswith(run_prefixes)]
    if run_labels != [f'{policy["prefix"]}-run-{run["id"]}-{run["run_attempt"]}']:
        return None
    for role in policy['roles']:
        if role_labels == [policy['prefix'] + '-tdx-' + role]:
            return role
    return None


def pending_runs():
    # Completed runs must not push older queued work out of a recency window.
    runs = {}
    for repo in REPOSITORIES:
        try:
            for status in ['queued', 'in_progress']:
                page = 1
                while True:
                    batch = api(repo, f'actions/runs?status={status}&per_page=100&page={page}')['workflow_runs']
                    runs.update(((repo, run['id']), (repo, run))
                                for run in batch if eligible(repo, run))
                    if len(batch) < 100:
                        break
                    page += 1
        except Exception as error:
            # Missing access to one repository must not block the other pool user.
            print(json.dumps({'repo': repo, 'poll_error': type(error).__name__}), flush=True)
    return sorted(runs.values(), key=lambda item: (item[1]['created_at'], item[1]['id'], item[0]))


def pending_jobs(repo, run):
    page = 1
    while True:
        batch = api(repo, f'actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100&page={page}')['jobs']
        yield from batch
        if len(batch) < 100:
            return
        page += 1


def capacity():
    return (shutil.disk_usage('/data').free >= 100 * 1024**3
            and shutil.disk_usage(POOL).free >= 20 * 1024**3)


def ssh(port, script, input=None, timeout=30):
    return command(['ssh', '-i', '/home/tdx2/.ssh/macvm_key', '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                    '-o', 'ConnectTimeout=5', '-p', str(port), 'macdev@127.0.0.1', script],
                   input=input, timeout=timeout, stderr=subprocess.DEVNULL)


def destroy(name):
    if not re.fullmatch(r'winnow-ci-job-[0-9]+-[0-9]+-(package|build|units|journey)', name):
        raise ValueError('refusing to destroy a non-pool domain')
    for args in [['destroy', name], ['undefine', name, '--nvram']]:
        subprocess.run(['sudo', '-n', 'virsh'] + args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run(['sudo', '-n', 'rm', '-rf', str(POOL / name)], check=True)


def create(role, run_id, job_id):
    cpus, memory, port = ROLES[role]
    name = f'winnow-ci-job-{int(run_id)}-{int(job_id)}-{role}'
    folder = POOL / name
    folder.mkdir(mode=0o750)
    tree = ET.parse(POOL / 'base' / 'template.xml')
    root = tree.getroot()
    root.find('name').text = name
    root.find('uuid').text = str(uuid.uuid4())
    for field in ['memory', 'currentMemory']:
        root.find(field).text = str(memory * 1024 * 1024)
    root.find('vcpu').text = str(cpus)
    root.find('cpu/topology').set('cores', str(cpus))
    for disk in root.findall('devices/disk'):
        source = disk.find('source')
        filename = Path(source.get('file')).name
        base = POOL / 'base' / (BOOT_DISK if filename == 'OpenCore.qcow2' else filename)
        target = folder / base.name
        command(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b', str(base), str(target)])
        source.set('file', str(target))
        for backing in disk.findall('backingStore'):
            disk.remove(backing)
    nvram = folder / 'VARS.fd'
    shutil.copyfile(POOL / 'base' / 'VARS.fd', nvram)
    root.find('os/nvram').text = str(nvram)
    for label in root.findall('seclabel'):
        root.remove(label)
    label = ET.SubElement(root, 'seclabel', {'type': 'static', 'model': 'dac', 'relabel': 'yes'})
    ET.SubElement(label, 'label').text = '+64060:+64060'
    for arg in root.findall(f'{{{QEMU}}}commandline/{{{QEMU}}}arg'):
        value = arg.get('value').replace(':2230-', f':{port}-')
        if value.startswith('virtio-net-pci'):
            value = value.replace('52:54:00:c9:19:30', f'52:54:00:c9:20:{port - 2200:02x}')
        arg.set('value', value)
    xml = folder / 'domain.xml'
    tree.write(xml)
    command(['sudo', '-n', 'chown', '-R', '64060:64060', str(folder)])
    command(['sudo', '-n', 'virsh', 'define', str(xml)])
    command(['sudo', '-n', 'virsh', 'start', name])
    return name, port


def cancel_run(repo, run):
    # Skip newer attempts already visible while a failed worker is reclaimed.
    # GitHub's run-level cancellation API cannot make this check atomic.
    if not same_run(repo, api(repo, f'actions/runs/{run["id"]}'), run):
        return
    api(repo, f'actions/runs/{run["id"]}/cancel', {})
    time.sleep(15)
    if same_run(repo, api(repo, f'actions/runs/{run["id"]}'), run):
        api(repo, f'actions/runs/{run["id"]}/force-cancel', {})


def worker(repo, role, run, job):
    # Validate before any host effects, including the finally cleanup path.
    if role not in ROLES or role_for(repo, run, job) != role:
        raise ValueError('refusing an untrusted or mismatched job')
    name = f'winnow-ci-job-{int(run["id"])}-{int(job["id"])}-{role}'
    prefix = REPOSITORIES[repo]['prefix']
    runner_id = None
    start = time.monotonic()
    try:
        name, port = create(role, run['id'], job['id'])
        while time.monotonic() - start < 600:
            if not same_run(repo, api(repo, f'actions/runs/{run["id"]}'), run):
                return
            try:
                ssh(port, 'test -f /etc/winnow-ci-image', timeout=8)
                break
            except subprocess.SubprocessError:
                time.sleep(5)
        else:
            raise RuntimeError('guest did not become ready')
        # Booting can take minutes; recheck the actual queued job before giving
        # this guest its single-job credential.
        if role_for(repo, run, api(repo, f'actions/jobs/{job["id"]}')) != role:
            return
        config = api(repo, 'actions/runners/generate-jitconfig', {
            'name': name, 'runner_group_id': 1,
            'labels': ['self-hosted', 'macOS', 'X64', prefix + '-tdx-' + role,
                       f'{prefix}-run-{run["id"]}-{run["run_attempt"]}'], 'work_folder': '_work'})
        runner_id = config['runner']['id']
        # Only the single-job credential crosses into the guest, through stdin.
        ssh(port, 'read -r jit; cd /Users/macdev/actions-runner; nohup ./run.sh --jitconfig "$jit" > /tmp/winnow-runner.log 2>&1 < /dev/null &',
            input=(config['encoded_jit_config'] + '\n').encode())
        while time.monotonic() - start < 4200:
            state = command(['sudo', '-n', 'virsh', 'domstate', name], text=True).strip()
            if state != 'running':
                raise RuntimeError('worker stopped before GitHub reported completion')
            current = api(repo, f'actions/jobs/{job["id"]}')
            parent = api(repo, f'actions/runs/{run["id"]}')
            if current['status'] == 'completed' or not same_run(repo, parent, run):
                print(json.dumps({'repo': repo, 'job': job['id'], 'role': role, 'result': current.get('conclusion'),
                                  'worker_seconds': round(time.monotonic() - start)}), flush=True)
                return
            if not capacity():
                raise RuntimeError('pool storage reserve reached')
            time.sleep(10)
        raise RuntimeError('worker exceeded 70 minute lifetime')
    except Exception as error:
        print(json.dumps({'repo': repo, 'job': job['id'], 'role': role, 'error': type(error).__name__, 'detail': str(error)[:300]}), flush=True)
        # A lost worker fails the pipeline; it is never silently retried.
        try:
            cancel_run(repo, run)
        except Exception:
            pass
    finally:
        try:
            destroy(name)
        finally:
            if runner_id:
                subprocess.run(['gh', 'api', '--method', 'DELETE', f'repos/{repo}/actions/runners/{runner_id}'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def dispatch(executor, active, seen):
    if active:
        repo, run_id, _ = next(iter(active))[:3]
        runs = [(repo, api(repo, f'actions/runs/{run_id}'))]
    else:
        runs = pending_runs()
    for repo, run in runs:
        if not eligible(repo, run):
            continue
        run_key = (repo, run['id'], run['run_attempt'])
        if active and run_key != next(iter(active))[:3]:
            continue
        for job in pending_jobs(repo, run):
            role = role_for(repo, run, job)
            if not role:
                continue
            key = (*run_key, job['id'], role)
            if key in seen or any(k[4] == role for k in active) or not capacity():
                continue
            seen.add(key)
            active[key] = executor.submit(worker, repo, role, run, job)
        if active:
            break


def main():
    import fcntl
    lock = open('/home/tdx2/.winnow-ci-controller.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    # Reconcile only controller-owned guests left by a host/service restart.
    names = command(['sudo', '-n', 'virsh', 'list', '--all', '--name'], text=True).split()
    for name in names:
        if name.startswith('winnow-ci-job-'):
            destroy(name)
    seen = set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        active = {}
        while True:
            active = {key: value for key, value in active.items() if not value.done()}
            try:
                dispatch(executor, active, seen)
            except Exception as error:
                print(json.dumps({'poll_error': type(error).__name__}), flush=True)
            time.sleep(15)

if __name__ == '__main__':
    main()
