import CryptoKit
import Foundation

enum SecMsGec {
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let windowsEpochOffset: UInt64 = 11_644_473_600
    private static let prefixLength = 57
    private static let prefixWords: [UInt32] = [
        0x79706f43, 0x68676972, 0x43282074, 0x694d2029, 0x736f7263,
        0x2074666f, 0x70726f43, 0x7461726f, 0x2e6e6f69, 0x6c6c4120,
        0x67697220, 0x20737468, 0x65736572, 0x64657672, 0x0000002e,
    ]
    private static let coefficients: [(UInt32, UInt32)] = [
        (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D),
        (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF),
        (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
        (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB),
        (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464),
        (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
        (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167),
    ]
    private static let factor: UInt32 = 0x82893933
    private static let adjustment0: UInt32 = 0xF2F90B1A
    private static let adjustment1: UInt32 = 0x0B1A0000

    private static func rol16(_ value: UInt32) -> UInt32 {
        (value << 16) | (value >> 16)
    }

    private static func words(from bytes: [UInt8]) -> [UInt32] {
        var padded = bytes
        while padded.count % 4 != 0 { padded.append(0) }
        var result: [UInt32] = []
        var index = 0
        while index + 4 <= padded.count {
            result.append(
                UInt32(padded[index])
                | (UInt32(padded[index + 1]) << 8)
                | (UInt32(padded[index + 2]) << 16)
                | (UInt32(padded[index + 3]) << 24)
            )
            index += 4
        }
        if result.count % 2 != 0 { result.append(0) }
        return result
    }

    private static func cs64(_ data: Data, digest: Data) -> (UInt32, UInt32) {
        let digestBytes = [UInt8](digest)
        var keyA = UInt32(digestBytes[0]) | (UInt32(digestBytes[1]) << 8)
            | (UInt32(digestBytes[2]) << 16) | (UInt32(digestBytes[3]) << 24)
        var keyB = UInt32(digestBytes[4]) | (UInt32(digestBytes[5]) << 8)
            | (UInt32(digestBytes[6]) << 16) | (UInt32(digestBytes[7]) << 24)
        keyA |= 1
        keyB |= 1
        let factors = (keyA &* factor, keyB &* factor)
        var terms: [UInt32] = []
        var offsets: [UInt32] = []
        for (index, coefficient) in coefficients.enumerated() {
            terms.append(coefficient.0 &* (index % 2 == 0 ? factors.0 : factors.1))
            offsets.append(coefficient.1)
        }
        let allWords = words(from: [0] + [UInt8](data))
        for (index, word) in allWords.enumerated() {
            var term = word &* (index % 2 == 0 ? keyA : keyB)
            var offset = rol16(word) &* (index % 2 == 0 ? 0xEF0569FB : 0xC31713DB)
            if index == 0 {
                term = term &+ adjustment0 &* factors.0
                offset = offset &+ adjustment1
            }
            terms.append(term)
            offsets.append(offset)
        }

        var swapAcc: UInt32 = 0
        var swapLast: UInt32 = 0
        var state: UInt32 = 0
        var acc: UInt32 = 0
        var index = 0
        while index + 1 < terms.count {
            let x = terms[index]
            let y = terms[index + 1]
            var t = rol16(offsets[index] &+ x)
            var q = t &* 0x76F50F34
            swapAcc = swapAcc &+ (rol16(q) &* 0xC3EFEA97 &+ q)
            t = rol16(offsets[index + 1] &+ y)
            q = t &* 0x1881CE3C
            swapLast = rol16(q) &* 0x35BD1EC9 &+ q
            swapAcc = swapAcc &+ swapLast

            state = state &* keyA &+ x
            state = rol16(state) &* 0xCF98B111
            state = rol16(state) &* 0x87085B9F
            state = rol16(state) &* 0x12CEB96D
            state = rol16(state) &* 0x257E1D83
            acc = acc &+ state
            t = state &* keyB &+ y
            t = rol16(t) &* 0xA27416F5
            t = rol16(t) &* 0xD38396FF
            state = rol16(rol16(t) &* 0x7C932B89) &* 0xBFA49F69
            acc = acc &+ state
            index += 2
        }
        return (swapLast ^ state, swapAcc ^ acc)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func token(now: Date = Date()) -> String {
        var ticks = UInt64(now.timeIntervalSince1970) + windowsEpochOffset
        ticks -= ticks % 300
        ticks *= 10_000_000
        let suffix = Data("\(ticks)\(trustedClientToken)".utf8)
        var data = Data(count: prefixLength + suffix.count)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            for (index, word) in prefixWords.enumerated() {
                base[index] = word.littleEndian
            }
        }
        data.replaceSubrange(prefixLength..<(prefixLength + suffix.count), with: suffix)
        let digest = Data(SHA256.hash(data: data))
        let (a, b) = cs64(suffix, digest: digest)
        let cs64Bytes = [
            UInt8(a & 0xff), UInt8((a >> 8) & 0xff),
            UInt8((a >> 16) & 0xff), UInt8((a >> 24) & 0xff),
            UInt8(b & 0xff), UInt8((b >> 8) & 0xff),
            UInt8((b >> 16) & 0xff), UInt8((b >> 24) & 0xff),
        ]
        return "\(hex(cs64Bytes))-\(hex([UInt8](digest)))"
    }
}
