import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

loader = importlib.machinery.SourceFileLoader("build_site", str(Path(__file__).parents[1] / "build-site"))
spec = importlib.util.spec_from_loader(loader.name, loader)
site = importlib.util.module_from_spec(spec)
loader.exec_module(site)

class JourneyOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "docs/videos").mkdir(parents=True)
        (self.root / "docs/screenshots").mkdir()
        (self.root / "docs/screenshots/receive.png").write_bytes(b"image fixture")
        (self.root / "UITests").mkdir()
        self.source = self.root / site.TEST_PATH
        self.source.write_text("    func test01Receive() {}\n")
        (self.root / "docs" / site.VIDEO_PATH).write_bytes(b"recording fixture")
        self.journeys = [{"id": "receive", "section": "everyday", "tests": ["test01Receive"]}]
        self.save()

    def save(self):
        (self.root / "docs/journeys.json").write_text(json.dumps(self.journeys))

    def test_real_scenario_and_recording_are_accepted(self):
        journeys, cases = site.load_journeys(self.root)
        self.assertEqual(len(journeys), 1)
        self.assertEqual(set(cases), {"test01Receive"})

    def test_removed_test_cannot_keep_supporting_a_claim(self):
        self.source.write_text("")
        with self.assertRaisesRegex(ValueError, "missing app test"):
            site.load_journeys(self.root)

    def test_new_scenario_needs_a_documented_purpose(self):
        self.source.write_text(self.source.read_text() + "    func test02Undocumented() {}\n")
        with self.assertRaisesRegex(ValueError, "need a documented journey"):
            site.load_journeys(self.root)

    def test_missing_recording_is_rejected(self):
        (self.root / "docs" / site.VIDEO_PATH).unlink()
        with self.assertRaisesRegex(ValueError, "missing journey video"):
            site.load_journeys(self.root)

    def test_unresolved_recording_is_rejected(self):
        (self.root / "docs" / site.VIDEO_PATH).write_bytes(
            b"version https://git-lfs.github.com/spec/v1\n")
        with self.assertRaisesRegex(ValueError, "unresolved LFS pointer"):
            site.load_journeys(self.root)

    def test_inventory_can_include_features_without_ui_coverage(self):
        guide = {"id": "savings", "section": "everyday", "tests": [],
                 "title": "Shared savings", "description": "Choose co-owners.",
                 "journey": ["Review the signing policy."]}
        self.journeys.append(guide)
        self.save()
        journeys, _ = site.load_journeys(self.root)
        self.assertEqual(len(journeys), 2)
        self.assertEqual(journeys[1]["tests"], [])

    def test_feature_guidance_cannot_claim_another_tests_screenshot(self):
        self.journeys.append({"id": "savings", "section": "everyday",
                              "tests": [], "image": "receive"})
        self.save()
        with self.assertRaisesRegex(ValueError, "not captured by its app tests"):
            site.load_journeys(self.root)

    def test_optional_screenshot_needs_its_owning_capture(self):
        self.journeys[0]["image"] = "receive"
        self.save()
        with self.assertRaisesRegex(ValueError, "not captured by its app tests"):
            site.load_journeys(self.root)
        self.source.write_text('    func test01Receive() {\n'
                               '        Screenshots.capture(app, "receive", testCase: self)\n'
                               '    }\n')
        journeys, _ = site.load_journeys(self.root)
        self.assertEqual(journeys[0]["image"], "receive")
        (self.root / "docs/screenshots/receive.png").unlink()
        with self.assertRaisesRegex(ValueError, "missing screenshot"):
            site.load_journeys(self.root)

    def test_duplicate_journey_is_rejected(self):
        self.journeys.append(dict(self.journeys[0]))
        self.save()
        with self.assertRaisesRegex(ValueError, "duplicate or invalid"):
            site.load_journeys(self.root)

    def test_homepage_keeps_opening_material_and_video_lives_on_recording_page(self):
        homepage = site.homepage()
        recording = site.recording_page(self.root)
        main = homepage.split("<main>", 1)[1].split("</main>", 1)[0]
        self.assertIn("A Bitcoin wallet for your iPhone.", main)
        self.assertIn("Download on the App Store", main)
        self.assertIn("TestFlight", main)
        self.assertIn('id="signing-choices"', main)
        self.assertIn("<svg", main)
        self.assertNotIn('<video', homepage)
        self.assertNotIn('class="journey"', main)
        self.assertNotIn('class="jump-links"', main)
        self.assertNotIn('id="evidence"', main)
        self.assertNotIn("Advanced features", main)
        self.assertNotIn("What’s next", main)
        self.assertNotIn('href="/advanced', homepage)
        self.assertNotIn('href="/testing', homepage)
        self.assertEqual(recording.count("<video "), 1)
        self.assertIn('<video controls playsinline preload="metadata"', recording)
        self.assertIn(f'<source src="/{site.VIDEO_PATH}" type="video/mp4">', recording)
        self.assertNotIn("autoplay", recording)
        self.assertNotIn("<img", homepage)

if __name__ == "__main__":
    unittest.main()
