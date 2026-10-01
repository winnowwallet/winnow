import Foundation
import P256K
import WalletCore

struct ChannelSecrets: Codable {
    let funding: Data, revocation: Data, payment: Data, delayed: Data, htlc: Data, seed: Data
    init() throws {
        funding = try P256K.Signing.PrivateKey().dataRepresentation
        revocation = try P256K.Signing.PrivateKey().dataRepresentation
        payment = try P256K.Signing.PrivateKey().dataRepresentation
        delayed = try P256K.Signing.PrivateKey().dataRepresentation
        htlc = try P256K.Signing.PrivateKey().dataRepresentation
        seed = try P256K.Signing.PrivateKey().dataRepresentation
    }
    func point(_ number: UInt64) throws -> Data {
        try ChannelKeys.publicKey(secret: ChannelKeys.commitmentSecret(seed: seed, number: number))
    }
    func terms(capacity: UInt64, format: ChannelFormat = .staticRemoteKey) throws -> ChannelTerms {
        try ChannelTerms(maximumHTLCMsat: capacity * 1000, reserveSat: max(546, capacity / 100),
            funding: ChannelKeys.publicKey(secret: funding), revocation: ChannelKeys.publicKey(secret: revocation),
            payment: ChannelKeys.publicKey(secret: payment), delayed: ChannelKeys.publicKey(secret: delayed),
            htlc: ChannelKeys.publicKey(secret: htlc), firstPoint: point(0), format: format)
    }
}

struct ChannelState: Codable {
    let peer: Data, temporaryID: Data
    let capacity: UInt64, pushMsat: UInt64, feePerKW: UInt32, isFunder: Bool
    let secrets: ChannelSecrets
    let local: ChannelTerms
    var remote: ChannelTerms?
    var phase: LightningEngine.ChannelPhase
    var minimumDepth: UInt32 = 3
    var fundingTxid: Data?, fundingOutput: UInt16?, fundingTransaction: Data?
    // Fully witnessed, peer-verified latest LOCAL commitment. This is the
    // enforceable monitor record, stored in the same transaction as the outbox.
    var signedCommitment: Data?
    var remoteNextPoint: Data?
    var localReady = false, remoteReady = false
    var fundingIsConfirmed = false
    var localNumber: UInt64 = 0, remoteNumber: UInt64 = 0
    var remoteCurrentPoint: Data?
    var awaitingRevocation = false
    var remoteCommitmentSequence: UInt64?
    var revocations = RevocationSecrets()
    var nextLocalHTLC: UInt64 = 0, nextRemoteHTLC: UInt64 = 0
    var updates: [ChannelUpdate] = []
    var localHTLCSignatures: [Data] = []
    var previousRemoteCommitments: [Data] = []
    var learnedPreimages: [Data] = []
    var incomingBlinding: [UInt64: Data] = [:]
    var localShutdown: Data?, remoteShutdown: Data?
    var closingFee: UInt64?, closingFeeLimit: UInt64?
    var closingTransaction: Data?
    var observedFundingSpend: Data?
    var fundingSpendHeight: UInt32?
    var dataLossDetected = false
    var recovery: ChannelResolution.Policy?
    var resolutions: [ChannelResolution.Spend] = []
    var invoicePolicy: LightningEngine.InvoicePolicy?
    var feeBumps: [AnchorFeeBump]?

    var id: Data {
        guard let fundingTxid, let fundingOutput else { return temporaryID }
        // Persisted records are validated when opened; never use this fallback
        // to publish a message from an invalid record.
        return (try? ChannelNegotiation.channelID(txid: fundingTxid, output: fundingOutput)) ?? temporaryID
    }
    func commitment(localOwner: Bool) throws -> ChannelTransactions.Commitment {
        try commitment(localOwner: localOwner, number: localOwner ? localNumber : remoteNumber)
    }
    func commitment(localOwner: Bool, number: UInt64) throws -> ChannelTransactions.Commitment {
        guard let remote, let txid = fundingTxid, let output = fundingOutput else { throw LightningError.invalidState }
        let owner = localOwner ? local : remote, other = localOwner ? remote : local
        let point = try commitmentPoint(localOwner: localOwner, number: number)
        let view = try view(localOwner: localOwner, number: number)
        let keys = try ChannelTransactions.Keys(fundingLocal: owner.funding, fundingRemote: other.funding,
            revocation: ChannelKeys.revocationPublicKey(basepoint: other.revocation, commitmentPoint: point),
            delayedLocal: ChannelKeys.derivedPublicKey(basepoint: owner.delayed, commitmentPoint: point),
            paymentRemote: other.payment,
            htlcLocal: ChannelKeys.derivedPublicKey(basepoint: owner.htlc, commitmentPoint: point),
            htlcRemote: ChannelKeys.derivedPublicKey(basepoint: other.htlc, commitmentPoint: point))
        let ownerIsFunder = localOwner == isFunder
        return try ChannelTransactions.commitment(.init(funding: .init(txid: txid, vout: UInt32(output)),
            fundingSat: capacity, localMsat: localOwner ? view.localMsat : view.remoteMsat,
            remoteMsat: localOwner ? view.remoteMsat : view.localMsat, localIsFunder: ownerIsFunder,
            dustSat: owner.dustSat, feePerKW: view.feePerKW, delay: other.delay, number: number,
            openerPaymentBasepoint: isFunder ? local.payment : remote.payment,
            accepterPaymentBasepoint: isFunder ? remote.payment : local.payment, keys: keys, format: local.format,
            htlcs: view.htlcs.map { .init(id: $0.id, offered: localOwner ? $0.offered : !$0.offered,
                amountMsat: $0.amountMsat, paymentHash: $0.paymentHash, expiry: $0.expiry) }))
    }
    func commitmentPoint(localOwner: Bool, number: UInt64) throws -> Data {
        if localOwner { return try secrets.point(number) }
        if number == 0, let remote { return remote.firstPoint }
        if number < remoteNumber { return try ChannelKeys.publicKey(secret: revocations.secret(for: number)) }
        if number == remoteNumber, let remoteCurrentPoint { return remoteCurrentPoint }
        if number == remoteNumber + 1, let remoteNextPoint { return remoteNextPoint }
        throw LightningError.invalidCommitment
    }
    func validateNegotiation() throws {
        guard let remote else { throw LightningError.invalidState }
        try local.validate(capacity: capacity); try remote.validate(capacity: capacity)
        guard local.format == remote.format else { throw LightningError.invalidMessage }
        guard local.dustSat <= remote.reserveSat, remote.dustSat <= local.reserveSat else { throw LightningError.invalidAmount }
        let fee = UInt64(feePerKW) * local.format.commitmentWeight / 1000 + local.format.anchorReserveSat
        let funderReserve = isFunder ? remote.reserveSat : local.reserveSat
        guard (capacity * 1000 - pushMsat) / 1000 >= fee + funderReserve else { throw LightningError.invalidAmount }
    }
    mutating func acceptSignature(_ compact: Data) throws {
        let commitment = try commitment(localOwner: true)
        let ours = try ChannelKeys.sign(digest: ChannelTransactions.fundingDigest(commitment), secret: secrets.funding)
        let signed = try ChannelTransactions.signed(commitment, localSignature: ours, remoteSignature: ChannelKeys.derSignature(compact))
        signedCommitment = signed.serialized(includeWitness: true)
    }
    func remoteSignature() throws -> Data {
        let commitment = try commitment(localOwner: false)
        return try ChannelKeys.compactSignature(ChannelKeys.sign(digest: ChannelTransactions.fundingDigest(commitment), secret: secrets.funding))
    }
    func fundingScript() throws -> Data {
        guard let remote else { throw LightningError.invalidState }
        return try ChannelScripts.witnessScriptHash(ChannelScripts.funding(local.funding, remote.funding))
    }
    func checkFunding(_ transaction: Transaction, output: UInt16) throws {
        guard transaction.outputs.indices.contains(Int(output)), !transaction.inputs.isEmpty,
              transaction.inputs.allSatisfy({ !$0.witness.isEmpty }) else { throw LightningError.invalidCommitment }
        let funding = transaction.outputs[Int(output)]
        guard funding.value == Int64(capacity), try funding.scriptPubKey == fundingScript() else { throw LightningError.invalidCommitment }
    }
}
