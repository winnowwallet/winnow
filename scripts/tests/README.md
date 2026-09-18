[Back to main README](../../README.md)

# Regression tests for repository tooling

These Python tests cover journey media reuse, website preparation, App Store
status parsing, and release policy. They prevent skipped checks being mistaken
for evidence and check the inputs used to prepare and release the app and site.

[test_ci_journey_cache.py](test_ci_journey_cache.py) checks test/build input
matching and requires successful same-repository evidence with a retained media
artifact. Missing or uncertain evidence must run fresh tests. Website-only reuse
keeps the recording's original provenance rather than claiming a new test run.

[test_build_site.py](test_build_site.py) exercises journey validation and
generation. [test_prepare_site_artifact.py](test_prepare_site_artifact.py) checks
fresh website assembly with new or reused journey media.

[test_appstore_status.py](test_appstore_status.py) and
[test_release_policy.py](test_release_policy.py) check release tooling with local
fixtures, without App Store requests or signing.

Run all suites from the repository root:

```sh
python3 -m unittest discover -s scripts/tests
```

The CI build job runs all five suites; the website job deploys its ready
artifact. These tests validate tooling behavior, not the rendered webpage or
the app itself.
