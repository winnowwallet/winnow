"""Exercise runner selection without launching Xcode or a simulator."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'ci-app-tests'
class AppRunnerTests(unittest.TestCase):
    def test_missing_ambiguous_and_single_specifications(self):
        for count in [0,2,1]:
            with self.subTest(count=count),tempfile.TemporaryDirectory() as d:
                root=Path(d);products=root/'build/Build/Products';products.mkdir(parents=True)
                for i in range(count):(products/f'WinnowApp_{i}.xctestrun').write_text('fixture')
                binary=root/'xcodebuild';binary.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARG_LOG"\n');binary.chmod(0o755)
                result=subprocess.run([str(SCRIPT),str(root/'results'),'--skip-build'],capture_output=True,
                    env={**os.environ,'PATH':str(root)+':'+os.environ['PATH'],'SIMULATOR_ID':'fixture',
                         'DERIVED_DATA':str(root/'build'),'ARG_LOG':str(root/'args')})
                self.assertEqual(result.returncode==0,count==1)
                if count==1:
                    args=(root/'args').read_text().splitlines()
                    self.assertIn('-xctestrun',args);self.assertNotIn('-project',args)
                    self.assertIn('-only-testing:WinnowAppTests',args)
