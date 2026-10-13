import Models
@testable import Scanner
import XCTest

final class ListenerClassifierTests: XCTestCase {
    private func label(_ argv: [String], exe: String = "/usr/local/bin/node") -> String? {
        ListenerClassifier.classify(executablePath: exe, argv: argv)
    }

    func testFrameworkTable() {
        XCTAssertEqual(label(["node", "/Users/me/app/node_modules/.bin/next", "dev"]), "Next.js")
        XCTAssertEqual(label(["node", "/Users/me/app/node_modules/.bin/vite"]), "Vite")
        XCTAssertEqual(label(["node", "node_modules/.bin/astro", "dev"]), "Astro")
        XCTAssertEqual(label(["ruby", "bin/rails", "server"], exe: "/usr/bin/ruby"), "Rails")
        XCTAssertEqual(label(["ruby", "bin/rails", "s"], exe: "/usr/bin/ruby"), "Rails")
        XCTAssertEqual(label(["puma", "-C", "config/puma.rb"], exe: "/usr/bin/ruby"), "Rails")
        XCTAssertEqual(label(["python3", "manage.py", "runserver"], exe: "/usr/bin/python3"), "Django")
        XCTAssertEqual(label([".venv/bin/uvicorn", "main:app"], exe: "/usr/bin/python3"), "Python")
        XCTAssertEqual(label(["gunicorn", "app:app"], exe: "/usr/bin/python3"), "Python")
        XCTAssertEqual(label(["flask", "run"], exe: "/usr/bin/python3"), "Python")
        XCTAssertEqual(label(["php", "artisan", "serve"], exe: "/opt/homebrew/bin/php"), "Laravel")
        XCTAssertEqual(label(["node", "server.js"]), "Node")
    }

    func testUnknownProcessHasNoLabel() {
        XCTAssertNil(label(["postgres", "-D", "/usr/local/var/postgres"], exe: "/usr/local/bin/postgres"))
    }

    func testEmptyArgvFallsBackToExecutable() {
        XCTAssertEqual(label([], exe: "/usr/local/bin/node"), "Node")
    }
}
