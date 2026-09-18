import importlib.machinery
import importlib.util
import json
import re
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
        # the homepage's checkpoints must exist and be captured by the journey
        self.checkpoints = [name for _, shots in site.ACTS for name, _ in shots]
        for name in self.checkpoints:
            (self.root / f"docs/screenshots/{name}.png").write_bytes(b"image fixture")
        (self.root / "UITests/Checkpoints.swift").write_text("extension WinnowAppUITests {\n" + "".join(
            f'        Screenshots.capture(app, "{name}", testCase: self)\n' for name in self.checkpoints) + "}\n")
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

    def documented_inventory(self):
        """One fully documented journey with a test, and one guide without."""
        self.journeys = [
            {"id": "receive", "section": "everyday", "title": "Receive bitcoin",
             "description": "Share an address.", "tests": ["test01Receive"],
             "journey": ["Tap Receive.", "Read the address."],
             "limitations": "Labels stay on this device."},
            {"id": "fees", "section": "advanced", "title": "Replace a pending payment",
             "description": "Bump the fee.", "journey": ["Choose Bump fee."],
             "tests": [], "guide": "/vaults"},
        ]
        self.save()
        (self.root / "docs/vaults.html").write_text("<p>the signing guide</p>")
        return site.load_journeys(self.root)

    def test_homepage_modes_keep_the_complete_journey_available(self):
        journeys, cases = self.documented_inventory()
        homepage = site.homepage(journeys, cases)
        recording = site.recording_page(self.root)
        self.assertIn("Download for iPhone", homepage)
        self.assertIn("TestFlight", homepage)
        for mode in ("everyday", "both", "shared"):
            self.assertIn(f'id="mode-{mode}"', homepage)
            self.assertIn(f'aria-controls="policy-{mode} screen-{mode}"', homepage)
            self.assertIn(f'id="policy-{mode}"', homepage)
            self.assertIn(f'id="screen-{mode}"', homepage)
        self.assertIn('href="/recording" data-watch', homepage)
        self.assertIn('<video controls playsinline preload="none"', homepage)
        self.assertNotIn("autoplay", homepage)
        self.assertNotIn('href="/advanced', homepage)
        self.assertNotIn('href="/testing', homepage)
        self.assertEqual(recording.count("<video "), 1)
        self.assertIn(f'<source src="/{site.VIDEO_PATH}" type="video/mp4">', recording)
        self.assertNotIn("autoplay", recording)
        gallery = homepage.split('id="screens"', 1)[1].split('</details>', 1)[0]
        shown = re.findall(r'<img src="screenshots/([a-z0-9-]+)\.png"', gallery)
        self.assertEqual(shown, self.checkpoints)
        hero = homepage.split('class="wallet-screens"', 1)[1].split('</section>', 1)[0]
        featured = re.findall(r'<img src="screenshots/([a-z0-9-]+)\.png"', hero)
        self.assertEqual(len(featured), 3)
        self.assertTrue(set(featured).issubset(self.checkpoints))

    def test_homepage_cannot_show_a_screen_the_journey_never_captured(self):
        (self.root / "UITests/Checkpoints.swift").write_text("")
        with self.assertRaisesRegex(ValueError, "not captured by the journey"):
            site.load_journeys(self.root)

    def test_missing_checkpoint_image_is_rejected(self):
        (self.root / f"docs/screenshots/{self.checkpoints[0]}.png").unlink()
        with self.assertRaisesRegex(ValueError, "missing checkpoint screenshot"):
            site.load_journeys(self.root)

if __name__ == "__main__":
    unittest.main()
