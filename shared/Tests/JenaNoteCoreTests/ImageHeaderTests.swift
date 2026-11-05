import XCTest
@testable import JenaNoteCore

final class ImageHeaderTests: XCTestCase {
    func testReadsPNGSize() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGP4z8DwnwGM/zMwAAAf7gP9NRsAMwAAAABJRU5ErkJggg=="))
        XCTAssertEqual(ImageHeader.pixelSize(png)?.width, 2)
        XCTAssertEqual(ImageHeader.pixelSize(png)?.height, 2)
    }

    func testReadsJPEGSizeAfterOtherSegments() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00,
                         0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x2C, 0x02, 0x58])
        XCTAssertEqual(ImageHeader.pixelSize(jpeg)?.width, 600)
        XCTAssertEqual(ImageHeader.pixelSize(jpeg)?.height, 300)
    }

    func testRejectsUnknownOrTruncatedData() {
        XCTAssertNil(ImageHeader.pixelSize(Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNil(ImageHeader.pixelSize(Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00])))
        XCTAssertNil(ImageHeader.pixelSize(Data()))
    }
}
