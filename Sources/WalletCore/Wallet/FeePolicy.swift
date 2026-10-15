import Foundation

/// Feerate resolution (docs/write-side.md §4; the read-side names the
/// blindness as weakness 4). Resolution order, strongest first:
///
/// 1. an explicit **user override** (sat/vB);
/// 2. the **median feerate observed** from the wallet's own recently confirmed
///    transactions (the only feerates a filter-only client can compute exactly,
///    since it knows all input amounts);
/// 3. conservative **static presets** per priority;
///
/// …with the result always clamped from below by the peers' BIP133 `feefilter`
/// floor, with an automatic peer-driven increase capped at 120 sat/vB.
/// A floor is a relay hint, not a guarantee of propagation or confirmation.
public enum FeePolicy {
    public static let maximumSatPerVByte: Double = 10_000
    /// Available to applications that choose a cap on automatic peer-driven
    /// increases. Applications must inspect `Resolution.clampedFloor` before signing.
    public static let maximumPeerFloorSatPerVByte: Double = 120

    public enum FloorAggregation: Sendable {
        case strictest
        case seatMajority
    }

    public struct Resolution: Equatable, Sendable {
        public let rate: Double
        /// A reported floor this rate falls below because of the selected cap.
        /// The caller must obtain a new decision or refuse before signing.
        public let clampedFloor: Double?
    }

    public enum Priority: String, CaseIterable, Sendable {
        case low, medium, high

        /// Conservative static presets (sat/vB), used when nothing is observed.
        /// Deliberately above typical minima — a mempool-blind wallet must
        /// overpay rather than stall.
        public var satPerVByte: Double {
            switch self {
            case .low: 2
            case .medium: 5
            case .high: 12
            }
        }
    }

    /// Resolves the feerate to use (sat/vB). See the type doc for the order.
    public static func resolve(priority: Priority = .medium, override: Double? = nil,
                               observed: [Double] = [], floorSatPerVByte: Double? = nil) -> Double {
        resolution(priority: priority, override: override, observed: observed,
                   floorSatPerVByte: floorSatPerVByte).rate
    }

    /// A validated estimate with an optional, explicitly selected peer-floor
    /// cap. Override wins; an external estimate cannot undercut our observed
    /// median. The cap limits only a peer's increase, not the user's override
    /// or the wallet's own observed rate. The default cap is 120 sat/vB; nil explicitly selects an uncapped floor.
    public static func resolution(priority: Priority = .medium, override: Double? = nil,
                                  estimated: Double? = nil, observed: [Double] = [],
                                  floorSatPerVByte: Double? = nil,
                                  peerFloorCap: Double? = FeePolicy.maximumPeerFloorSatPerVByte) -> Resolution {
        let observedRate = median(observed.compactMap { usable($0) })
        let estimate = usable(estimated).map { max($0, observedRate ?? 0) }
        let base = usable(override) ?? estimate ?? observedRate ?? priority.satPerVByte
        guard let floor = usable(floorSatPerVByte) else {
            return Resolution(rate: base, clampedFloor: nil)
        }
        let rate = max(base, min(floor, usable(peerFloorCap) ?? maximumSatPerVByte))
        return Resolution(rate: rate, clampedFloor: rate < floor ? floor : nil)
    }

    private static func usable(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0, rate <= maximumSatPerVByte else { return nil }
        return rate
    }

    /// Lower median across configured seats, with missing or unusable reports
    /// counting as zero. A floor needs more than half of the seats behind it;
    /// the first reporting peer cannot set the whole wallet's floor.
    public static func seatMajorityFloor(reported: [Double], seats: Int) -> Double? {
        let count = max(seats, reported.count)
        guard count > 0 else { return nil }
        let values = reported.map { usable($0) ?? 0 } + Array(repeating: 0, count: count - reported.count)
        let floor = values.sorted()[(count - 1) / 2]
        return floor > 0 ? floor : nil
    }

    /// Median of the observed samples (nil when empty).
    public static func median(_ samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension PeerPool {
    /// Explicit aggregation for an embedding application's policy. The
    /// no-argument overload selects the majority policy.
    public func feeFilterFloorSatPerVByte(aggregation: FeePolicy.FloorAggregation) async -> Double? {
        switch aggregation {
        case .strictest:
            var reports: [Double] = []
            for peer in connectedPeers() {
                if let floor = await peer.feeFilter { reports.append(Double(floor) / 1_000) }
            }
            return reports.max()
        case .seatMajority:
            var reports: [Double] = []
            for peer in connectedPeers() {
                if let floor = await peer.feeFilter { reports.append(Double(floor) / 1_000) }
            }
            return FeePolicy.seatMajorityFloor(reported: reports, seats: peerCount)
        }
    }

    /// The lower median across configured peer seats, counting missing
    /// reports as zero. An advertised floor is a peer's hint, not a market
    /// estimate or proof that a transaction will relay.
    public func feeFilterFloorSatPerVByte() async -> Double? {
        await feeFilterFloorSatPerVByte(aggregation: .seatMajority)
    }

}

/// Consensus monetary range used at wallet authorization boundaries.
public enum BitcoinAmount {
    /// 21 million BTC in satoshis (`MAX_MONEY` in Bitcoin Core).
    public static let maximum: Int64 = 2_100_000_000_000_000
}
