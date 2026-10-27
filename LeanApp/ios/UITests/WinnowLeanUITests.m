// The Lean app's UI journeys, in the simulator against the regtest node `backend-test --fixture` left
// running (scripts/ci-ui-journey). Each launches the app in test mode with a fresh pinned seed, so a reused
// node never shows an earlier run's coins, and checks what the app shows against what the node holds.
#import <XCTest/XCTest.h>
#import "WLCoreSigner.h"
#import "WLHost.h"
#import "WLTest.h"

static const int64_t WLFunding = 5000000;
static const int64_t WLPayment = 1000000;
static const int64_t WLRecoveryPayment = 500000;
/// The builder's shortest recovery delay: one day.
static const NSInteger WLRecoveryBlocks = 144;

@interface WinnowLeanUITests : XCTestCase
@property (nonatomic, strong) XCUIApplication *app;
@property (nonatomic, copy) NSString *controlFile;
@end

@implementation WinnowLeanUITests

- (void)setUp {
    self.continueAfterFailure = NO;
    self.executionTimeAllowance = 900;
    self.controlFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"winnow-ui-%@.json", NSUUID.UUID.UUIDString]];
}

- (void)tearDown {
    [self.app terminate];
    [NSFileManager.defaultManager removeItemAtPath:self.controlFile error:nil];
}

/// What the app's Paste buttons read in test mode (`WINNOW_E2E_CONTROL_FILE`).
- (void)setClipboard:(NSString *)text {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"clipboard": text} options:0 error:nil];
    XCTAssertTrue([json writeToFile:self.controlFile atomically:YES]);
}

/// Launches the app in test mode on the fixture's node, as its only peer.
- (XCUIApplication *)launch:(NSString *)run extra:(NSDictionary<NSString *, NSString *> *)extra {
    WLHost *host = WLHost.shared;
    NSString *entropy = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    NSMutableDictionary *env = [@{
        @"WINNOW_E2E": @"1",
        @"WINNOW_E2E_RUN": run,
        @"WINNOW_E2E_RESET": @"1",
        @"WINNOW_E2E_ENTROPY": entropy,
        @"WINNOW_E2E_NETWORK": @"regtest",
        @"WINNOW_E2E_PEER": [NSString stringWithFormat:@"127.0.0.1:%ld", (long)host.p2p],
        @"WINNOW_E2E_PEER_COUNT": @"1",
        @"WINNOW_E2E_SYNC_INTERVAL": @"3",
        @"WINNOW_E2E_CONTROL_FILE": self.controlFile,
    } mutableCopy];
    [env addEntriesFromDictionary:extra];
    self.app = [XCUIApplication new];
    self.app.launchEnvironment = env;
    [self.app launch];
    return self.app;
}

/// Creates the wallet and confirms its words were written down; the home screen with its balance.
- (void)createWallet:(XCUIApplication *)app {
    XCTAssertTrue([WLElement(app, @"createWalletButton") waitForExistenceWithTimeout:60], @"onboarding did not open");
    WLShot(self, app, @"01-onboarding");
    WLTap(self, app, @"createWalletButton");
    XCUIElement *written = WLElement(app, @"writtenDownToggle");
    XCTAssertTrue([written waitForExistenceWithTimeout:60], @"creation did not show the recovery words");
    WLShot(self, app, @"02-backup-words");
    XCTAssertTrue(WLScrollTo(app, written));
    [written tap];
    WLTap(self, app, @"backupDoneButton");
    XCTAssertTrue([WLElement(app, @"receiveButton") waitForExistenceWithTimeout:30], @"the wallet did not open");
    XCTAssertTrue([WLElement(app, @"balanceText") waitForExistenceWithTimeout:30]);
}

/// The receive address the app shows (its label skipped).
- (NSString *)receiveAddress:(XCUIApplication *)app {
    WLTap(self, app, @"receiveButton");
    XCUIElement *skip = WLElement(app, @"skipReceiveAddressLabelButton");
    if ([skip waitForExistenceWithTimeout:20]) [skip tap];
    XCUIElement *shown = WLElement(app, @"receiveAddress");
    XCTAssertTrue([shown waitForExistenceWithTimeout:30], @"Receive shows no address");
    NSString *address = WLText(shown);
    XCTAssertTrue([address hasPrefix:@"bcrt1"], @"not a regtest address: %@", address);
    return address;
}

- (int64_t)balance:(XCUIApplication *)app { return WLDigits(WLText(WLElement(app, @"balanceText"))); }

/// The one transaction that entered the mempool after `before`.
- (NSString *)newMempoolTransaction:(NSSet<NSString *> *)before within:(NSTimeInterval)timeout {
    __block NSString *txid = nil;
    WLPoll(timeout, 1, ^{
        NSMutableSet *now = [WLHost.shared.mempool mutableCopy];
        [now minusSet:before];
        txid = now.anyObject;
        return (BOOL)(txid != nil);
    });
    return txid;
}

/// Create a wallet, receive from the node, send to it and see the payment confirm: upstream's
/// test01CreateReceiveSendConfirm on regtest (the silent payment leg is not part of the Lean app yet).
- (void)testCreateReceiveSendConfirm {
    WLHost *host = WLHost.shared;
    NSString *destination = host.bankAddress;
    [self setClipboard:destination];
    XCUIApplication *app = [self launch:@"journey" extra:@{}];
    [self createWallet:app];

    NSString *address = [self receiveAddress:app];
    WLShot(self, app, @"03-receive");
    WLTap(self, app, @"closeReceiveButton");

    NSString *funding = [host fund:address sats:WLFunding];
    XCTAssertTrue(WLPoll(90, 1, ^{ return (BOOL)([self balance:app] == WLFunding); }),
                  @"the wallet did not find the confirmed payment (balance %lld)", [self balance:app]);
    XCTAssertTrue([WLElement(app, [@"historyPayment-" stringByAppendingString:funding]) waitForExistenceWithTimeout:20],
                  @"the funding transaction is missing from Activity");
    XCUIElement *sync = WLElement(app, @"syncSummaryText");
    XCTAssertTrue(WLPoll(60, 0.5, ^{ return [WLText(sync) isEqualToString:@"Up to date"]; }), @"sync: %@", WLText(sync));
    WLShot(self, app, @"04-home-funded");

    WLTap(self, app, @"openSendButton");
    WLTap(self, app, @"pasteDestinationButton");
    WLType(self, app, @"amountField", [NSString stringWithFormat:@"%lld", WLPayment]);
    WLTap(self, app, @"reviewButton");
    XCUIElement *send = WLElement(app, @"sendButton");
    XCTAssertTrue([send waitForExistenceWithTimeout:30], @"the payment review did not open");
    XCTAssertEqualObjects(WLText(WLElement(app, @"reviewDestination")), destination);
    XCTAssertEqual(WLDigits(WLText(WLElement(app, @"reviewAmount"))), WLPayment);
    int64_t fee = WLDigits(WLText(WLElement(app, @"reviewFee")));
    XCTAssertGreaterThan(fee, 0);
    WLShot(self, app, @"05-send-review");

    NSSet *before = host.mempool;
    WLTap(self, app, @"sendButton");
    NSString *txid = [self newMempoolTransaction:before within:60];
    XCTAssertNotNil(txid, @"the node never received the payment");
    NSString *script = [host scriptPubKey:destination];
    BOOL paysDestination = NO;
    for (NSDictionary *output in [host transaction:txid][@"vout"]) {
        if ([output[@"scriptPubKey"][@"hex"] isEqualToString:script]) {
            paysDestination = YES;
            XCTAssertEqual(llround([output[@"value"] doubleValue] * 1e8), WLPayment);
        }
    }
    XCTAssertTrue(paysDestination, @"the transaction the node accepted does not pay the reviewed destination");

    [host mine:1];
    XCTAssertTrue([WLElement(app, @"broadcastConfirmed") waitForExistenceWithTimeout:90],
                  @"the open receipt did not notice the confirmation");
    // the payment is to the node's wallet, which knows it once confirmed (the node keeps no txindex)
    NSDictionary *confirmed = [host wallet:@"w" cliJSON:@[@"gettransaction", txid]];
    XCTAssertGreaterThan([confirmed[@"confirmations"] integerValue], 0);
    WLShot(self, app, @"06-send-confirmed");
    WLTap(self, app, @"closeSendButton");
    XCTAssertTrue(WLPoll(60, 1, ^{ return (BOOL)([self balance:app] == WLFunding - WLPayment - fee); }),
                  @"balance after the payment: %lld", [self balance:app]);
    XCTAssertTrue([WLElement(app, [@"historyPayment-" stringByAppendingString:txid]) waitForExistenceWithTimeout:20],
                  @"the payment is missing from Activity");
    WLShot(self, app, @"07-home-after-send");
}

/// Advanced mode, through its alert, then the Wallet tab.
- (void)turnOnAdvanced:(XCUIApplication *)app {
    WLTap(self, app, @"advancedModeButton");
    XCUIElement *on = app.alerts.buttons[@"Turn on"];
    XCTAssertTrue([on waitForExistenceWithTimeout:10], @"no Advanced mode alert");
    [on tap];
    XCUIElement *wallet = app.tabBars.buttons[@"Wallet"];
    XCTAssertTrue([wallet waitForExistenceWithTimeout:15], @"Advanced mode shows no tabs");
    [wallet tap];
}

/// A label shown by the app, found by its text (zero-width spaces ignored).
- (XCUIElement *)text:(XCUIApplication *)app beginningWith:(NSString *)prefix {
    return [self text:app matching:[@"^" stringByAppendingString:[NSRegularExpression escapedPatternForString:prefix]]];
}

- (XCUIElement *)text:(XCUIApplication *)app matching:(NSString *)pattern {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(id<XCUIElementAttributes> e, NSDictionary *b) {
        NSString *text = [e.label stringByReplacingOccurrencesOfString:@"\u200B" withString:@""];
        return [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
    }];
    return [app.staticTexts matchingPredicate:p].firstMatch;
}

/// The first input of the transaction `txid` in the mempool, with its witness.
- (NSDictionary *)spendingInput:(NSString *)txid {
    return [[WLHost.shared transaction:txid][@"vin"] firstObject];
}

/// Hex lengths of the witness's first `count` items, sorted.
static NSArray<NSNumber *> *WLWitnessSizes(NSArray<NSString *> *witness, NSUInteger count) {
    NSMutableArray *sizes = [NSMutableArray array];
    for (NSUInteger i = 0; i < count && i < witness.count; i++) [sizes addObject:@(witness[i].length)];
    return [sizes sortedArrayUsingSelector:@selector(compare:)];
}

/// A 2-of-3 Taproot multisig account between the phone and two Bitcoin Core wallets, with a recovery path
/// letting any one of them spend a coin after a day (upstream's MultisigJourney, built in the app's own
/// builder): its first address must be Core's; the phone creates the spend and signs first, each Core wallet
/// signs its copy with its own libsecp256k1, the phone combines both (three signatures where two are
/// needed), finalizes and broadcasts, and Core must accept a witness carrying exactly two. Then, past the
/// delay, the phone alone spends the change on the recovery path and Core accepts the CSV-locked witness.
- (void)testMultisigTwoOfThreeWithRecovery {
    WLHost *host = WLHost.shared;
    NSString *run = [NSUUID.UUID.UUIDString substringToIndex:8];
    WLCoreSigner *core = [[WLCoreSigner alloc] initWithWallet:[@"ui-core-" stringByAppendingString:run]];
    WLCoreSigner *second = [[WLCoreSigner alloc] initWithWallet:[@"ui-core-second-" stringByAppendingString:run]];
    XCUIApplication *app = [self launch:@"multisig" extra:@{}];
    [self createWallet:app];
    [self turnOnAdvanced:app];

    // the account, in the app's builder: this phone, the two Core keys, any 2 of 3, any 1 after a day
    WLTap(self, app, @"multisigBuildButton");
    WLType(self, app, @"multisigBuildNameField", @"Phone and two Cores");
    for (WLCoreSigner *signer in @[core, second]) {
        [self setClipboard:signer.keyExpression];
        WLTap(self, app, @"multisigPasteSignerButton");
    }
    XCTAssertTrue([[self text:app beginningWith:@"Signers · 3"] waitForExistenceWithTimeout:10], @"the two Core keys were not added");
    XCTAssertTrue([self text:app beginningWith:@"Any 2 of 3 spend at once"].exists);
    WLTap(self, app, @"multisigRecoveryToggle");
    XCTAssertTrue([[self text:app beginningWith:@"Any 1 of the 3 signers"] waitForExistenceWithTimeout:10]);
    XCUIElement *days = WLElement(app, @"multisigRecoveryDaysStepper");
    XCTAssertTrue(WLScrollTo(app, days));
    XCUIElement *delay = [self text:app matching:@"^After \\d+ days \\("];
    for (int i = 0; i < 40 && ![WLText(delay) hasPrefix:@"After 1 days"]; i++) [days.buttons[@"Decrement"] tap];
    XCTAssertEqualObjects(WLText(delay), ([NSString stringWithFormat:@"After 1 days (%ld blocks)", (long)WLRecoveryBlocks]));
    WLShot(self, app, @"10-multisig-build");
    WLTap(self, app, @"multisigCreateAccountButton");
    XCTAssertTrue([WLElement(app, @"multisigCreated") waitForExistenceWithTimeout:30], @"the account was not created");
    XCUIElement *created = WLElement(app, @"multisigCreatedDescriptor");
    XCTAssertTrue(WLScrollTo(app, created));
    NSString *descriptor = WLText(created);
    XCTAssertTrue([descriptor hasPrefix:@"tr("], @"not a descriptor: %@", descriptor);
    [core importAccount:descriptor];
    [second importAccount:descriptor];
    WLTap(self, app, @"multisigOpenAccountButton");

    // receive: the address on screen is Core's first address of the account
    NSString *first = WLDeriveAddress(descriptor, 0);
    XCUIElement *shown = WLElement(app, @"multisigReceiveAddress");
    XCTAssertTrue([shown waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects(WLText(shown), first, @"the account's first address is not Core's");
    NSString *funding = [host fund:first sats:WLFunding];
    XCUIElement *balance = WLElement(app, @"multisigBalance");
    XCTAssertTrue(WLPoll(90, 1, ^{ return (BOOL)(WLDigits(WLText(balance)) == WLFunding); }),
                  @"the account did not find %@ (balance %@)", funding, WLText(balance));
    WLShot(self, app, @"11-multisig-funded");

    // the phone creates the spend and signs first; one signature is not enough
    NSString *destination = host.bankAddress;
    WLTap(self, app, @"multisigPSBTButton");
    WLType(self, app, @"multisigAddressField", destination);
    WLType(self, app, @"multisigAmountField", [NSString stringWithFormat:@"%lld", WLPayment]);
    WLType(self, app, @"multisigFeeRateField", @"2");
    WLTap(self, app, @"multisigCreateButton");
    XCUIElement *feeText = WLElement(app, @"multisigFee");
    XCTAssertTrue([feeText waitForExistenceWithTimeout:30], @"the PSBT review did not open");
    int64_t fee = WLDigits(WLText(feeText));
    XCTAssertGreaterThan(fee, 0);
    WLTap(self, app, @"multisigSignButton");
    XCUIElement *count = WLElement(app, @"multisigSignatureCount");
    XCTAssertTrue(WLPoll(30, 0.3, ^{ return [WLText(count) isEqualToString:@"1 of 2"]; }), @"after the phone: %@", WLText(count));
    XCUIElement *broadcast = WLElement(app, @"multisigBroadcastButton");
    XCTAssertTrue(WLScrollTo(app, broadcast));
    XCTAssertFalse(broadcast.isEnabled, @"one signer alone cannot send");
    XCUIElement *shared = WLElement(app, @"multisigPSBTText");
    XCTAssertTrue(WLScrollTo(app, shared));
    NSString *phoneSigned = WLText(shared);
    XCTAssertTrue([phoneSigned hasPrefix:@"cHNidP8"], @"not a PSBT: %@", phoneSigned);
    WLShot(self, app, @"12-multisig-one-signature");

    // each Core wallet signs its own copy; the phone combines both
    NSArray *rounds = @[@[core, @"2 of 2"], @[second, @"3 of 2"]];
    for (NSArray *round in rounds) {
        WLCoreSigner *signer = round[0];
        NSString *expected = round[1];
        [self setClipboard:[signer sign:phoneSigned]];
        WLTap(self, app, @"psbtPasteButton");
        WLTap(self, app, @"addPSBTButton");
        XCTAssertTrue(WLPoll(30, 0.3, ^{ return [WLText(count) isEqualToString:expected]; }),
                      @"after %@: %@", signer.wallet, WLText(count));
    }

    // the phone finalizes and broadcasts; Core accepts a witness with exactly two signatures
    NSSet *before = host.mempool;
    WLTap(self, app, @"multisigBroadcastButton");
    XCTAssertTrue([WLElement(app, @"multisigPaymentSent") waitForExistenceWithTimeout:30], @"the payment was not sent");
    NSString *txid = [self newMempoolTransaction:before within:30];
    XCTAssertNotNil(txid, @"Core did not accept the multisig payment");
    NSDictionary *input = [self spendingInput:txid];
    XCTAssertEqualObjects(input[@"txid"], funding);
    NSArray *witness = input[@"txinwitness"];
    XCTAssertEqual(witness.count, 5u, @"three key slots, the leaf script and the control block");
    XCTAssertEqualObjects(WLWitnessSizes(witness, 3), (@[@0, @128, @128]), @"exactly two 64-byte signatures");
    XCTAssertEqual([witness.lastObject length], 130u, @"a 65-byte control block");
    BOOL paid = NO;
    for (NSDictionary *output in [host transaction:txid][@"vout"])
        if ([output[@"scriptPubKey"][@"hex"] isEqualToString:[host scriptPubKey:destination]])
            paid = llround([output[@"value"] doubleValue] * 1e8) == WLPayment;
    XCTAssertTrue(paid, @"the spend does not pay the destination the reviewed amount");
    WLShot(self, app, @"13-multisig-sent");
    [host mine:1];
    NSInteger spentAt = [[host cliJSON:@[@"getblockcount"]] integerValue];
    [app.navigationBars.buttons[@"Back"] tap];
    XCTAssertTrue(WLPoll(90, 1, ^{ return (BOOL)(WLDigits(WLText(balance)) == WLFunding - WLPayment - fee); }),
                  @"the account's change: %@", WLText(balance));

    // past the delay, the phone alone spends the change on the recovery path
    NSInteger height = [[host cliJSON:@[@"getblockcount"]] integerValue];
    if (height < spentAt + WLRecoveryBlocks - 1) [host mine:spentAt + WLRecoveryBlocks - 1 - height];
    WLTap(self, app, @"multisigPSBTButton");
    WLTap(self, app, @"multisigPathPicker");
    XCUIElement *recovery = app.buttons[@"Recovery path"];
    XCTAssertTrue([recovery waitForExistenceWithTimeout:10], @"the spend screen offers no recovery path");
    [recovery tap];
    NSString *recoveryDestination = host.bankAddress;
    WLType(self, app, @"multisigAddressField", recoveryDestination);
    WLType(self, app, @"multisigAmountField", [NSString stringWithFormat:@"%lld", WLRecoveryPayment]);
    WLType(self, app, @"multisigFeeRateField", @"2");
    // the phone may not have seen the last blocks yet: create until the coin unlocks
    XCTAssertTrue(WLPoll(120, 3, ^{
        if (feeText.exists) return YES;
        XCUIElement *create = WLElement(app, @"multisigCreateButton");
        if (create.exists && create.isEnabled && WLScrollTo(app, create)) [create tap];
        return [feeText waitForExistenceWithTimeout:2];
    }), @"the recovery spend was not created");
    XCUIElement *recoveryCount = WLElement(app, @"multisigRecoverySignatureCount");
    XCTAssertTrue([recoveryCount waitForExistenceWithTimeout:10]);
    XCTAssertEqualObjects(WLText(recoveryCount), @"0 of 1");
    WLTap(self, app, @"multisigSignButton");
    XCTAssertTrue(WLPoll(30, 0.3, ^{ return [WLText(recoveryCount) isEqualToString:@"1 of 1"]; }),
                  @"after the phone's recovery signature: %@", WLText(recoveryCount));
    before = host.mempool;
    WLTap(self, app, @"multisigBroadcastButton");
    XCTAssertTrue([WLElement(app, @"multisigPaymentSent") waitForExistenceWithTimeout:30]);
    NSString *recovered = [self newMempoolTransaction:before within:30];
    XCTAssertNotNil(recovered, @"Core did not accept the recovery spend");
    input = [self spendingInput:recovered];
    XCTAssertEqualObjects(input[@"txid"], txid, @"the recovery spend does not spend the change");
    XCTAssertEqual([input[@"sequence"] integerValue], WLRecoveryBlocks);
    witness = input[@"txinwitness"];
    XCTAssertEqual(witness.count, 5u, @"one signature, two empty slots, the recovery leaf and its control block");
    XCTAssertEqualObjects(WLWitnessSizes(witness, 3), (@[@0, @0, @128]));
    XCTAssertEqual([witness.lastObject length], 130u);
    WLShot(self, app, @"14-multisig-recovered");
    [host mine:1];
    NSDictionary *tip = [host cliJSON:@[@"getblock", [host cli:@[@"getbestblockhash"]]]];
    XCTAssertTrue([tip[@"tx"] containsObject:recovered], @"the recovery spend was not mined");
}

/// A 2-of-2 between the phone and a Ledger, with test mode's simulated Ledger (`WINNOW_E2E_LEDGER`, the
/// Lean device behind the app's real APDU program): pair it, have it derive the receive address, which
/// must also be Core's, fund the account, sign the spend with the phone and the Ledger, and Core must
/// accept a witness carrying both signatures.
- (void)testLedgerPairVerifySpend {
    WLHost *host = WLHost.shared;
    NSString *ledgerSeed = [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    XCUIApplication *app = [self launch:@"ledger" extra:@{@"WINNOW_E2E_LEDGER": ledgerSeed}];
    [self createWallet:app];
    [self turnOnAdvanced:app];

    WLTap(self, app, @"ledgerPairButton");
    WLType(self, app, @"ledgerNameField", @"Ledger savings");
    WLTap(self, app, @"ledgerPairStartButton");
    XCUIElement *account = app.buttons[@"Ledger savings"];
    XCTAssertTrue([account waitForExistenceWithTimeout:60], @"pairing did not create the account");
    XCTAssertTrue(WLScrollTo(app, account));
    [account tap];
    XCUIElement *policy = WLElement(app, @"multisigPolicy");
    XCTAssertTrue([policy waitForExistenceWithTimeout:20]);
    XCTAssertEqualObjects(WLText(policy), @"2 of 2");

    // the Ledger derives the address the phone shows, and so does Core from the account's descriptor
    XCUIElement *shown = WLElement(app, @"multisigReceiveAddress");
    XCTAssertTrue([shown waitForExistenceWithTimeout:20]);
    NSString *address = WLText(shown);
    WLTap(self, app, @"ledgerVerifyButton");
    XCUIElement *verified = WLElement(app, @"ledgerVerifyResult");
    XCTAssertTrue([verified waitForExistenceWithTimeout:60], @"the Ledger did not answer");
    XCTAssertTrue([WLText(verified) hasPrefix:@"The Ledger derived this same address."], @"%@", WLText(verified));
    XCUIElement *descriptorText = WLElement(app, @"multisigDescriptor");
    XCTAssertTrue(WLScrollTo(app, descriptorText));
    XCTAssertEqualObjects(WLDeriveAddress(WLText(descriptorText), 0), address, @"the account's first address is not Core's");
    WLShot(self, app, @"20-ledger-verified");

    NSString *funding = [host fund:address sats:WLFunding];
    XCUIElement *balance = WLElement(app, @"multisigBalance");
    XCTAssertTrue(WLPoll(90, 1, ^{ return (BOOL)(WLDigits(WLText(balance)) == WLFunding); }),
                  @"the account did not find %@ (balance %@)", funding, WLText(balance));

    NSString *destination = host.bankAddress;
    WLTap(self, app, @"multisigPSBTButton");
    WLType(self, app, @"multisigAddressField", destination);
    WLType(self, app, @"multisigAmountField", [NSString stringWithFormat:@"%lld", WLPayment]);
    WLType(self, app, @"multisigFeeRateField", @"2");
    WLTap(self, app, @"multisigCreateButton");
    XCTAssertTrue([WLElement(app, @"multisigFee") waitForExistenceWithTimeout:30], @"the PSBT review did not open");
    XCUIElement *count = WLElement(app, @"multisigSignatureCount");
    WLTap(self, app, @"multisigSignButton");
    XCTAssertTrue(WLPoll(30, 0.3, ^{ return [WLText(count) isEqualToString:@"1 of 2"]; }), @"after the phone: %@", WLText(count));
    WLTap(self, app, @"ledgerSignButton");
    XCTAssertTrue(WLPoll(60, 0.3, ^{ return [WLText(count) isEqualToString:@"2 of 2"]; }), @"after the Ledger: %@", WLText(count));
    WLShot(self, app, @"21-ledger-signed");

    NSSet *before = host.mempool;
    WLTap(self, app, @"multisigBroadcastButton");
    XCTAssertTrue([WLElement(app, @"multisigPaymentSent") waitForExistenceWithTimeout:30], @"the payment was not sent");
    NSString *txid = [self newMempoolTransaction:before within:30];
    XCTAssertNotNil(txid, @"Core did not accept the Ledger-signed payment");
    NSDictionary *input = [self spendingInput:txid];
    XCTAssertEqualObjects(input[@"txid"], funding);
    NSArray *witness = input[@"txinwitness"];
    XCTAssertEqual(witness.count, 4u, @"two signatures, the leaf script and the control block");
    XCTAssertEqualObjects(WLWitnessSizes(witness, 2), (@[@128, @128]), @"the phone's and the Ledger's signatures");
    [host mine:1];
    NSDictionary *tip = [host cliJSON:@[@"getblock", [host cli:@[@"getbestblockhash"]]]];
    XCTAssertTrue([tip[@"tx"] containsObject:txid], @"the payment was not mined");
}

@end
