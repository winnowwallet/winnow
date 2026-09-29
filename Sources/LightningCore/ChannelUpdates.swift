import Foundation

struct ChannelUpdate: Codable {
    enum Change: Codable {
        case add(ChannelTransactions.HTLC, onion: Data)
        case fulfill(id: UInt64, offered: Bool, preimage: Data)
        case fail(id: UInt64, offered: Bool, reason: Data)
        case fee(UInt32)
    }
    let change: Change
    let fromLocal: Bool
    var localNumber: UInt64?
    var remoteNumber: UInt64?
    var remoteAcknowledged = false
    var irrevocable: Bool { localNumber != nil && remoteAcknowledged }
    func pending(localOwner: Bool) -> Bool {
        if localOwner { return localNumber == nil && (!fromLocal || remoteAcknowledged) }
        return remoteNumber == nil && (fromLocal || localNumber != nil)
    }
}

struct ChannelView {
    var localMsat: UInt64, remoteMsat: UInt64
    var feePerKW: UInt32
    var htlcs: [ChannelTransactions.HTLC] = []
    mutating func apply(_ change: ChannelUpdate.Change) throws {
        switch change {
        case .add(let htlc, _): try add(htlc)
        case .fulfill(let id, let offered, let preimage):
            let htlc = try remove(id: id, offered: offered)
            guard preimage.count == 32, ChannelKeys.hash(preimage) == htlc.paymentHash else { throw LightningError.invalidHash }
            if offered { remoteMsat += htlc.amountMsat } else { localMsat += htlc.amountMsat }
        case .fail(let id, let offered, _):
            let htlc = try remove(id: id, offered: offered)
            if offered { localMsat += htlc.amountMsat } else { remoteMsat += htlc.amountMsat }
        case .fee(let rate): feePerKW = rate
        }
    }
    private mutating func add(_ htlc: ChannelTransactions.HTLC) throws {
        guard !htlcs.contains(where: { $0.id == htlc.id && $0.offered == htlc.offered }) else { throw LightningError.invalidState }
        if htlc.offered {
            guard localMsat >= htlc.amountMsat else { throw LightningError.invalidAmount }
            localMsat -= htlc.amountMsat
        } else {
            guard remoteMsat >= htlc.amountMsat else { throw LightningError.invalidAmount }
            remoteMsat -= htlc.amountMsat
        }
        htlcs.append(htlc)
    }
    private mutating func remove(id: UInt64, offered: Bool) throws -> ChannelTransactions.HTLC {
        guard let index = htlcs.firstIndex(where: { $0.id == id && $0.offered == offered }) else { throw LightningError.invalidState }
        return htlcs.remove(at: index)
    }
}

extension ChannelState {
    func view(localOwner: Bool, number: UInt64) throws -> ChannelView {
        var view = ChannelView(localMsat: isFunder ? capacity * 1000 - pushMsat : pushMsat,
                               remoteMsat: isFunder ? pushMsat : capacity * 1000 - pushMsat, feePerKW: feePerKW)
        for update in updates {
            let included = localOwner ? update.localNumber : update.remoteNumber
            if let included, included <= number { try view.apply(update.change) }
        }
        return view
    }
    mutating func includeUpdates(localOwner: Bool, number: UInt64) throws {
        let pending = updates.indices.filter { updates[$0].pending(localOwner: localOwner) }
        guard !pending.isEmpty else { throw LightningError.invalidState }
        for index in pending {
            if localOwner { updates[index].localNumber = number } else { updates[index].remoteNumber = number }
        }
        try validateView(localOwner: localOwner, number: number)
    }
    func validateView(localOwner: Bool, number: UInt64) throws {
        guard let remote else { throw LightningError.invalidState }
        let view = try view(localOwner: localOwner, number: number)
        let commitment = try commitment(localOwner: localOwner, number: number)
        let funderMsat = isFunder ? view.localMsat : view.remoteMsat
        let reserve = isFunder ? remote.reserveSat : local.reserveSat
        guard funderMsat / 1000 >= reserve + commitment.actualFeeSat else { throw LightningError.invalidAmount }
        if number > 0 {
            let previous = try self.view(localOwner: localOwner, number: number - 1)
            guard view.localMsat >= previous.localMsat || view.localMsat >= remote.reserveSat * 1000,
                  view.remoteMsat >= previous.remoteMsat || view.remoteMsat >= local.reserveSat * 1000
            else { throw LightningError.invalidAmount }
        }
        try validateHTLCLimit(view.htlcs.filter(\.offered), terms: remote)
        try validateHTLCLimit(view.htlcs.filter { !$0.offered }, terms: local)
    }
    private func validateHTLCLimit(_ htlcs: [ChannelTransactions.HTLC], terms: ChannelTerms) throws {
        guard htlcs.count <= Int(terms.maximumHTLCCount), htlcs.allSatisfy({ $0.amountMsat >= terms.minimumHTLCMsat }),
              htlcs.reduce(UInt64(0), { $0 + $1.amountMsat }) <= terms.maximumHTLCMsat else { throw LightningError.invalidAmount }
    }
    func activeHTLC(id: UInt64, offered: Bool) throws -> ChannelTransactions.HTLC {
        let local = try view(localOwner: true, number: localNumber), remote = try view(localOwner: false, number: remoteNumber)
        guard let htlc = local.htlcs.first(where: { $0.id == id && $0.offered == offered }),
              remote.htlcs.contains(htlc) else { throw LightningError.invalidState }
        return htlc
    }
}
