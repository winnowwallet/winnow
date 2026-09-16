import WalletCore
import Foundation

/// Thread-safe sink for FilterSync matches, handed in as its `@Sendable`
/// match callback.
public final class MatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BlockMatch] = []

    public init() {}

    public var matches: [BlockMatch] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func add(_ match: BlockMatch) {
        lock.lock()
        stored.append(match)
        lock.unlock()
    }
}

/// Collects the events of an `AsyncStream` from its consumer task — the
/// broadcaster's, the mempool window's, whichever the test subscribes to.
public final class EventCollector<Event>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Event] = []

    public init() {}

    public var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func add(_ event: Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

/// Polls `condition` every 10ms until it holds or `timeout` elapses, and
/// says which: the test asserts on the answer.
///
/// The timeout is a HANG-GUARD, not a performance claim. Nothing here asserts
/// that the condition is met within it — on a contended CI runner a short
/// deadline turns into an assertion nobody wrote, which is how these became
/// intermittent (#144). Keep it generous: a real hang fails either way.
public func pollUntil(_ timeout: Duration = .seconds(60),
                      _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Polls the pool until `predicate` holds for its seated endpoints, or ten
/// seconds pass, and returns the endpoints it last saw. Eviction refills
/// asynchronously, so `start()` alone does not settle a pool.
public func settle(_ pool: PeerPool,
                   until predicate: @escaping ([PeerEndpoint]) -> Bool) async -> [PeerEndpoint] {
    var seen: [PeerEndpoint] = []
    for _ in 0 ..< 100 {
        seen = []
        for peer in await pool.connectedPeers() { seen.append(await peer.endpoint) }
        if predicate(seen) { return seen }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return seen
}

/// Polls the pool until it has seated `count` peers and returns the count it
/// last saw: the call site keeps its own assertion and its own message.
///
/// `PeerPool.start()` awaits `replenish()`, so the seats are normally filled
/// by the time it returns. Normally — a dial or a handshake that lands late on
/// a contended runner leaves the count short, and a bare assertion straight
/// after `start()` reads a slow runner as a broken fixture (#152). Waiting for
/// the handshake the test actually needs asserts nothing about how long it took.
///
/// The timeout is a HANG-GUARD, not a performance claim, for the reason
/// `pollUntil` gives above. It matches the longest `dialTimeout` these fixtures
/// pass, so the guard never expires before the dial it is waiting on could have
/// finished, and it does not outlast the pool's 30-second replacement tick, so a
/// peer that was genuinely dropped is not papered over by a later replenish.
public func seatedPeerCount(_ pool: PeerPool, reaching count: Int,
                            within timeout: Duration = .seconds(30)) async -> Int {
    var seen = 0
    _ = await pollUntil(timeout) {
        seen = await pool.connectedPeers().count
        return seen == count
    }
    return seen
}
