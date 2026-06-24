import XCTest
@testable import JenaNoteKit

final class HwpxWriterTests: XCTestCase {

    private func unzip(_ data: Data) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hwpx-\(UUID().uuidString).hwpx")
        try data.write(to: tmp)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hwpxout-\(UUID().uuidString)", isDirectory: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", tmp.path, "-d", outDir.path]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        return outDir
    }

    // MARK: - 무결성 + mimetype 첫 엔트리

    func testHwpxIsValidZip() throws {
        let data = HwpxWriter.write([.paragraph([Inline(text: "안녕하세요")])])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hwpxvalid-\(UUID().uuidString).hwpx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-t", tmp.path]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("No errors detected"), out)
    }

    func testMimetypeIsFirstEntry() throws {
        let data = HwpxWriter.write([.paragraph([Inline(text: "x")])])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hwpxmime-\(UUID().uuidString).hwpx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-l", tmp.path]
        let pipe = Pipe(); proc.standardOutput = pipe
        try proc.run(); proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // 목록에서 mimetype이 첫 파일로 등장해야 한다
        let lines = out.components(separatedBy: "\n")
        let fileLines = lines.filter { $0.contains("mimetype") || $0.contains("Contents/") || $0.contains("version.xml") }
        XCTAssertTrue(fileLines.first?.contains("mimetype") ?? false, "mimetype이 첫 엔트리가 아니다:\n\(out)")
    }

    // MARK: - 본문 / 서식 노드

    func testSectionContainsText() throws {
        let dir = try unzip(HwpxWriter.write([
            .heading(level: 1, inlines: [Inline(text: "제목입니다")]),
            .paragraph([Inline(text: "본문 내용")])
        ]))
        defer { try? FileManager.default.removeItem(at: dir) }
        let sec = try String(contentsOf: dir.appendingPathComponent("Contents/section0.xml"), encoding: .utf8)
        XCTAssertTrue(sec.contains("제목입니다"))
        XCTAssertTrue(sec.contains("본문 내용"))
        XCTAssertTrue(sec.contains("<hp:secPr"), "섹션 설정이 첫 문단에 있어야 한다")
        XCTAssertTrue(sec.contains("<hp:t>"), "텍스트 노드가 있어야 한다")
    }

    func testHeaderContainsCharPrWithBoldAndColor() throws {
        let dir = try unzip(HwpxWriter.write([
            .paragraph([Inline(text: "굵게", bold: true), Inline(text: "빨강", color: "#FF0000")])
        ]))
        defer { try? FileManager.default.removeItem(at: dir) }
        let head = try String(contentsOf: dir.appendingPathComponent("Contents/header.xml"), encoding: .utf8)
        XCTAssertTrue(head.contains("<hh:bold/>"), "굵게 charPr가 있어야 한다")
        XCTAssertTrue(head.contains("textColor=\"#FF0000\""), "색상 charPr가 있어야 한다")
        XCTAssertTrue(head.contains("<hh:charProperties"))
    }

    func testTableFlattenedAndImageSkipped() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])   // 가짜 — 빌더가 아니라 직접 ImageRef
        let out = HwpxWriter.build([
            .table(rows: [[[Inline(text: "이름")], [Inline(text: "나이")]],
                          [[Inline(text: "철수")], [Inline(text: "20")]]], headerRow: 0),
            .image(ImageRef(data: png, fileName: "image1.png", width: nil))
        ])
        XCTAssertEqual(out.imageSkipped, 1, "이미지는 1차 hwpx에서 건너뛴다")

        let dir = try unzip(out.data)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sec = try String(contentsOf: dir.appendingPathComponent("Contents/section0.xml"), encoding: .utf8)
        // 표 내용이 텍스트로 평탄화돼 보존
        XCTAssertTrue(sec.contains("이름"))
        XCTAssertTrue(sec.contains("철수"))
    }

    // MARK: - 수동 검증용 종합 샘플 (한글에서 열기)

    func testGenerateComprehensiveSample() throws {
        let blocks: [Block] = [
            .heading(level: 1, inlines: [Inline(text: "내보내기 테스트 문서")]),
            .paragraph([Inline(text: "일반 본문과 "), Inline(text: "굵게", bold: true),
                        Inline(text: ", "), Inline(text: "기울임", italic: true),
                        Inline(text: ", "), Inline(text: "빨강", color: "#E53935"), Inline(text: " 서식.")]),
            .heading(level: 2, inlines: [Inline(text: "목록")]),
            .listItem(ordered: false, index: 0, inlines: [Inline(text: "사과")]),
            .listItem(ordered: true, index: 1, inlines: [Inline(text: "첫째")]),
            .blockquote([Inline(text: "인용문입니다.")]),
            .codeBlock("let x = 1\nlet y = 2"),
            .heading(level: 3, inlines: [Inline(text: "표 (평탄화)")]),
            .table(rows: [
                [[Inline(text: "이름")], [Inline(text: "나이")]],
                [[Inline(text: "철수")], [Inline(text: "20")]]
            ], headerRow: 0),
            .horizontalRule,
            .paragraph([Inline(text: "끝.")])
        ]
        let data = HwpxWriter.write(blocks)
        let sample = URL(fileURLWithPath: "/private/tmp/claude-502/-Volumes-Backup-Project-jena-source-jena-note/751f28cb-dc26-482f-8e9b-babe7511c476/scratchpad/sample-export.hwpx")
        try? data.write(to: sample)
        XCTAssertFalse(data.isEmpty)
    }
}
