[Back to main README](../README.md)

# Asserted app journeys

XCUITest drives real screens for wallet creation, recovery, receiving, sending,
saved recipients, shared savings, and Advanced signing. These tests check the combined app,
wallet, and node behavior that isolated unit tests cannot establish.
The ordinary, shared, and extra-device journeys all start payments in Send.
Form editing is checked once; each signing journey then checks its own approval
rules and the result accepted by the Bitcoin node. Ordinary co-owner requests
and raw PSBTs signed by a group both go through Approve a request. The group
journey approves on the phone, exports the raw request to the group, imports its
reply, and sends. It checks that Advanced mode adds no second signing entry.

[WinnowAppUITests.swift](WinnowAppUITests.swift) contains the scenarios.
[The journey inventory](../docs/journeys.json) maps them to the public website;
[build-site](../scripts/build-site) validates selectors and named screenshot captures.
[Node support](../Tests/Support/Node/README.md) supplies transactions and mined blocks.

[Node CI](../.github/workflows/node-tests.yml) creates a disposable signet and
uploads the result bundle, screenshots, and timing observations.
[The testing guide](../docs/testing.html) explains those artifacts and limits.
Screenshots do not turn a failed assertion into a pass; simulator evidence does
not establish physical-device behavior.

Review the images themselves before publishing them. On the TDX macOS VM,
iOS 26.5 captures have omitted tab bars and system-sheet backgrounds even when
all assertions pass. That VM reports no Metal device; Reduce Transparency did
not restore the missing tabs. Use a Mac with working simulator graphics for
publication captures, and keep the original result bundle and source revision.
The runner graphics problem is tracked in [#84](https://github.com/winnowwallet/winnow/issues/84).
