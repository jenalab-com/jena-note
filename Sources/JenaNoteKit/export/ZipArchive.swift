import Foundation

// MARK: - ZipArchive
//
// 의존성 0 zip 패커. docx·hwpx는 결국 zip + XML이라, 외부 도구 없이 직접 쓴다.
// 1차는 **무압축(stored)** 만 지원한다 — Word·한글 둘 다 stored 엔트리를 연다.
// (deflate가 필요해지면 Compression.framework의 raw DEFLATE로 추가하면 된다.)
//
// hwpx 요구: `mimetype`이 zip의 첫 엔트리 + 무압축이어야 한다(이 패커는 stored 전용이라 자동 충족).

struct ZipArchive {

    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
        let offset: UInt32   // local header가 시작하는 바이트 오프셋
    }

    private var entries: [Entry] = []
    private var buffer = Data()

    // DOS date/time — 결정적 산출물을 위해 고정값(1980-01-01 00:00:00).
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021   // year=0(1980), month=1, day=1

    /// 엔트리 추가. 데이터는 무압축(stored)으로 저장된다.
    mutating func addEntry(path: String, data: Data) {
        let crc = ZipArchive.crc32(data)
        let offset = UInt32(buffer.count)
        entries.append(Entry(path: path, data: data, crc32: crc, offset: offset))

        let nameBytes = Array(path.utf8)

        // ── Local File Header ──
        buffer.appendUInt32(0x04034b50)            // signature
        buffer.appendUInt16(20)                    // version needed (2.0)
        buffer.appendUInt16(0)                     // general purpose flag
        buffer.appendUInt16(0)                     // compression method = stored
        buffer.appendUInt16(ZipArchive.dosTime)
        buffer.appendUInt16(ZipArchive.dosDate)
        buffer.appendUInt32(crc)
        buffer.appendUInt32(UInt32(data.count))    // compressed size (== uncompressed)
        buffer.appendUInt32(UInt32(data.count))    // uncompressed size
        buffer.appendUInt16(UInt16(nameBytes.count))
        buffer.appendUInt16(0)                     // extra field length
        buffer.append(contentsOf: nameBytes)
        buffer.append(data)
    }

    /// 모든 엔트리를 마감하고 완성된 zip 바이트를 돌려준다.
    func finalize() -> Data {
        var out = buffer
        let centralDirOffset = UInt32(out.count)

        for e in entries {
            let nameBytes = Array(e.path.utf8)
            // ── Central Directory File Header ──
            out.appendUInt32(0x02014b50)           // signature
            out.appendUInt16(20)                   // version made by
            out.appendUInt16(20)                   // version needed
            out.appendUInt16(0)                    // flags
            out.appendUInt16(0)                    // compression = stored
            out.appendUInt16(ZipArchive.dosTime)
            out.appendUInt16(ZipArchive.dosDate)
            out.appendUInt32(e.crc32)
            out.appendUInt32(UInt32(e.data.count)) // compressed size
            out.appendUInt32(UInt32(e.data.count)) // uncompressed size
            out.appendUInt16(UInt16(nameBytes.count))
            out.appendUInt16(0)                    // extra length
            out.appendUInt16(0)                    // comment length
            out.appendUInt16(0)                    // disk number start
            out.appendUInt16(0)                    // internal attrs
            out.appendUInt32(0)                    // external attrs
            out.appendUInt32(e.offset)             // local header offset
            out.append(contentsOf: nameBytes)
        }

        let centralDirSize = UInt32(out.count) - centralDirOffset

        // ── End of Central Directory Record ──
        out.appendUInt32(0x06054b50)               // signature
        out.appendUInt16(0)                        // disk number
        out.appendUInt16(0)                        // disk with central dir
        out.appendUInt16(UInt16(entries.count))    // entries on this disk
        out.appendUInt16(UInt16(entries.count))    // total entries
        out.appendUInt32(centralDirSize)
        out.appendUInt32(centralDirOffset)
        out.appendUInt16(0)                        // comment length

        return out
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - Data little-endian 헬퍼

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
