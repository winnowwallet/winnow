[Back to main README](../../README.md)

# Regression tests for repository tooling

These Python tests check journey media reuse, website preparation and code-size
reports. They prevent skipped checks being mistaken for evidence, missing test
mappings, and changes in counting policy that produce misleading output.

[test_ci_journey_cache.py](test_ci_journey_cache.py) checks test/build input
matching and requires successful same-repository evidence with a retained media
artifact. Missing or uncertain evidence must run fresh tests. Website-only reuse
keeps the recording's original provenance rather than claiming a new test run.

[test_build_site.py](test_build_site.py) exercises journey
validation and generation. [test_prepare_site_artifact.py](test_prepare_site_artifact.py)
checks fresh website assembly with new or reused journey media.
[test_report_loc.py](test_report_loc.py)
uses temporary repositories to check file categories and historical comparisons.
Its synthetic infra paths intentionally test older trees after that directory's deletion.

From the root, run `python3 -m unittest discover -s scripts/tests -p test_build_site.py`.
The CI build job runs the cache, generation and preparation regressions; the
website job only deploys its ready artifact. The LOC reporter is manual.
For all suites, download the official `cloc-2.10.pl` release asset and use
[report-loc.py](../report-loc.py)'s pinned checksum, then run
`CLOC=/path/to/cloc-2.10.pl python3 -m unittest discover -s scripts/tests`.
The LOC suite requires `CLOC`; omitting it is an error.
These tests validate tooling behavior, not the rendered webpage or the app itself.
