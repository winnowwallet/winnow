import Foundation

extension LightningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "The amount, fee limit, or expiry is outside the supported limits."
        case .invalidMessage: "The offer, provider setup, or peer message is invalid or unsupported."
        case .invalidState: "Lightning is not ready for this action. Verify the chain and reconnect the provider."
        case .invalidKey, .invalidHash: "The Lightning identity or payment identifier is invalid."
        case .invalidCommitment, .invalidSignature, .authenticationFailed: "Lightning verification failed. No unverified payment was accepted."
        case .closed: "The Lightning peer disconnected. Reconnect after the chain is verified."
        case .storageFailed: "The protected Lightning journal could not be verified or saved. Financial actions are stopped; keep this device and its files for recovery."
        }
    }
}
