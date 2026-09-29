import Foundation
import LightningCore
import WalletCore

/// The intended payment amount survives provider setup and relaunch. It is
/// separate from channel capacity, which can have a larger provider minimum.
struct LightningReceiveIntent: Codable, Equatable {
    let network: String
    let amountSat: UInt64

    init(amountSat: UInt64, network: BitcoinNetwork) throws {
        guard amountSat > 0, amountSat < 16_777_216 else { throw LightningError.invalidAmount }
        self.amountSat = amountSat
        self.network = network.rawValue
    }

    func validate(network: BitcoinNetwork) throws {
        guard self.network == network.rawValue else { throw LightningError.invalidHash }
        _ = try Self(amountSat: amountSat, network: network)
    }

    func capacity(using info: LightningLiquidity.Info) throws -> UInt64 {
        let capacity = max(amountSat, info.minimumCapacitySat)
        _ = try info.request(capacitySat: capacity)
        return capacity
    }
}
