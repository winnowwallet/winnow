import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, call, patch
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location(
    'tdx_controller', Path(__file__).resolve().parents[1] / 'tdx/controller.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def run(repo=m.REPO, run_id=123, attempt=1, **changes):
    return {
        'id': run_id, 'run_attempt': attempt, 'created_at': f'2026-09-19T{run_id:06d}',
        'status': 'in_progress', 'event': 'pull_request',
        'path': '.github/workflows/fork-tests.yml' if repo == m.FIRE_REPO else '.github/workflows/ci.yml',
        'repository': {'full_name': repo}, 'head_repository': {'full_name': repo},
        **changes,
    }


def job(parent, role='package', job_id=456, **changes):
    repo = parent['repository']['full_name']
    prefix = m.REPOSITORIES[repo]['prefix']
    return {
        'id': job_id, 'run_id': parent['id'], 'run_attempt': parent['run_attempt'],
        'status': 'queued',
        'labels': ['self-hosted', f'{prefix}-tdx-{role}',
                   f'{prefix}-run-{parent["id"]}-{parent["run_attempt"]}'],
        **changes,
    }


class ControllerTests(unittest.TestCase):
    def setUp(self):
        # Every test fails closed at the external-effect boundary. Unexpected
        # paths cannot use gh, SSH, sudo, virsh, qemu-img or real VM disks.
        for target in ['command', 'ssh', 'create', 'destroy']:
            p = patch.object(m, target, side_effect=AssertionError('unexpected host action'))
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(m.subprocess, 'run', side_effect=AssertionError('unexpected subprocess'))
        p.start()
        self.addCleanup(p.stop)
        p = patch.object(m.time, 'sleep')
        p.start()
        self.addCleanup(p.stop)

    def test_old_queued_work_survives_pagination_and_completed_run_history(self):
        def response(repo, path):
            if repo == m.FIRE_REPO:
                return {'workflow_runs': []}
            if 'status=in_progress' in path:
                return {'workflow_runs': [run(run_id=1), run(run_id=999, status='completed')]}
            ids = range(102, 2, -1) if path.endswith('page=1') else [2]
            return {'workflow_runs': [run(run_id=i, status='queued') for i in ids]}
        with patch.object(m, 'api', side_effect=response) as request:
            self.assertEqual([r['id'] for _, r in m.pending_runs()], list(range(1, 103)))
        self.assertIn(call(m.REPO, 'actions/runs?status=queued&per_page=100&page=2'), request.call_args_list)

    def test_repositories_are_merged_in_global_age_order_without_id_collisions(self):
        winnow, fire = run(), run(m.FIRE_REPO, created_at='2026-09-18T000000')
        def response(repo, path):
            values = [winnow, fire] if 'status=in_progress' in path else []
            return {'workflow_runs': values}
        with patch.object(m, 'api', side_effect=response):
            self.assertEqual(m.pending_runs(), [(m.FIRE_REPO, fire), (m.REPO, winnow)])

    def test_inaccessible_fire_repository_does_not_block_winnow(self):
        parent = run()
        def response(repo, path):
            if repo == m.FIRE_REPO:
                raise subprocess.CalledProcessError(1, ['gh', 'api'])
            return {'workflow_runs': [parent]}
        with patch.object(m, 'api', side_effect=response), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(m.pending_runs(), [(m.REPO, parent)])

    def test_only_trusted_allowlisted_repository_workflows_are_eligible(self):
        for repo in m.REPOSITORIES:
            parent = run(repo)
            self.assertTrue(m.eligible(repo, parent))
            for field, value in [
                ('head_repository', {'full_name': 'fork/wallet'}),
                ('head_repository', None), ('repository', {'full_name': 'other/wallet'}),
                ('path', '.github/workflows/evil.yml'), ('status', 'completed'),
                ('event', 'pull_request_target'), ('event', 'workflow_run'),
                ('run_attempt', 0), ('id', '../123'),
            ]:
                with self.subTest(repo=repo, field=field, value=value):
                    self.assertFalse(m.eligible(repo, {**parent, field: value}))
        self.assertFalse(m.eligible('other/repo', run('other/repo')))
        for path in ['.github/workflows/testflight.yml', '.github/workflows/ios-ui-tests.yml',
                     '.github/workflows/ci.yml']:
            self.assertFalse(m.eligible(m.FIRE_REPO, run(m.FIRE_REPO, path=path)))
        for path in m.WORKFLOWS:
            self.assertTrue(m.eligible(m.REPO, run(path=path)))

    def test_only_queued_repo_run_attempt_and_role_labels_can_allocate(self):
        for repo in m.REPOSITORIES:
            parent = run(repo)
            prefix = m.REPOSITORIES[repo]['prefix']
            good = job(parent)
            self.assertEqual(m.role_for(repo, parent, good), 'package')
            changes = [
                {'status': 'completed'}, {'run_id': 124}, {'run_attempt': 2},
                {'id': -1}, {'labels': [f'{prefix}-tdx-package']},
                {'labels': [f'{prefix}-tdx-package', f'{prefix}-run-123-2']},
                {'labels': [f'{prefix}-tdx-package', f'{prefix}-run-124-1']},
                {'labels': good['labels'] + [f'{prefix}-tdx-build']},
                {'labels': good['labels'] + ['fire-run-999-1']},
                {'labels': good['labels'] + ['winnow-tdx-journey']},
            ]
            for change in changes:
                with self.subTest(repo=repo, change=change):
                    self.assertIsNone(m.role_for(repo, parent, {**good, **change}))
        fire = run(m.FIRE_REPO)
        for role in ['build', 'units', 'journey', 'signing']:
            self.assertIsNone(m.role_for(m.FIRE_REPO, fire, job(fire, role)))
        self.assertIsNone(m.role_for(m.FIRE_REPO, fire, job(run())))
        for role in m.ROLES:
            self.assertEqual(m.role_for(m.REPO, run(), job(run(), role)), role)

    def test_api_uses_exact_repository_and_rejects_unknown_before_command(self):
        m.command.side_effect = None
        m.command.return_value = b'{"ok":true}'
        for repo in m.REPOSITORIES:
            self.assertEqual(m.api(repo, 'actions/runners/generate-jitconfig', {'name': 'test'}), {'ok': True})
            args, kwargs = m.command.call_args
            self.assertEqual(args[0], ['gh', 'api', f'repos/{repo}/actions/runners/generate-jitconfig',
                                      '--method', 'POST', '--input', '-'])
            self.assertEqual(json.loads(kwargs['input']), {'name': 'test'})
        m.command.reset_mock()
        with self.assertRaises(ValueError):
            m.api('other/repo', 'actions/runners')
        m.command.assert_not_called()

    def test_job_pagination_is_bound_to_repository_and_attempt(self):
        parent = run(m.FIRE_REPO, attempt=3)
        jobs = [job(parent, job_id=i) for i in range(1, 102)]
        with patch.object(m, 'api', side_effect=[{'jobs': jobs[:100]}, {'jobs': jobs[100:]}]) as api:
            self.assertEqual(list(m.pending_jobs(m.FIRE_REPO, parent)), jobs)
        self.assertEqual(api.call_args_list, [
            call(m.FIRE_REPO, 'actions/runs/123/attempts/3/jobs?per_page=100&page=1'),
            call(m.FIRE_REPO, 'actions/runs/123/attempts/3/jobs?per_page=100&page=2'),
        ])

    def test_dispatch_selects_one_run_globally_and_one_job_per_role(self):
        first, second = run(m.FIRE_REPO), run(run_id=124)
        executor, active, seen = Mock(), {}, set()
        with patch.object(m, 'pending_runs', return_value=[(m.FIRE_REPO, first), (m.REPO, second)]), \
                patch.object(m, 'pending_jobs', return_value=[job(first), job(first, job_id=457)]) as jobs, \
                patch.object(m, 'capacity', return_value=True):
            m.dispatch(executor, active, seen)
        executor.submit.assert_called_once_with(m.worker, m.FIRE_REPO, 'package', first, job(first))
        jobs.assert_called_once_with(m.FIRE_REPO, first)
        self.assertEqual(set(active), {(m.FIRE_REPO, 123, 1, 456, 'package')})

    def test_active_run_is_repo_scoped_and_blocks_new_attempt_until_cleanup(self):
        active = {(m.FIRE_REPO, 123, 1, 456, 'package'): Mock()}
        with patch.object(m, 'api', return_value=run(m.FIRE_REPO, attempt=2)) as api, \
                patch.object(m, 'pending_runs') as pending, patch.object(m, 'pending_jobs') as jobs:
            m.dispatch(Mock(), active, set())
        api.assert_called_once_with(m.FIRE_REPO, 'actions/runs/123')
        pending.assert_not_called()
        jobs.assert_not_called()

    def test_all_four_original_roles_share_existing_capacity(self):
        parent, executor, active = run(), Mock(), {}
        jobs = [job(parent, role, i) for i, role in enumerate(m.ROLES, 1)]
        with patch.object(m, 'pending_runs', return_value=[(m.REPO, parent)]), \
                patch.object(m, 'pending_jobs', return_value=jobs), patch.object(m, 'capacity', return_value=True):
            m.dispatch(executor, active, set())
        self.assertEqual(executor.submit.call_count, 4)
        self.assertEqual(sum(x[0] for x in m.ROLES.values()), 44)
        self.assertEqual(sum(x[1] for x in m.ROLES.values()), 112)
        self.assertEqual({x[2] for x in m.ROLES.values()}, {2241, 2242, 2243, 2244})

    def test_seen_keys_include_repo_and_attempt_and_disk_reserve_blocks_dispatch(self):
        parent, executor = run(m.FIRE_REPO, attempt=2), Mock()
        seen = {(m.REPO, 123, 2, 456, 'package'), (m.FIRE_REPO, 123, 1, 456, 'package')}
        with patch.object(m, 'pending_runs', return_value=[(m.FIRE_REPO, parent)]), \
                patch.object(m, 'pending_jobs', return_value=[job(parent)]), \
                patch.object(m, 'capacity', return_value=False) as capacity:
            m.dispatch(executor, {}, seen)
            executor.submit.assert_not_called()
            capacity.return_value = True
            m.dispatch(executor, {}, seen)
            executor.submit.assert_called_once()
            m.dispatch(executor, {}, seen)
            executor.submit.assert_called_once()

    def lifecycle(self, repo, *, state='running', parent_change=None, cleanup_error=None, queued_change=None):
        parent, role = run(repo), 'package'
        queued = job(parent)
        name = 'winnow-ci-job-123-456-package'
        job_reads = 0
        def response(request_repo, path, body=None):
            nonlocal job_reads
            self.assertEqual(request_repo, repo)
            if path.endswith('generate-jitconfig'):
                return {'runner': {'id': 7}, 'encoded_jit_config': 'synthetic-test-value'}
            if path == 'actions/jobs/456':
                job_reads += 1
                return {**queued, **(queued_change or {})} if job_reads == 1 else {**queued, 'status': 'completed', 'conclusion': 'success'}
            return {**parent, **(parent_change or {})}
        with patch.object(m, 'api', side_effect=response) as api, \
                patch.object(m, 'create', return_value=(name, 2241)) as create, \
                patch.object(m, 'ssh') as ssh, patch.object(m, 'command', return_value=state), \
                patch.object(m, 'destroy', side_effect=cleanup_error) as destroy, \
                patch.object(m.subprocess, 'run') as delete, contextlib.redirect_stdout(io.StringIO()):
            if cleanup_error:
                with self.assertRaises(type(cleanup_error)):
                    m.worker(repo, role, parent, queued)
            else:
                m.worker(repo, role, parent, queued)
        create.assert_called_once_with('package', 123, 456)
        destroy.assert_called_once_with(name)
        return api, ssh, delete

    def test_jit_registration_and_cleanup_are_repository_scoped(self):
        for repo in m.REPOSITORIES:
            with self.subTest(repo=repo):
                api, ssh, delete = self.lifecycle(repo)
                jit = next(c for c in api.call_args_list if c.args[1].endswith('generate-jitconfig'))
                prefix = m.REPOSITORIES[repo]['prefix']
                self.assertEqual(jit.args[2]['labels'], ['self-hosted', 'macOS', 'X64',
                                                      f'{prefix}-tdx-package', f'{prefix}-run-123-1'])
                self.assertEqual(jit.args[2]['name'], 'winnow-ci-job-123-456-package')
                self.assertEqual(ssh.call_args.kwargs['input'], b'synthetic-test-value\n')
                self.assertNotIn('synthetic-test-value', ssh.call_args.args[1])
                self.assertFalse(any('/cancel' in c.args[1] for c in api.call_args_list))
                self.assertEqual(delete.call_args.args[0], ['gh', 'api', '--method', 'DELETE',
                                                           f'repos/{repo}/actions/runners/7'])

    def test_lost_worker_cancels_only_its_repo_and_reclaims_guest(self):
        api, _, delete = self.lifecycle(m.FIRE_REPO, state='shut off')
        self.assertIn(call(m.FIRE_REPO, 'actions/runs/123/cancel', {}), api.call_args_list)
        self.assertIn(call(m.FIRE_REPO, 'actions/runs/123/force-cancel', {}), api.call_args_list)
        delete.assert_called_once()

    def test_runner_is_deleted_even_when_domain_cleanup_fails(self):
        _, _, delete = self.lifecycle(m.FIRE_REPO, cleanup_error=RuntimeError('mock cleanup failure'))
        delete.assert_called_once()

    def test_completed_or_newer_attempt_during_boot_cleans_up_without_registering(self):
        for change in [{'status': 'completed'}, {'run_attempt': 2}]:
            api, ssh, delete = self.lifecycle(m.FIRE_REPO, parent_change=change)
            self.assertFalse(any(c.args[1].endswith('generate-jitconfig') for c in api.call_args_list))
            ssh.assert_not_called()
            delete.assert_not_called()

    def test_job_labels_or_status_changed_during_boot_cannot_receive_jit(self):
        for change in [{'status': 'completed'}, {'run_attempt': 2}, {'labels': ['fire-tdx-package']}]:
            api, _, delete = self.lifecycle(m.FIRE_REPO, queued_change=change)
            self.assertFalse(any(c.args[1].endswith('generate-jitconfig') for c in api.call_args_list))
            delete.assert_not_called()

    def test_untrusted_worker_input_has_no_host_or_github_effects(self):
        parent = run(m.FIRE_REPO)
        for parent_change, job_change in [
            ({'head_repository': {'full_name': 'fork/wallet'}}, {}),
            ({'event': 'pull_request_target'}, {}), ({}, {'run_attempt': 2}),
            ({}, {'labels': ['fire-tdx-package']}),
        ]:
            with patch.object(m, 'api') as api:
                with self.assertRaises(ValueError):
                    m.worker(m.FIRE_REPO, 'package', {**parent, **parent_change}, {**job(parent), **job_change})
                api.assert_not_called()
                m.create.assert_not_called()
                m.destroy.assert_not_called()

    def test_cancellation_never_targets_a_new_attempt_or_untrusted_run(self):
        parent = run(m.FIRE_REPO)
        for change in [{'run_attempt': 2}, {'status': 'completed'}, {'head_repository': None}]:
            with patch.object(m, 'api', return_value={**parent, **change}) as api:
                m.cancel_run(m.FIRE_REPO, parent)
            api.assert_called_once_with(m.FIRE_REPO, 'actions/runs/123')
        with patch.object(m, 'api', side_effect=[parent, {}, {**parent, 'run_attempt': 2}]) as api:
            m.cancel_run(m.FIRE_REPO, parent)
        self.assertIn(call(m.FIRE_REPO, 'actions/runs/123/cancel', {}), api.call_args_list)
        self.assertFalse(any('force-cancel' in c.args[1] for c in api.call_args_list))

    def test_cleanup_cannot_target_existing_workers(self):
        for name in ['winnow-1', 'winnow-2', 'winnow-3', 'winnow-poc16', 'macvm-0',
                     'winnow-ci-job-../../outside', 'fire-ci-job-123-456-package']:
            with self.assertRaises(ValueError):
                ORIGINAL_DESTROY(name)
        m.subprocess.run.assert_not_called()
        m.subprocess.run.side_effect = None
        ORIGINAL_DESTROY('winnow-ci-job-123-456-package')
        self.assertEqual(m.subprocess.run.call_count, 3)
        self.assertEqual(m.subprocess.run.call_args.args[0],
                         ['sudo', '-n', 'rm', '-rf', str(m.POOL / 'winnow-ci-job-123-456-package')])

    def test_disk_reserve_stops_new_allocations(self):
        with patch.object(m.shutil, 'disk_usage', return_value=Mock(free=99 * 1024**3)):
            self.assertFalse(m.capacity())
        with patch.object(m.shutil, 'disk_usage', side_effect=[Mock(free=101 * 1024**3), Mock(free=19 * 1024**3)]):
            self.assertFalse(m.capacity())

    def test_vm_creation_keeps_seed_read_only_and_uses_existing_domain_and_port(self):
        # Synthetic local XML only: no real image, hypervisor or guest access.
        with tempfile.TemporaryDirectory() as tmp:
            pool = Path(tmp)
            base = pool / 'base'
            base.mkdir()
            (base / 'VARS.fd').write_bytes(b'synthetic firmware')
            template = '''<domain xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
<name>seed</name><uuid>seed</uuid><memory>0</memory><currentMemory>0</currentMemory>
<vcpu>1</vcpu><cpu><topology cores="1"/></cpu><os><nvram>seed-vars</nvram></os>
<devices><disk><source file="/seed/OpenCore.qcow2"/><backingStore/></disk>
<disk><source file="/seed/macOS.qcow2"/></disk></devices>
<qemu:commandline><qemu:arg value="hostfwd=tcp:127.0.0.1:2230-:22"/>
<qemu:arg value="virtio-net-pci,mac=52:54:00:c9:19:30"/></qemu:commandline></domain>'''
            (base / 'template.xml').write_text(template)
            before = {p.name: p.read_bytes() for p in base.iterdir()}
            with patch.object(m, 'POOL', pool), patch.object(m, 'command') as command:
                name, port = ORIGINAL_CREATE('package', 123, 456)
            self.assertEqual((name, port), ('winnow-ci-job-123-456-package', 2241))
            self.assertEqual(before, {p.name: p.read_bytes() for p in base.iterdir()})
            root = ET.parse(pool / name / 'domain.xml').getroot()
            sources = [Path(d.find('source').get('file')) for d in root.findall('devices/disk')]
            self.assertTrue(all(p.parent == pool / name for p in sources))
            self.assertEqual(root.find('vcpu').text, '8')
            self.assertEqual(root.find('memory').text, str(24 * 1024 * 1024))
            self.assertIn(call(['qemu-img', 'create', '-f', 'qcow2', '-F', 'qcow2', '-b',
                                str(base / m.BOOT_DISK), str(pool / name / m.BOOT_DISK)]), command.call_args_list)
            self.assertEqual((pool / name / 'VARS.fd').read_bytes(), b'synthetic firmware')
            args = [a.get('value') for a in root.findall(f'{{{m.QEMU}}}commandline/{{{m.QEMU}}}arg')]
            self.assertIn('hostfwd=tcp:127.0.0.1:2241-:22', args)


ORIGINAL_CREATE, ORIGINAL_DESTROY = m.create, m.destroy


if __name__ == '__main__':
    unittest.main()
