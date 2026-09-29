import Foundation

extension LightningRoutingGraph {
    private struct Candidate {
        let node: Data, amount: UInt64, delta: UInt32, hops: [Bolt11Invoice.Route]
        func dominates(_ other: Candidate) -> Bool { amount <= other.amount && delta <= other.delta && hops.count <= other.hops.count }
    }
    private struct Queue {
        var values: [Candidate] = []
        mutating func push(_ value: Candidate) throws {
            guard values.count < 100_000 else { throw LightningInvoiceError.noRoute }
            values.append(value); var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard less(values[index], values[parent]) else { break }; values.swapAt(index, parent); index = parent
            }
        }
        mutating func pop() -> Candidate? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let result = values[0]; values[0] = values.removeLast(); var index = 0
            while index * 2 + 1 < values.count {
                let left = index * 2 + 1, right = left + 1
                let best = right < values.count && less(values[right], values[left]) ? right : left
                guard less(values[best], values[index]) else { break }; values.swapAt(index, best); index = best
            }
            return result
        }
        private func less(_ a: Candidate, _ b: Candidate) -> Bool { a.amount != b.amount ? a.amount < b.amount : a.delta < b.delta }
    }
    func route(from peer: Data, invoice: Bolt11Invoice.Decoded, amountMsat: UInt64,
               feeLimitMsat: UInt64, maximumDelta: UInt32) throws -> Bolt11PaymentRoute {
        let hops = try search(from: peer, target: invoice.payee, hints: invoice.routes) { hops in
            let route = try Bolt11PaymentRoute(hops: hops)
            let quote = try route.quote(invoice: invoice, amountMsat: amountMsat, feeLimitMsat: feeLimitMsat, height: 0, maximumDelta: maximumDelta)
            return (quote.amountMsat, quote.delta)
        }
        return try Bolt11PaymentRoute(hops: hops)
    }
    func search(from peer: Data, target: Data, hints: [[Bolt11Invoice.Route]] = [], enforcePaymentBounds: Bool = true,
                quote: ([Bolt11Invoice.Route]) throws -> (UInt64, UInt32)) throws -> [Bolt11Invoice.Route] {
        let incoming = incomingPolicies()
        var queue = Queue(), seen: [Data: [Candidate]] = [:]
        func candidate(node: Data, hops: [Bolt11Invoice.Route]) throws -> Candidate {
            let (amount, delta) = try quote(hops)
            return Candidate(node: node, amount: amount, delta: delta, hops: hops)
        }
        try queue.push(candidate(node: target, hops: []))
        for seed in hintedCandidates(hints: hints, quote: quote) { try queue.push(seed) }
        var explored = 0
        while let current = queue.pop(), explored < 500_000 {
            explored += 1
            if current.node == peer { return current.hops }
            guard current.hops.count < 19, !(seen[current.node] ?? []).contains(where: { $0.dominates(current) }) else { continue }
            var labels = seen[current.node] ?? []; labels.removeAll { current.dominates($0) }
            guard labels.count < 8 else { continue }; labels.append(current); seen[current.node] = labels
            for (source, policy) in incoming[current.node] ?? [] {
                guard !enforcePaymentBounds || (policy.minimum...policy.maximum).contains(current.amount), !current.hops.contains(where: { $0.peer == source }), source != target,
                      let next = try? candidate(node: source, hops: [policy.hop] + current.hops) else { continue }
                try queue.push(next)
            }
        }
        throw LightningInvoiceError.noRoute
    }
    private func incomingPolicies() -> [Data: [(Data, Policy)]] {
        var incoming: [Data: [(Data, Policy)]] = [:]
        for channel in channels.values {
            for (direction, policy) in channel.policies where !policy.disabled {
                let source = channel.nodes[direction], target = channel.nodes[direction ^ 1]
                if !blockedNodes.contains(source) { incoming[target, default: []].append((source, policy)) }
            }
        }
        return incoming
    }
    private func hintedCandidates(hints: [[Bolt11Invoice.Route]],
                                  quote: ([Bolt11Invoice.Route]) throws -> (UInt64, UInt32)) -> [Candidate] {
        hints.compactMap { hint in
            guard !hint.contains(where: { blockedNodes.contains($0.peer) }), let first = hint.first,
                  let (amount, delta) = try? quote(hint) else { return nil }
            return Candidate(node: first.peer, amount: amount, delta: delta, hops: hint)
        }
    }
}
