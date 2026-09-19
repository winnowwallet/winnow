import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('tdx_controller',Path(__file__).resolve().parents[1]/'tdx/controller.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class ControllerTests(unittest.TestCase):
    def test_old_queued_work_survives_pagination_and_completed_run_history(self):
        def run(i, status='queued'):
            return {'id': i, 'created_at': f'2026-09-19T{i:06d}', 'status': status,
                    'path': '.github/workflows/ci.yml', 'event': 'push',
                    'repository': {'full_name': m.REPO}, 'head_repository': {'full_name': m.REPO}}
        responses = [
            {'workflow_runs': [run(i) for i in range(101, 1, -1)]},
            {'workflow_runs': [run(1)]},
            {'workflow_runs': [run(0, 'in_progress'), run(999, 'completed')]},
        ]
        with patch.object(m, 'api', side_effect=responses) as request:
            self.assertEqual([r['id'] for r in m.pending_runs()], list(range(102)))
        self.assertEqual(request.call_args_list[1].args[0], 'actions/runs?status=queued&per_page=100&page=2')

    def test_only_trusted_workflow_runs_can_allocate_workers(self):
        run={'path':'.github/workflows/tdx-trial.yml','head_repository':{'full_name':m.REPO},
             'repository':{'full_name':m.REPO},'event':'pull_request','status':'in_progress'}
        self.assertTrue(m.eligible(run))
        for field,value in [('head_repository',{'full_name':'fork/winnow'}),('head_repository',None),('path','evil.yml'),('status','completed'),('event','pull_request_target')]:
            self.assertFalse(m.eligible({**run,field:value}))
    def test_only_queued_unambiguous_pool_jobs_are_selected(self):
        self.assertEqual(m.role_for({'status':'queued','labels':['winnow-tdx-build']}),'build')
        for status,labels in [('completed',['winnow-tdx-build']),('queued',['winnow-1']),('queued',['winnow-tdx-build','winnow-tdx-journey'])]:
            self.assertIsNone(m.role_for({'status':status,'labels':labels}))
    def test_cleanup_cannot_target_existing_workers(self):
        for name in ['winnow-1','winnow-2','winnow-3','winnow-poc16','macvm-0','winnow-ci-job-../../outside']:
            with self.assertRaises(ValueError):m.destroy(name)
    def test_disk_reserve_stops_new_allocations(self):
        class Disk:
            free=99*1024**3
        with patch.object(m.shutil,'disk_usage',return_value=Disk()):self.assertFalse(m.capacity())
    def test_resources_fit_dedicated_pool(self):
        self.assertEqual(sum(x[0] for x in m.ROLES.values()),44)
        self.assertEqual(sum(x[1] for x in m.ROLES.values()),112)

    def test_lost_worker_cancels_run_and_reclaims_guest_even_if_github_stalls(self):
        import contextlib,io
        calls=[]
        def api(path,body=None):
            calls.append(path)
            if path.endswith('generate-jitconfig'):
                return {'runner':{'id':7},'encoded_jit_config':'synthetic-test-value'}
            return {'status':'in_progress'}
        name='winnow-ci-job-123-456-units'
        with patch.object(m,'api',side_effect=api),patch.object(m,'create',return_value=(name,2243)), \
             patch.object(m,'ssh'),patch.object(m,'command',return_value='shut off'), \
             patch.object(m.time,'sleep'),patch.object(m,'destroy') as cleanup, \
             patch.object(m.subprocess,'run'),contextlib.redirect_stdout(io.StringIO()):
            m.worker('units',{'id':123,'run_attempt':1},{'id':456})
        self.assertIn('actions/runs/123/cancel',calls)
        self.assertIn('actions/runs/123/force-cancel',calls)
        cleanup.assert_called_once_with(name)
