[Back to main README](../README.md)

# Website and product explanations

This directory is the static website and the public explanation of Winnow's
features, architecture, testing, and limitations. The app also bundles five
technical guides and site.css so those explanations are available offline.

[The journey inventory](journeys.json) and
[app test source](../UITests/README.md) feed [build-site](../scripts/build-site),
which generates home and recording pages. The homepage gives an overview,
illustrates the signing choices, and then shows the journey itself: the sixteen
checkpoint screenshots the UI run captures, in three acts, each linking to the
full-size image. Generation refuses any checkpoint the journey does not capture,
so the page cannot show a screen no test produced. A link opens the full
recording; detailed feature descriptions stay off the homepage. Filmstrip styles
stay inline on the homepage, so site.css is unaffected.
The [signing guide](vaults.html) explains
the policies, and the [recording page](https://winnowwallet.com/recording) presents
the continuous payment journey with playback controls and source provenance.
Other pages are authored directly. Older guide illustrations keep their dated provenance.
[signing.js](signing.js) runs the homepage’s signing examples: a stolen hardware
key, a separate approved payment, shared savings, and a possible future loan.
Each scene plays once, has replay controls, and shows a still version for reduced
motion. Approvals travel to the payment; MuSig2 approvals merge into one on-chain
signature, while shared spending reveals its three keys and two-approval rule.
Without JavaScript, the signing scenes remain readable. The drawings come from
the page generator and use [site.css](site.css); no animation library is needed.
[The roadmap](roadmap.html) separates planned work from current behavior.
[Architecture](architecture.html) links directly to the focused technical guides.
Those HTML files are the maintained explanations; no separate paper or paper
index is needed. [_redirects](_redirects) sends old paper URLs to the architecture page.

Run `scripts/build-site --check` and, with real LFS images downloaded,
`scripts/check-site` from the root. Both accept `--root` for a staged repository.
[prepare-site-artifact](../scripts/prepare-site-artifact) builds the deployable
directory; [Website CI](../.github/workflows/site.yml) consumes that artifact.
The checks cover generation, local links, media objects, and the 25 MiB per-file
hosting limit, not rendered-browser layout or the truth of every prose claim.

For a successful CI journey, run `scripts/prepare-site-artifact OUTPUT --journey
JOURNEY --media-output MEDIA`. It copies all 16 current checkpoints, normalizes
the full recording with `+igndts` and no cuts, and records source SHA, run URL,
duration, and checksums in `journey-provenance.json`. The output includes a local
`/recording` page explaining that evidence. Replaying an older artifact requires
its `--source-sha` and `--run-url`; CI defaults to the current checkout and run.

Website-only builds use `--media MEDIA` to reuse the small normalized artifact
without video tools or raw result bundles. Its original recording provenance
stays intact while pages are regenerated from the current source. The optional
`--media-output` contains only the video, 16 PNGs, and provenance JSON for caching.
With neither media option, packaging retains the reviewed repository reference
assets and explicitly makes no new integration-result claim. Output directories
must be new. Packaging never changes repository media.
[Testing policy](testing.md), [the recording](videos/README.md),
[current and historical screenshots](screenshots/README.md), and
[security evidence](security/README.md) explain the supporting records.
