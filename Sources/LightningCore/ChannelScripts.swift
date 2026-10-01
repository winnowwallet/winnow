import Foundation
import WalletCore

/// BOLT 3 scripts. Script serialization and hashing reuse WalletCore.
public enum ChannelScripts {
    public static func funding(_ first: Data, _ second: Data) throws -> Script {
        try validate([first, second])
        guard first != second else { throw LightningError.invalidKey }
        let keys = [first, second].sorted { $0.lexicographicallyPrecedes($1) }
        return Script.build {
            $0.appendScriptNumber(2); $0.appendPush(keys[0]); $0.appendPush(keys[1])
            $0.appendScriptNumber(2); $0.appendOpcode(0xae)
        }
    }

    public static func delayed(revocation: Data, delayed: Data, delay: UInt16) throws -> Script {
        try validate([revocation, delayed])
        return Script.build {
            $0.appendOpcode(0x63); $0.appendPush(revocation); $0.appendOpcode(0x67)
            $0.appendScriptNumber(Int(delay)); $0.appendOpcode(0xb2); $0.appendOpcode(0x75)
            $0.appendPush(delayed); $0.appendOpcode(0x68); $0.appendOpcode(0xac)
        }
    }

    public static func htlc(offered: Bool, revocation: Data, local: Data, remote: Data,
                             paymentHash: Data, expiry: UInt32, format: ChannelFormat = .staticRemoteKey) throws -> Script {
        try validate([revocation, local, remote])
        guard paymentHash.count == 32 else { throw LightningError.invalidHash }
        return Script.build { script in
            script.appendOpcode(0x76); script.appendOpcode(0xa9)
            script.appendPush(RIPEMD160.hash(ChannelKeys.hash(revocation)))
            script.appendOpcode(0x87); script.appendOpcode(0x63); script.appendOpcode(0xac)
            script.appendOpcode(0x67); script.appendPush(remote); script.appendOpcode(0x7c)
            script.appendOpcode(0x82); script.appendScriptNumber(32); script.appendOpcode(0x87)
            script.appendOpcode(offered ? 0x64 : 0x63)
            if offered {
                script.appendOpcode(0x75); multisig(&script, local: local)
                script.appendOpcode(0x67); payment(&script, hash: paymentHash); script.appendOpcode(0xac)
            } else {
                payment(&script, hash: paymentHash); multisig(&script, local: local)
                script.appendOpcode(0x67); script.appendOpcode(0x75)
                script.appendScriptNumber(Int(expiry)); script.appendOpcode(0xb1)
                script.appendOpcode(0x75); script.appendOpcode(0xac)
            }
            script.appendOpcode(0x68)
            if format.hasAnchors { script.appendScriptNumber(1); script.appendOpcode(0xb2); script.appendOpcode(0x75) }
            script.appendOpcode(0x68)
        }
    }

    public static func anchor(fundingKey: Data) throws -> Script {
        try validate([fundingKey])
        return Script.build {
            $0.appendPush(fundingKey); $0.appendOpcode(0xac); $0.appendOpcode(0x73)
            $0.appendOpcode(0x64); $0.appendScriptNumber(16); $0.appendOpcode(0xb2); $0.appendOpcode(0x68)
        }
    }
    public static func remote(paymentKey: Data) throws -> Script {
        try validate([paymentKey])
        return Script.build {
            $0.appendPush(paymentKey); $0.appendOpcode(0xad)
            $0.appendScriptNumber(1); $0.appendOpcode(0xb2)
        }
    }
    public static func remoteOutput(paymentKey: Data, format: ChannelFormat) throws -> Data {
        if format.hasAnchors { return try witnessScriptHash(remote(paymentKey: paymentKey)) }
        return try witnessKeyHash(paymentKey)
    }

    public static func witnessScriptHash(_ script: Script) -> Data {
        Data([0, 32]) + ChannelKeys.hash(script.bytes)
    }
    public static func witnessKeyHash(_ key: Data) throws -> Data {
        try validate([key])
        return Data([0, 20]) + RIPEMD160.hash(ChannelKeys.hash(key))
    }
    private static func validate(_ keys: [Data]) throws {
        for key in keys { _ = try ChannelKeys.point(key) }
    }
    private static func multisig(_ script: inout Script, local: Data) {
        script.appendScriptNumber(2); script.appendOpcode(0x7c); script.appendPush(local)
        script.appendScriptNumber(2); script.appendOpcode(0xae)
    }
    private static func payment(_ script: inout Script, hash: Data) {
        script.appendOpcode(0xa9); script.appendPush(RIPEMD160.hash(hash)); script.appendOpcode(0x88)
    }
}
