import Foundation

/// Reads pixel size from PNG and JPEG headers where AppKit's image decoding is not available.
enum ImageHeader {
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        return png(bytes) ?? jpeg(bytes)
    }

    private static func png(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count >= 24, Array(bytes[0..<8]) == signature else { return nil }
        func bigEndian(at offset: Int) -> Int {
            bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
        }
        return (bigEndian(at: 16), bigEndian(at: 20))
    }

    private static func jpeg(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var offset = 2
        while offset + 9 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            // Start-of-frame markers hold the size. C4, C8 and CC share the range but do not.
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                let height = Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6])
                let width = Int(bytes[offset + 7]) << 8 | Int(bytes[offset + 8])
                return (width, height)
            }
            offset += 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        return nil
    }
}
