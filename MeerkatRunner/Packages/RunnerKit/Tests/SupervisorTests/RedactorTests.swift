import Supervisor
import XCTest

final class RedactorTests: XCTestCase {
    func testAssignments() {
        XCTAssertEqual(Redactor.redact("API_KEY=abc123"), "API_KEY=[redacted]")
        XCTAssertEqual(Redactor.redact("export SESSION_SECRET=\"a b\" next"), "export SESSION_SECRET=[redacted] next")
        XCTAssertEqual(Redactor.redact("db_password=hunter2 port=5432"), "db_password=[redacted] port=5432")
    }

    func testJSONPairs() {
        XCTAssertEqual(Redactor.redact(#"{"authToken": "xyz", "port": "3000"}"#), #"{"authToken": "[redacted]", "port": "3000"}"#)
    }

    func testLeavesOrdinaryOutputAlone() {
        let line = "  ➜  Local:   http://localhost:5173/"
        XCTAssertEqual(Redactor.redact(line), line)
    }
}
