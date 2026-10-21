import Foundation

extension Satochip {
    /// The device that decides what the card signs. It holds the card's 2FA
    /// key and the account registered at setup, and works from the PSBT
    /// alone: no wallet state, no network. It rebuilds each input as a coin
    /// from the PSBT's `witness_utxo` and the address index found by deriving
    /// the registered descriptor, which is safe offline because a BIP341
    /// sighash commits to every input's amount and script: a PSBT that lies
    /// about either yields a signature that fails. It then runs the same
    /// review as the phone, shows the result, and computes the approvals.
    public struct Checker: Sendable {
        public let account: MuSig2Account
        /// The card's participant key (its account public key).
        public let cardKey: Data
        private let twoFactorKey: Data
        /// How many addresses per chain are derived to find inputs and change.
        public let searchLimit: UInt32

        public enum CheckerError: Error, Equatable {
            /// The registered card key is not a participant of the descriptor.
            case cardNotInAccount
            /// An input's script is none of the first `searchLimit` addresses.
            case unknownInput(Int)
            /// An input carries no `witness_utxo`.
            case missingInputAmount(Int)
            /// A participant's nonce is missing, so there is nothing to approve yet.
            case incompleteRoundOne
        }

        public init(descriptor: String, network: BitcoinNetwork, cardKey: Data, twoFactorKey: Data,
                    searchLimit: UInt32 = 500) throws {
            let account = try MuSig2Account(descriptor, network: network)
            guard account.participant(forCardKey: cardKey) != nil else { throw CheckerError.cardNotInAccount }
            guard twoFactorKey.count == 20 else { throw SatochipError.invalidTwoFactorKey }
            self.account = account
            self.cardKey = cardKey
            self.twoFactorKey = twoFactorKey
            self.searchLimit = searchLimit
        }

        /// The card's key expression, rebuilt from the master and account
        /// extended keys the setup tool read off the card: the checker's own
        /// view of the card, to compare with the phone's descriptor.
        public static func cardKeyExpression(masterXpub: String, accountXpub: String, path: [UInt32],
                                             network: HDKey.Network) throws -> String {
            let master = try HDKey.deserialize(masterXpub)
            let account = try HDKey.deserialize(accountXpub)
            guard master.depth == 0, Int(account.depth) == path.count, account.childIndex == path.last else {
                throw SatochipError.malformedResponse("the extended keys do not match the path")
            }
            return ParticipantKey(masterFingerprint: master.fingerprint, path: path, accountKey: account.neutered)
                .keyExpression(network: network)
        }

        public struct Review: Equatable, Sendable {
            public struct Input: Equatable, Sendable {
                public let txid: String
                public let vout: UInt32
                public let amount: Int64
                public let chain: AddressChain
                public let index: UInt32
            }

            public struct Output: Equatable, Sendable {
                public let amount: Int64
                /// The address, or nil for a script without one.
                public let address: String?
                public let scriptPubKey: Data
                /// One of this account's own addresses (change, or a self-payment).
                public let isAccountOwned: Bool
            }

            public let txid: String
            public let inputs: [Input]
            public let outputs: [Output]
            public let fee: Int64
            /// Whether every participant has added a nonce, so approvals can be made.
            public let isReadyToApprove: Bool

            public var sentAway: Int64 { outputs.filter { !$0.isAccountOwned }.reduce(0) { $0 + $1.amount } }
        }

        /// The phone's review, from the PSBT and the descriptor alone.
        public func review(_ psbt: PSBT) throws -> Review {
            let (coins, owned) = try coins(in: psbt)
            let review = try account.reviewSpend(psbt, knownUTXOs: coins, ownedOutputCoordinates: owned, chainTip: 0)
            let network = account.network
            return Review(
                txid: try psbt.unsignedTransaction().txid.displayHex,
                inputs: coins.map { Review.Input(txid: $0.txid.displayHex, vout: $0.vout, amount: $0.amount,
                                                 chain: $0.chain, index: $0.index) },
                outputs: review.outputs.map { Review.Output(amount: $0.amount,
                                                            address: AddressDecoder.address(for: $0.scriptPubKey,
                                                                                            network: network),
                                                            scriptPubKey: $0.scriptPubKey,
                                                            isAccountOwned: $0.isAccountOwned) },
                fee: review.fee,
                isReadyToApprove: psbt.inputs.allSatisfy { $0.musig2PubNonces.count == account.participants.count })
        }

        /// Approvals for every input, after the same review. Show `review`
        /// to the person first; calling this is the approval.
        public func approve(_ psbt: PSBT) throws -> Approvals {
            let (coins, owned) = try coins(in: psbt)
            guard psbt.inputs.allSatisfy({ $0.musig2PubNonces.count == account.participants.count }) else {
                throw CheckerError.incompleteRoundOne
            }
            let requests = try account.cardSignatureRequests(psbt, participant: cardKey, knownUTXOs: coins,
                                                             ownedOutputCoordinates: owned, chainTip: 0)
            var byInput: [Int: Data] = [:]
            for request in requests {
                byInput[request.input] = try twoFactorApproval(signingContext: request.signingContext, key: twoFactorKey)
            }
            return Approvals(txid: try psbt.unsignedTransaction().txid.displayHex, byInput: byInput)
        }

        /// The PSBT's inputs as this account's coins, and the account
        /// coordinates its outputs pay.
        private func coins(in psbt: PSBT) throws -> ([WalletUTXO], [MuSig2Account.OutputCoordinate]) {
            guard psbt.inputs.count <= MuSig2Account.maximumCardInputs else {
                throw MuSig2AccountError.invalidSpend("a Satochip signs at most \(MuSig2Account.maximumCardInputs) inputs per spend")
            }
            var wanted = Set<Data>()
            for (index, input) in psbt.inputs.enumerated() {
                guard let spent = input.witnessUTXO else { throw CheckerError.missingInputAmount(index) }
                wanted.insert(spent.scriptPubKey)
            }
            let outputScripts = Set(psbt.outputs.compactMap(\.script))
            wanted.formUnion(outputScripts)
            let found = try coordinates(of: wanted)
            var coins: [WalletUTXO] = []
            for (index, input) in psbt.inputs.enumerated() {
                guard let spent = input.witnessUTXO, let coordinate = found[spent.scriptPubKey],
                      let txid = input.previousTxid, let vout = input.outputIndex,
                      let chain = AddressChain(rawValue: coordinate.choice)
                else { throw CheckerError.unknownInput(index) }
                coins.append(WalletUTXO(txid: txid, vout: vout, amount: spent.amount, scriptPubKey: spent.scriptPubKey,
                                        chain: chain, index: coordinate.index, height: 0))
            }
            let owned = outputScripts.compactMap { found[$0] }
            return (coins, owned)
        }

        /// The account coordinates of `scripts`, searched over the first
        /// `searchLimit` addresses of both chains; scripts not found are absent.
        private func coordinates(of scripts: Set<Data>) throws -> [Data: MuSig2Account.OutputCoordinate] {
            var found: [Data: MuSig2Account.OutputCoordinate] = [:]
            for index in 0 ..< searchLimit {
                for choice in 0 ... 1 {
                    let script = try account.scriptPubKey(index: index, choice: choice)
                    if scripts.contains(script), found[script] == nil {
                        found[script] = MuSig2Account.OutputCoordinate(choice: choice, index: index)
                    }
                }
                if found.count == scripts.count { break }
            }
            return found
        }
    }
}
