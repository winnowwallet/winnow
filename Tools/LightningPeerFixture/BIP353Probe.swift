import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    static func probeBIP353(_ args: [String]) async throws {
        guard args.count == 2 else { throw DNSSECError.malformed }
        let now = UInt64(Date().timeIntervalSince1970), name = try BIP353Name(args[1])
        let instructions = try await BIP353Resolver().resolve(name, chain: NetworkParams.mainnet.genesisHash, now: now)
        try emit(["name": instructions.name.display, "uri": instructions.uri, "offer": instructions.offer.string,
                  "valid_until": String(instructions.validUntil), "validated_at": String(now),
                  "validation": "Local DNSSEC signatures and delegation chain to pinned IANA root DSs"])
    }
}
