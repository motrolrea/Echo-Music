import Foundation
import CommonCrypto

/// 汽水音乐加密音源解密：`spade_a` / `play_auth` 密钥还原 + MP4/CENC 样本解密。
///
/// 与 libresoda `src/soda/crypto.rs` 的算法一致：spade 还原 16 字节 AES 密钥，
/// 再按 `senc` 样本逐段做 AES-128-CTR（大端 128 位计数器）解密，最后把
/// `stsd` 里的 `enca` 还原为 `frma` 指向的原始编码。
///
/// 汽水对 VIP / 无损档位一律返回加密媒体；解密后交给播放器的是普通 m4a，
/// 因此无需任何服务端参与。
enum QishuiCrypto {
    enum CryptoError: LocalizedError {
        case base64
        case tooShort
        case invalidPadding
        case indexOutOfBounds
        case invalidKeyLength
        case boxNotFound(String)
        case sizeMismatch

        var errorDescription: String? {
            switch self {
            case .base64: return "汽水密钥无法解码"
            case .tooShort: return "汽水密钥数据过短"
            case .invalidPadding: return "汽水密钥填充无效"
            case .indexOutOfBounds: return "汽水密钥索引越界"
            case .invalidKeyLength: return "汽水密钥长度无效"
            case .boxNotFound(let name): return "音频缺少 \(name) 结构"
            case .sizeMismatch: return "音频解密后长度不一致"
            }
        }
    }

    // MARK: - spade 密钥还原

    /// 从 `play_auth` / `spade_a` 还原十六进制 AES 密钥。
    static func extractKey(fromPlayAuth auth: String) throws -> String {
        guard let bytes = Data(base64Encoded: auth.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CryptoError.base64
        }
        let raw = [UInt8](bytes)
        guard raw.count >= 3 else { throw CryptoError.tooShort }

        let paddingLen = Int((raw[0] ^ raw[1] ^ raw[2]) & 0xFF) - 48
        guard paddingLen >= 0, raw.count >= paddingLen + 2 else { throw CryptoError.invalidPadding }

        let inner = Array(raw[1..<(raw.count - paddingLen)])
        let tmpBuff = decryptSpadeInner(inner)
        guard !tmpBuff.isEmpty else { throw CryptoError.indexOutOfBounds }

        let skipBytes = Int(decodeBase36(tmpBuff[0]))
        let endIndex = 1 + (raw.count - paddingLen - 2) - skipBytes
        guard endIndex <= tmpBuff.count, endIndex >= 1 else { throw CryptoError.indexOutOfBounds }
        return String(decoding: tmpBuff[1..<endIndex], as: UTF8.self)
    }

    private static func decryptSpadeInner(_ keyBytes: [UInt8]) -> [UInt8] {
        var buff = [UInt8]()
        buff.reserveCapacity(keyBytes.count + 2)
        buff.append(0xFA)
        buff.append(0x55)
        buff.append(contentsOf: keyBytes)

        var result = [UInt8]()
        result.reserveCapacity(keyBytes.count)
        for index in 0..<keyBytes.count {
            var value = Int((keyBytes[index] ^ buff[index]) & 0xFF) - bitCount(index) - 21
            while value < 0 { value += 255 }
            result.append(UInt8(value & 0xFF))
        }
        return result
    }

    private static func bitCount(_ value: Int) -> Int {
        var v = value
        var count = 0
        while v != 0 {
            count += v & 1
            v >>= 1
        }
        return count
    }

    private static func decodeBase36(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x7A: return byte - 0x61 + 10
        default: return 0xFF
        }
    }

    // MARK: - 整文件解密

    static func decryptAudio(_ data: Data, playAuth: String) throws -> Data {
        let hexKey = try extractKey(fromPlayAuth: playAuth)
        guard let keyBytes = hexDecode(hexKey), keyBytes.count == 16 else {
            throw CryptoError.invalidKeyLength
        }
        return try decryptAudio(withKey: keyBytes, data: data)
    }

    static func decryptAudio(withKey keyBytes: [UInt8], data: Data) throws -> Data {
        guard keyBytes.count == 16 else { throw CryptoError.invalidKeyLength }
        let bytes = [UInt8](data)
        guard let moov = findBoxDeep(bytes, type: "moov", start: 0, end: bytes.count) else {
            throw CryptoError.boxNotFound("moov")
        }
        guard let stbl = findBoxDeep(bytes, type: "stbl", start: moov.range.lowerBound, end: moov.range.upperBound) else {
            throw CryptoError.boxNotFound("stbl")
        }
        guard let stsz = findBox(bytes, type: "stsz", start: stbl.range.lowerBound + 8, end: stbl.range.upperBound) else {
            throw CryptoError.boxNotFound("stsz")
        }
        let sampleSizes = parseStsz(bytes, contentStart: stsz.range.lowerBound + 8, contentEnd: stsz.range.upperBound)

        let senc = findBoxDeep(bytes, type: "senc", start: stbl.range.lowerBound, end: stbl.range.upperBound)
            ?? findBox(bytes, type: "senc", start: moov.range.lowerBound + 8, end: moov.range.upperBound)
        guard let senc else { throw CryptoError.boxNotFound("senc") }
        let ivSize = defaultPerSampleIVSize(bytes, start: stbl.range.lowerBound, end: stbl.range.upperBound)
        let sencSamples = parseSenc(bytes, contentStart: senc.range.lowerBound + 8,
                                    contentEnd: senc.range.upperBound, ivSize: ivSize)

        guard let mdat = findBox(bytes, type: "mdat", start: 0, end: bytes.count) else {
            throw CryptoError.boxNotFound("mdat")
        }

        var decrypted = bytes
        var decryptedMDAT = [UInt8]()
        decryptedMDAT.reserveCapacity(max(0, mdat.range.upperBound - mdat.range.lowerBound - 8))
        var readPtr = mdat.range.lowerBound + 8
        for (index, size) in sampleSizes.enumerated() {
            let sampleSize = Int(size)
            if readPtr + sampleSize > decrypted.count { break }
            let chunk = Array(decrypted[readPtr..<(readPtr + sampleSize)])
            if index < sencSamples.count {
                decryptedMDAT.append(contentsOf: decryptSencSample(keyBytes, chunk: chunk, sample: sencSamples[index]))
            } else {
                decryptedMDAT.append(contentsOf: chunk)
            }
            readPtr += sampleSize
        }

        let payloadLength = mdat.range.upperBound - mdat.range.lowerBound - 8
        guard decryptedMDAT.count == payloadLength else { throw CryptoError.sizeMismatch }
        let start = mdat.range.lowerBound + 8
        decrypted.replaceSubrange(start..<(start + decryptedMDAT.count), with: decryptedMDAT)

        // stsd 里的 enca 还原成 frma 指向的原始编码
        if let stsd = findBoxDeep(bytes, type: "stsd", start: stbl.range.lowerBound, end: stbl.range.upperBound) {
            let slice = Array(decrypted[stsd.range.lowerBound..<stsd.range.upperBound])
            if let index = findSubslice(slice, needle: Array("enca".utf8)) {
                let original = encryptedSampleOriginalFormat(slice)
                let target = stsd.range.lowerBound + index
                if target + 4 <= decrypted.count {
                    decrypted.replaceSubrange(target..<(target + 4), with: original)
                }
            }
        }
        return Data(decrypted)
    }

    // MARK: - AES-128-CTR（大端 128 位计数器）

    private static func incrementCounter(_ counter: inout [UInt8]) {
        var carry = true
        var pos = 15
        while carry && pos >= 0 {
            let (sum, overflow) = counter[pos].addingReportingOverflow(1)
            counter[pos] = sum
            carry = overflow
            pos -= 1
        }
    }

    static func applyAES128CTR(_ data: inout [UInt8], key: [UInt8], iv: [UInt8]) {
        var counter = [UInt8](repeating: 0, count: 16)
        let copyLen = min(iv.count, 16)
        counter[0..<copyLen] = iv[0..<copyLen]
        guard !data.isEmpty else { return }

        // CTR 的加解密都是同一段密钥流异或。逐 16 字节调用一次 AES 在无损整轨上
        // 会到百万次，这里用一次 CCCryptor（ECB、无填充）批量算出计数器块的
        // 密钥流，再整段异或；计数器保持大端 128 位自增。
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreate(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count, nil, &cryptor
        )
        defer { if let cryptor { CCCryptorRelease(cryptor) } }
        guard created == kCCSuccess, cryptor != nil else {
            applyAES128CTRFallback(&data, key: key, counter: counter)
            return
        }

        let blockSize = kCCBlockSizeAES128
        let blocksPerBatch = 512
        let batchBytes = blocksPerBatch * blockSize
        var keystream = [UInt8](repeating: 0, count: batchBytes)
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let blocks = min(blocksPerBatch, (remaining + blockSize - 1) / blockSize)
            let counterBytes = blocks * blockSize

            var input = [UInt8]()
            input.reserveCapacity(counterBytes)
            for _ in 0..<blocks {
                input.append(contentsOf: counter)
                incrementCounter(&counter)
            }

            var produced = 0
            let status = CCCryptorUpdate(cryptor, input, counterBytes, &keystream, batchBytes, &produced)
            guard status == kCCSuccess, produced == counterBytes else {
                applyAES128CTRFallback(&data, key: key, counter: counter)
                return
            }
            let bytes = min(counterBytes, remaining)
            for i in 0..<bytes {
                data[offset + i] ^= keystream[i]
            }
            offset += bytes
        }
    }

    /// CommonCrypto 不可用时的等价实现（逐块 AES-ECB 生成密钥流）。
    private static func applyAES128CTRFallback(_ data: inout [UInt8], key: [UInt8], counter: [UInt8]) {
        var counter = counter
        var position = 0
        while position < data.count {
            let keystream = aesECBEncryptBlock(counter, key: key)
            incrementCounter(&counter)
            let blockLen = min(16, data.count - position)
            for i in 0..<blockLen {
                data[position + i] ^= keystream[i]
            }
            position += blockLen
        }
    }

    private static func aesECBEncryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var outLen = 0
        _ = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            key, key.count,
            nil,
            block, 16,
            &out, 16,
            &outLen
        )
        return out
    }

    // MARK: - MP4 box 解析

    private struct Box {
        let offset: Int
        let size: Int
        var range: Range<Int> { offset..<(offset + size) }
    }

    private static func findBox(_ data: [UInt8], type name: String, start: Int, end: Int) -> Box? {
        let end = min(end, data.count)
        var pos = start
        while pos + 8 <= end {
            let size = Int(readU32(data, pos))
            if size < 8 { break }
            let nameBytes = String(bytes: data[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? ""
            if nameBytes == name {
                let boxEnd = min(pos + size, data.count)
                return Box(offset: pos, size: boxEnd - pos)
            }
            pos += size
        }
        return nil
    }

    private static func findBoxDeep(_ data: [UInt8], type name: String, start: Int, end: Int) -> Box? {
        let end = min(end, data.count)
        var pos = start
        while pos + 8 <= end {
            var size = Int(readU32(data, pos))
            var headerSize = 8
            if size == 1 {
                guard pos + 16 <= end else { break }
                let size64 = readU64(data, pos + 8)
                guard size64 <= UInt64(end - pos) else { break }
                size = Int(size64)
                headerSize = 16
            }
            guard size >= headerSize, pos + size <= end else { break }
            let nameBytes = String(bytes: data[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? ""
            if nameBytes == name {
                return Box(offset: pos, size: size)
            }
            if let childStart = boxChildStart(nameBytes, offset: pos, headerSize: headerSize),
               childStart < pos + size,
               let found = findBoxDeep(data, type: name, start: childStart, end: pos + size) {
                return found
            }
            pos += size
        }
        return nil
    }

    private static func boxChildStart(_ boxName: String, offset: Int, headerSize: Int) -> Int? {
        switch boxName {
        case "moov", "trak", "mdia", "minf", "stbl", "sinf", "schi":
            return offset + headerSize
        case "stsd":
            return offset + headerSize + 8
        case "enca", "mp4a", "alac", "fLaC":
            return offset + headerSize + 28
        default:
            return nil
        }
    }

    private static func defaultPerSampleIVSize(_ data: [UInt8], start: Int, end: Int) -> Int {
        if let tenc = findBoxDeep(data, type: "tenc", start: start, end: end) {
            let contentStart = tenc.range.lowerBound + 8
            if contentStart + 8 <= data.count {
                let ivSize = Int(data[contentStart + 7])
                if ivSize == 8 || ivSize == 16 { return ivSize }
            }
        }
        return 8
    }

    private struct SencSubsample {
        let clear: UInt16
        let encrypted: UInt32
    }

    private struct SencSample {
        let iv: [UInt8]
        let subsamples: [SencSubsample]
    }

    private static func parseStsz(_ data: [UInt8], contentStart: Int, contentEnd: Int) -> [UInt32] {
        let base = contentStart
        guard contentEnd - base >= 12 else { return [] }
        let fixedSize = Int(readU32(data, base + 4))
        let declared = Int(readU32(data, base + 8))

        let sampleCount: Int
        if fixedSize != 0 {
            sampleCount = min(declared, 4 * 1024 * 1024)
        } else {
            let available = (contentEnd - base - 12) / 4
            sampleCount = min(declared, available, 4 * 1024 * 1024)
        }
        var sizes = [UInt32](repeating: 0, count: sampleCount)
        if fixedSize != 0 {
            for i in 0..<sampleCount { sizes[i] = UInt32(fixedSize) }
        } else {
            for i in 0..<sampleCount {
                let p = base + 12 + i * 4
                if p + 4 <= contentEnd { sizes[i] = readU32(data, p) }
            }
        }
        return sizes
    }

    private static func parseSenc(_ data: [UInt8], contentStart: Int, contentEnd: Int, ivSize rawIVSize: Int) -> [SencSample] {
        let ivSize = (rawIVSize == 8 || rawIVSize == 16) ? rawIVSize : 8
        let base = contentStart
        let end = contentEnd
        guard end - base >= 8 else { return [] }
        let flags = readU32(data, base) & 0x00FF_FFFF
        let hasSubsamples = (flags & 0x02) != 0
        let declared = Int(readU32(data, base + 4))

        let perSample = hasSubsamples ? ivSize + 2 : ivSize
        let maxByData = (end - base - 8) / max(perSample, 1)
        let sampleCount = min(declared, maxByData, 4 * 1024 * 1024)

        var samples = [SencSample]()
        samples.reserveCapacity(sampleCount)
        var ptr = base + 8
        for _ in 0..<sampleCount {
            guard ptr + ivSize <= end else { break }
            let iv = Array(data[ptr..<(ptr + ivSize)])
            ptr += ivSize
            var subsamples = [SencSubsample]()
            if hasSubsamples {
                guard ptr + 2 <= end else { break }
                let subCount = Int(readU16(data, ptr))
                ptr += 2
                guard ptr + subCount * 6 <= end else { break }
                for _ in 0..<subCount {
                    subsamples.append(SencSubsample(
                        clear: readU16(data, ptr),
                        encrypted: readU32(data, ptr + 2)
                    ))
                    ptr += 6
                }
            }
            samples.append(SencSample(iv: iv, subsamples: subsamples))
        }
        return samples
    }

    private static func decryptSencSample(_ key: [UInt8], chunk: [UInt8], sample: SencSample) -> [UInt8] {
        var dst = chunk
        if sample.subsamples.isEmpty {
            applyAES128CTR(&dst, key: key, iv: sample.iv)
            return dst
        }

        var counter = [UInt8](repeating: 0, count: 16)
        let copyLen = min(sample.iv.count, 16)
        counter[0..<copyLen] = sample.iv[0..<copyLen]

        var keystream = [UInt8](repeating: 0, count: 16)
        var ksPos = 16
        var pos = 0
        for sub in sample.subsamples {
            let clear = Int(sub.clear)
            if pos + clear > chunk.count { break }
            pos += clear
            let enc = min(Int(sub.encrypted), chunk.count - pos)
            if pos + enc > chunk.count { break }
            var p = pos
            while p < pos + enc {
                if ksPos == 16 {
                    keystream = aesECBEncryptBlock(counter, key: key)
                    incrementCounter(&counter)
                    ksPos = 0
                }
                dst[p] ^= keystream[ksPos]
                ksPos += 1
                p += 1
            }
            pos += enc
        }
        return dst
    }

    private static func encryptedSampleOriginalFormat(_ stsdData: [UInt8]) -> [UInt8] {
        guard let idx = findSubslice(stsdData, needle: Array("frma".utf8)) else {
            return Array("mp4a".utf8)
        }
        guard idx >= 4, idx + 8 <= stsdData.count else { return Array("mp4a".utf8) }
        let size = Int(readU32(stsdData, idx - 4))
        guard size >= 12, idx - 4 + size <= stsdData.count else { return Array("mp4a".utf8) }
        return Array(stsdData[(idx + 4)..<(idx + 8)])
    }

    private static func findSubslice(_ haystack: [UInt8], needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle {
            return i
        }
        return nil
    }

    private static func readU32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readU16(_ data: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readU64(_ data: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(data[offset + i]) }
        return value
    }

    static func hexDecode(_ value: String) -> [UInt8]? {
        let chars = Array(value.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = hexNibble(chars[index]), let low = hexNibble(chars[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x61...0x66: return byte - 0x61 + 10
        case 0x41...0x46: return byte - 0x41 + 10
        default: return nil
        }
    }
}