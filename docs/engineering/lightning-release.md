# Releasing Winnow with Lightning

Lightning ships inside Winnow (`com.btcswift.app`), so there is one release:
push a `vX.Y.Z` tag and `.github/workflows/release.yml` runs.

1. **Run CI for the tagged tree.** That is every tdx lane, the CRAP gate, and
   the Swift Lightning job (independent peers and the recorded journey).
   Nothing below runs unless all of it passes.
2. **Apply the reviewed export compliance answer**
   (`scripts/encryption-declaration-key`, from `WINNOW_NONEXEMPT_ENCRYPTION`).
3. **Archive and verify.** Archive `WinnowApp`, then check:
   - the signed identity, production iCloud and the encryption answer
     (`verify-signed-archive`);
   - that no test activation is present (`verify-release-e2e-exclusion`, which
     includes the Lightning UI fixture's markers);
   - the exported package.
4. **Generate the SBOM and provenance** for the exact package, naming this
   repository as the source.
5. **Upload**, wait for processing, and add the What to Test notes
   (`docs/testflight-what-to-test.txt`).
6. **Add the internal and external TestFlight groups.**
7. **Read the processed build back** (`scripts/asc-preflight`): one VALID
   build of this version and number, carrying the reviewed answer.

## Export compliance

Lightning's Noise transport and Sphinx onions include cryptography implemented
outside Apple's OS ([inventory](../release/encryption-inventory.md)). The
answer is the account holder's, not the repository's.

- **Until it is reviewed** (`WINNOW_NONEXEMPT_ENCRYPTION` unset):
  - builds carry no encryption key, so App Store Connect asks its questions for
    each build;
  - the release uploads and adds notes, then reports that testers wait for
    those answers.
- **To answer through the API:**
  - Fill in and approve `docs/release/encryption-questionnaire.json`, including
    the French-store answer, which depends on Winnow's App Store territories.
  - Run **TestFlight encryption** (`declare`) for the build, then
    **TestFlight recovery** to add the groups.
  - `scripts/encryption-declaration` submits exactly those answers and applies
    Apple's determination to the build.
- **Once Apple has a determination:**
  - Set `WINNOW_NONEXEMPT_ENCRYPTION` (`YES` or `NO`) and, if Apple issued one,
    `WINNOW_ENCRYPTION_COMPLIANCE_CODE`.
  - Later builds carry the key, and `verify-signed-archive` checks it.

## Checks CI cannot make

Record these on a physical device for each release that changes Lightning:
- successful and cancelled Face ID or passcode approval for funding, payment
  and close (cancelling must submit nothing);
- the exact Share and Copy contents;
- locking and unlocking during a payment;
- channel identity after an update;
- iCloud backup of the Bitcoin wallet alongside an exported Lightning recovery
  file.

Simulator runs do not establish locked-device journal or Keychain protection.
A funded mainnet payment is separate from the regtest interoperability CI runs.
