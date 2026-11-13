import XCTest
@testable import ClaudeStudio

final class SearchFoldTests: XCTestCase {

    private func folded(_ text: String) -> String {
        var bytes = Array(text.utf8)
        ClaudeTranscripts.fold(&bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    func testAsciiIsLowercased() {
        XCTAssertEqual(folded("Hello WORLD 42"), "hello world 42")
    }

    func testTurkishAndLatinCapitalsFoldToTheirSmallLetters() {
        XCTAssertEqual(folded("ÇALIŞMA ĞÜÖ"), folded("çalişma ğüö"))
        XCTAssertEqual(folded("Şirket"), "şirket")
        XCTAssertEqual(folded("ÜRÜN"), "ürün")
    }

    func testFoldingKeepsTheByteLength() {
        let text = "İSTANBUL ıI Ç×÷"
        XCTAssertEqual(folded(text).utf8.count, text.utf8.count)
    }
}
