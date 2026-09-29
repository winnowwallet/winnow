import Foundation

/// Where a candidate peer came from.
///
/// The pool races all candidates and keeps the fastest, which on a hostile
/// network is exactly the wrong rule: an attacker running nodes near the device
/// wins every latency race, and can end up holding every slot. Recording the
/// source lets the pool refuse to seat one origin in the whole pool (#3).
///
/// Ordered from most to least trusted, which is also the order candidates are
/// dialled in.
public enum PeerSource: String, Codable, Sendable, CaseIterable {
    /// Typed in by the user. Their explicit choice, dialled first.
    case manual
    /// Learned by connecting successfully on an earlier run.
    case persisted
    /// Downloaded census. The legacy raw value preserves saved-peer provenance;
    /// earlier versions used the same class for their census-derived bundle.
    case census = "fallback"
    /// Resolved from a DNS seed, over DoH where possible.
    case dnsSeed
}

/// A candidate endpoint together with where it was found.
public struct PeerCandidate: Equatable, Sendable {
    public var endpoint: PeerEndpoint
    public var source: PeerSource

    public init(endpoint: PeerEndpoint, source: PeerSource) {
        self.endpoint = endpoint
        self.source = source
    }
}

public extension PeerEndpoint {
    /// The address block this peer shares with its neighbours, or nil when the
    /// host is not a numeric address.
    ///
    /// Two peers in one block are close to one peer for the purpose peers
    /// serve: someone who can run a node at an address can usually run several
    /// more beside it, so the second adds far less independence than its slot
    /// suggests. Grouping IPv4 by /16 and IPv6 by /32 is the split Bitcoin
    /// Core's addrman uses for the same reason.
    ///
    /// nil means "do not restrict this peer", and there are two such cases.
    ///
    /// A **hostname** only reaches the pool by the user typing it, and refusing
    /// someone's explicitly chosen peer because its block cannot be computed
    /// would be the wrong trade.
    ///
    /// A **non-public address** — loopback, RFC1918, link-local — is not the
    /// thing this rule defends against. Concentration matters because renting
    /// several addresses beside one another is cheap for an attacker and
    /// buying independence is not; neither is true inside a home network, and
    /// an attacker already on your LAN is not held off by netblock spread. It
    /// also has a concrete cost: a signet or regtest pool is several nodes on
    /// 127.0.0.1, and a user may deliberately run two of their own machines on
    /// one subnet. Restricting those would break a working setup to no end.
    var netblock: String? {
        Self.netblock(forHost: host)
    }

    /// A Tor or I2P destination, reached through its gateway by name.
    var isOverlay: Bool { PeerNetwork(host: host) != .clearnet }

    /// Split out so it can be tested without constructing endpoints, and so the
    /// v4/v6 branch is visible in one place.
    ///
    /// Reuses `SeedAddressFilter`'s notion of public, which already enumerates
    /// the reserved ranges for the seed path — one definition, not two that can
    /// drift apart.
    static func netblock(forHost host: String) -> String? {
        if let octets = SeedAddressFilter.ipv4Octets(host) {
            guard SeedAddressFilter.isPublicIPv4(octets) else { return nil }
            return "v4:\(octets.0).\(octets.1)"
        }
        guard let bytes = SeedAddressFilter.ipv6Octets(host) else { return nil }
        if SeedAddressFilter.isIPv4Mapped(bytes) {
            let mapped = (bytes[12], bytes[13], bytes[14], bytes[15])
            guard SeedAddressFilter.isPublicIPv4(mapped) else { return nil }
            return "v4:\(mapped.0).\(mapped.1)"
        }
        guard SeedAddressFilter.isPublicIPv6(bytes) else { return nil }
        return String(format: "v6:%02x%02x:%02x%02x", bytes[0], bytes[1], bytes[2], bytes[3])
    }
}

/// The connected pool, viewed as the thing diversity rules are enforced against.
///
/// Every rule is a ceiling rather than a quota: it says what a pool may not
/// become, not what it must contain. A quota would mean refusing to connect at
/// all when a class is unreachable, which trades a real outage for a
/// hypothetical attacker.
struct DiversityPolicy {
    /// How many slots the pool is trying to fill.
    let peerCount: Int
    /// Whether clearnet peers are selected. Only then can the overlay rule ask
    /// for a netblock-limited peer; Tor-only and I2P-only routing are the
    /// user's choice and rely on the source rule alone.
    var clearnetSelected = true

    /// Whether a candidate may take a slot given what is already connected.
    ///
    /// - No two peers from one netblock. A candidate whose block cannot be
    ///   computed is always allowed; see `PeerEndpoint.netblock`.
    /// - No source class may hold every slot. With the shipped `peerCount` of
    ///   3 that permits 2 from one class and requires the third from another,
    ///   which is enough to stop a single compromised origin owning the pool
    ///   while still filling it when a class is dry.
    /// - While clearnet is selected, Tor and I2P peers together may not hold
    ///   every slot. Their names have no netblock, so the first rule never
    ///   limits them, and they can arrive under different source classes: two
    ///   remembered onions and one from the census would otherwise take the
    ///   whole pool at no cost to someone running many hidden services.
    ///
    /// **Manual peers are exempt from the source and overlay rules.** The risk this guards
    /// against is *automatic* selection converging on one operator; a peer the
    /// user typed in is not selection, it is instruction. Someone who
    /// configures three of their own nodes must get three, and an attacker who
    /// can edit that setting already has more than the pool to work with. The
    /// netblock rule still applies to them, since two addresses beside each
    /// other are no more independent for being chosen by hand.
    func admits(_ candidate: PeerCandidate, given seated: [PeerCandidate]) -> Bool {
        if let block = candidate.endpoint.netblock,
           seated.contains(where: { $0.endpoint.netblock == block }) {
            return false
        }
        guard candidate.source != .manual, peerCount > 1 else { return true }
        if clearnetSelected, candidate.endpoint.isOverlay,
           seated.filter(\.endpoint.isOverlay).count >= peerCount - 1 {
            return false
        }
        let sameSource = seated.filter { $0.source == candidate.source }.count
        return sameSource < peerCount - 1
    }
}

/// The persisted peers file.
///
/// Version 2 records the source class alongside the endpoint. It has to,
/// because a successful dial promotes the endpoint into the known-good set
/// regardless of where it came from — so without this, every peer collapses to
/// `persisted` after its first connection and the pool forgets it ever had a
/// diverse set of origins.
struct PersistedPeers: Codable, Sendable {
    struct Record: Codable, Sendable, Equatable {
        var host: String
        var port: UInt16
        var source: PeerSource

        var candidate: PeerCandidate {
            PeerCandidate(endpoint: PeerEndpoint(host: host, port: port), source: source)
        }
    }

    var version: Int
    var peers: [Record]

    static let currentVersion = 2

    init(_ candidates: [PeerCandidate]) {
        version = Self.currentVersion
        peers = candidates.map {
            Record(host: $0.endpoint.host, port: $0.endpoint.port, source: $0.source)
        }
    }

    /// Reads either format.
    ///
    /// A file written before this change is a bare array of endpoints with no
    /// class. Those are read as `persisted`, which is what they are: peers this
    /// device connected to on an earlier run. Nothing is discarded on upgrade.
    static func decode(_ data: Data) -> [PeerCandidate]? {
        if let versioned = try? JSONDecoder().decode(PersistedPeers.self, from: data),
           versioned.version == currentVersion {
            return versioned.peers.map(\.candidate)
        }
        guard let legacy = try? JSONDecoder().decode([PeerEndpoint].self, from: data) else {
            return nil
        }
        return legacy.map { PeerCandidate(endpoint: $0, source: .persisted) }
    }
}
