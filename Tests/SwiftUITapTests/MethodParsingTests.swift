import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import SwiftParser
import XCTest
@testable import SwiftUITapMacros

final class MethodParsingTests: XCTestCase {

    // MARK: - Helper

    private func parseMethods(_ source: String) -> [MethodInfo] {
        let sourceFile = Parser.parse(source: source)
        guard let classDecl = sourceFile.statements.first?.item.as(ClassDeclSyntax.self) else {
            XCTFail("Expected a class declaration")
            return []
        }
        return extractMethods(from: classDecl)
    }

    private func generateCall(_ source: String) -> String {
        let methods = parseMethods(source)
        return generateAgentCall(methods: methods)
    }

    // MARK: - extractMethods: param parsing

    func testSimpleLabel() {
        let methods = parseMethods("""
        final class S {
            func addTodo(title: String) {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        let m = methods[0]
        XCTAssertEqual(m.name, "addTodo")
        XCTAssertEqual(m.params.count, 1)
        XCTAssertEqual(m.params[0].label, "title")
        XCTAssertEqual(m.params[0].internalName, "title")
        XCTAssertEqual(m.params[0].jsonKey, "title")
        XCTAssertEqual(m.params[0].type, "String")
    }

    func testKeywordLabel() {
        let methods = parseMethods("""
        final class S {
            func book(for bookID: String) -> String? { nil }
        }
        """)

        XCTAssertEqual(methods.count, 1)
        let m = methods[0]
        XCTAssertEqual(m.name, "book")
        XCTAssertEqual(m.params[0].label, "for")
        XCTAssertEqual(m.params[0].internalName, "bookID")
        XCTAssertEqual(m.params[0].jsonKey, "for")
    }

    func testMixedLabels() {
        let methods = parseMethods("""
        final class S {
            func move(from source: Int, to destination: Int) {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        let m = methods[0]
        XCTAssertEqual(m.params.count, 2)

        XCTAssertEqual(m.params[0].label, "from")
        XCTAssertEqual(m.params[0].internalName, "source")
        XCTAssertEqual(m.params[0].jsonKey, "from")

        XCTAssertEqual(m.params[1].label, "to")
        XCTAssertEqual(m.params[1].internalName, "destination")
        XCTAssertEqual(m.params[1].jsonKey, "to")
    }

    func testNoParams() {
        let methods = parseMethods("""
        final class S {
            func reset() {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods[0].name, "reset")
        XCTAssertEqual(methods[0].params.count, 0)
        XCTAssertNil(methods[0].returnType)
    }

    func testReturnType() {
        let methods = parseMethods("""
        final class S {
            func count() -> Int { 0 }
            func lookup(name: String) -> [String: Any]? { nil }
        }
        """)

        XCTAssertEqual(methods.count, 2)
        XCTAssertEqual(methods[0].returnType, "Int")
        XCTAssertEqual(methods[1].returnType, "[String: Any]?")
    }

    func testMultipleKeywordLabels() {
        let methods = parseMethods("""
        final class S {
            func session(for bookID: String, in library: String) -> String? { nil }
        }
        """)

        XCTAssertEqual(methods.count, 1)
        let m = methods[0]
        XCTAssertEqual(m.params.count, 2)

        XCTAssertEqual(m.params[0].label, "for")
        XCTAssertEqual(m.params[0].internalName, "bookID")
        XCTAssertEqual(m.params[1].label, "in")
        XCTAssertEqual(m.params[1].internalName, "library")
    }

    // MARK: - extractMethods: skipping

    func testSkipsUnlabeledParam() {
        // Methods with _ params are skipped (agent can't construct complex types)
        let methods = parseMethods("""
        final class S {
            func remove(_ index: Int) {}
            func visible(name: String) {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods[0].name, "visible")
    }

    func testSkipsPrivate() {
        let methods = parseMethods("""
        final class S {
            private func helper() {}
            func visible() {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods[0].name, "visible")
    }

    func testSkipsStatic() {
        let methods = parseMethods("""
        final class S {
            static func factory() -> S { S() }
            func instance() {}
        }
        """)

        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods[0].name, "instance")
    }

    // MARK: - generateAgentCall: code generation

    func testCallGenSimpleLabel() {
        let code = generateCall("""
        final class S {
            func addTodo(title: String) {}
        }
        """)

        XCTAssert(code.contains(#"case "addTodo":"#))
        XCTAssert(code.contains(#"params["title"] as? String"#))
        XCTAssert(code.contains("addTodo(title: title)"))
    }

    func testCallGenKeywordLabel() {
        let code = generateCall("""
        final class S {
            func book(for bookID: String) -> [String: Any]? { nil }
        }
        """)

        XCTAssert(code.contains(#"case "book":"#))
        // JSON key is the argument label "for"
        XCTAssert(code.contains(#"params["for"]"#), "Should use argument label as JSON key")
        // Local variable is the internal name "bookID" (not "for" which would be a syntax error)
        XCTAssert(code.contains("guard let bookID"), "Should use internal name as variable")
        // Call site uses label: internalName
        XCTAssert(code.contains("book(for: bookID)"), "Should use label: internalName at call site")
    }

    func testCallGenMixedLabels() {
        let code = generateCall("""
        final class S {
            func move(from source: Int, to destination: Int) {}
        }
        """)

        XCTAssert(code.contains(#"params["from"]"#))
        XCTAssert(code.contains("guard let source"))
        XCTAssert(code.contains(#"params["to"]"#))
        XCTAssert(code.contains("guard let destination"))
        XCTAssert(code.contains("move(from: source, to: destination)"))
    }

    func testCallGenNoParams() {
        let code = generateCall("""
        final class S {
            func reset() {}
        }
        """)

        XCTAssert(code.contains("reset()"))
        XCTAssert(code.contains("return .value(nil)"))
    }
}
