import XCTest
@testable import BindersKit

final class InstancesTests: XCTestCase {
    private func procArgs(_ arguments: [String], path: String = "/Applications/Binders.app/Contents/MacOS/Binders",
                          padding: Int = 3, environment: [String] = ["HOME=/Users/someone"]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array(path.utf8) + Array(repeating: 0, count: padding)
        for argument in arguments + environment { bytes += Array(argument.utf8) + [0] }
        return bytes
    }

    func testTheAppItselfCounts() {
        XCTAssertTrue(AppInstances.isApp(arguments: ["/Applications/Binders.app/Contents/MacOS/Binders"]))
        // Xcode passes arguments of its own to a debug run; that is still the app.
        XCTAssertTrue(AppInstances.isApp(arguments: ["/x/Binders", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testTheMCPServerAndSelfTestsDoNot() {
        XCTAssertFalse(AppInstances.isApp(arguments: ["/Applications/Binders.app/Contents/MacOS/Binders", "--mcp"]))
        XCTAssertFalse(AppInstances.isApp(arguments: ["/x/Binders", "--selftest-demo-shots", "/tmp/shots", "--appearance", "dark"]))
        XCTAssertFalse(AppInstances.isApp(arguments: ["/x/Binders", "--selftest-capture-probe"]))
    }

    func testArgumentsAreReadFromTheKernelBuffer() {
        let args = ["/Applications/Binders.app/Contents/MacOS/Binders", "--mcp"]
        XCTAssertEqual(AppInstances.arguments(fromProcArgs: procArgs(args)), args)
        XCTAssertEqual(AppInstances.arguments(fromProcArgs: procArgs(["/x/Binders"], padding: 1)), ["/x/Binders"])
        XCTAssertEqual(AppInstances.arguments(fromProcArgs: procArgs(["/x/Binders", "", "--mcp"])), ["/x/Binders", "", "--mcp"])
    }

    func testMalformedBuffersAreRejected() {
        XCTAssertNil(AppInstances.arguments(fromProcArgs: []))
        XCTAssertNil(AppInstances.arguments(fromProcArgs: [1, 0]))
        // Claims three arguments but carries one.
        var short = procArgs(["/x/Binders"], environment: [])
        short.replaceSubrange(0..<4, with: withUnsafeBytes(of: Int32(3)) { Array($0) })
        XCTAssertNil(AppInstances.arguments(fromProcArgs: short))
    }
}
