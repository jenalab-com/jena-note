import XCTest
@testable import JenaNoteKit

final class ZipArchiveTests: XCTestCase {

    // MARK: - CRC32 표준 테스트 벡터

    func testCRC32KnownVector() {
        // "123456789"의 CRC32는 0xCBF43926 (표준 테스트 벡터)
        let data = "123456789".data(using: .ascii)!
        XCTAssertEqual(ZipArchive.crc32(data), 0xCBF43926)
    }

    func testCRC32Empty() {
        XCTAssertEqual(ZipArchive.crc32(Data()), 0)
    }

    // MARK: - 실제 unzip 무결성 검증

    func testProducesValidZipReadableByUnzip() throws {
        var zip = ZipArchive()
        zip.addEntry(path: "hello.txt", data: "안녕하세요".data(using: .utf8)!)
        zip.addEntry(path: "nested/world.txt", data: "world".data(using: .utf8)!)
        let data = zip.finalize()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziptest-\(UUID().uuidString).zip")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // unzip -t: CRC·구조 무결성 검사
        let test = try runUnzip(["-t", tmp.path])
        XCTAssertEqual(test.status, 0, "unzip -t 실패:\n\(test.output)")
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)

        // 풀어서 내용 일치 확인
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let extract = try runUnzip(["-o", tmp.path, "-d", outDir.path])
        XCTAssertEqual(extract.status, 0, extract.output)

        let hello = try String(contentsOf: outDir.appendingPathComponent("hello.txt"), encoding: .utf8)
        XCTAssertEqual(hello, "안녕하세요")
        let world = try String(contentsOf: outDir.appendingPathComponent("nested/world.txt"), encoding: .utf8)
        XCTAssertEqual(world, "world")
    }

    func testEmptyEntryAndBinaryData() throws {
        var zip = ZipArchive()
        zip.addEntry(path: "empty", data: Data())
        zip.addEntry(path: "bin", data: Data([0x00, 0xFF, 0x42, 0x13, 0x37]))
        let data = zip.finalize()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziptest2-\(UUID().uuidString).zip")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let test = try runUnzip(["-t", tmp.path])
        XCTAssertEqual(test.status, 0, "빈 엔트리·바이너리 무결성 실패:\n\(test.output)")
    }

    // MARK: - Helper

    private func runUnzip(_ args: [String]) throws -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, out)
    }
}
