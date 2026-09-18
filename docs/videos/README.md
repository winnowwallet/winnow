[Back to website notes](../README.md)

# Wallet journey recording

The [recording page](https://winnowwallet.com/recording) plays one continuous
journey: create the wallet, receive and send
an ordinary payment, then receive and send through MuSig2 and script-path 2-of-3
accounts. Bitcoin Core owns the other signing keys. The phone and one Core key
approve each shared-account payment; the third key in 2-of-3 stays available
but unused. Private signet blocks are mined automatically for prompt confirmation.
The 16 checkpoint screenshots remain secondary artifacts.

Each deployed website now has a `/recording` page identifying its video's
original source and test run. CI may supply a newer recording or reuse tested
media for website-only changes. The dated record below describes the movie
committed in this directory; it is not a live CI status or a guarantee that
every deployment uses this file.

## Website recording — 2026-09-17

- Test source: `809c383`, `test01CreateReceiveSendConfirm`, on
  `codex/single-signet-journey`.
- Device: iPhone 17 Pro simulator, iOS 26.5, Apple silicon Mac.
- Network: isolated custom signet, copied from a prepared bank fixture.
- Result: one test passed, zero failures, **213.202 seconds**. Bank setup:
  0.325 s; app journey including all 16 screenshots: 212.342 s.
- Journey phases: ordinary 35.264 s; MuSig2 101.585 s; 2-of-3 74.482 s.
- Original movie: 237.560 seconds, 138,654,231 bytes, H.264, 1206 × 2622.
- Evidence: `recovery/shared-account-2026-09-17/video-run/NodeUI.xcresult`,
  `node-ui.log`, `video.log`, `screenshots/`, and the untouched `journey.mp4`
  in the local Winnow workspace.
- Website copy: 206.567 seconds, 24,551,439 bytes, H.264 at 30 frames/second.
  Only 31 seconds of simulator/test-runner startup before the app's opening
  screen are removed. The app journey is continuous, with no steps cut or
  sped up. The original movie remains with the result bundle.
- The input contains conflicting decode timestamps. `+igndts` keeps its valid
  presentation timeline; omitting it can make FFmpeg drop opening screens.
  The browser copy has stable frame timing and its MP4 index at the front.

Reproduce the browser copy from the untouched recording:

```sh
ffmpeg -fflags +igndts -i journey.mp4 -ss 31 -vf fps=30 \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
  -movflags +faststart wallet-journey.mp4
```

Website movie SHA-256: `f1e9b721a03ebd856c6a5b60ec70b26805834a31dd17da48cc76b4d1bd9463b6`.

The opening screens, both signing exchanges, and final balances were visually
reviewed. The logs and xcresult establish success; the movie illustrates it.
All 16 accompanying stills come unchanged from the same run. Other PNGs retain
[their historical provenance](../screenshots/README.md). All funds and displayed
recovery words belong to the disposable test fixture.

## Earlier shared-build validation — 2026-09-17

The earlier `CI / app-build` job used one Debug build for app unit tests and the
recorded journey, followed by Release checks. It removed the separate node
workflow and DifferentialTests target.

A local validation of the shared Debug build passed 197 XCTest app tests plus
13 Swift Testing cases, then the same UI journey in **213.399 seconds**, with
both test invocations using `test-without-building`. Evidence is in
`recovery/shared-account-2026-09-17/combined-ci/`: `app-build.log`,
`units/AppTests.xcresult`, `units/app-tests.log`, and `journey/NodeUI.xcresult`
with its movie and screenshots. The checked-in website movie remains the
independently reviewed 213.202-second recording above; it is the same UI test source.

The subsequent [CI run at `5bbf6e1`](https://github.com/winnowwallet/winnow/actions/runs/35249124771)
passed under that earlier layout. Its `app-build` job took 7 minutes 40 seconds.
That measurement is not a timing result for the new consolidated workflow.

## Current website artifacts

The single CI `build` job now owns package, app, fuzz, lint/test gates and release
checks, then prepares the website artifact. `scripts/prepare-site-artifact`
normalizes a fresh continuous recording without trimming startup or app steps,
keeps all 16 checkpoints, and writes `journey-provenance.json` plus a local
`/recording` page. Its `--media-output` directory is a dedicated reusable bundle.

For website-only changes, matching test/build inputs allow a successful
same-repository run's normalized media to be reused unchanged. The generated
site is fresh, but the media retains its original source and run. The separate
website job downloads and deploys that ready same-run site artifact without
checkout or rebuilding. Manual, nightly and release runs always test fresh.

The first [consolidated CI run at `f9a8c78`](https://github.com/winnowwallet/winnow/actions/runs/35253439937)
passed on 2026-09-17. The build job took **11 minutes 28 seconds**, including
649 package tests, 210 app tests, the single journey in **247.107 seconds**,
Release checks, fuzz smoke, and website preparation. The separate deployment
took 41 seconds; the complete workflow took **12 minutes 17 seconds** from
creation to completion.

That run published the full **268.083-second** browser recording, **15,572,004
bytes**, and all 16 checkpoints to the [dated deployment](https://5c5c78fc.winnow-avs.pages.dev/).
Its [recording page](https://5c5c78fc.winnow-avs.pages.dev/recording) identifies
the original source and run. The normalized video SHA-256 is
`451fda1e1b59238f14045543e47938cbf1c6b7e01c34427dda14d75fdf6a6120`.
This is fresh-build evidence; website-only reuse is verified separately against
the same media artifact and test/build-input fingerprint.
