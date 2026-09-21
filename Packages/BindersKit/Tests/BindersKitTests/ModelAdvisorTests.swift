import XCTest
@testable import BindersKit

final class ModelAdvisorTests: XCTestCase {
    func testEveryCommonMacGetsAModelThatFits() {
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 8).model, "gemma4:e2b-it-qat")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 16).model, "gemma4:e4b-it-qat")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 18).model, "gemma4:e4b-it-qat")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 24).model, "gemma4:12b")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 36).model, "gemma4:12b")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 48).model, "gemma4:26b")
        XCTAssertEqual(ModelAdvisor.recommendation(memoryGB: 128).model, "gemma4:26b")
        // The download never takes more than about 40% of memory.
        for memory in [8, 16, 24, 32, 36, 48, 64, 96, 128] {
            let pick = ModelAdvisor.recommendation(memoryGB: memory)
            XCTAssertLessThanOrEqual(pick.downloadGB / Double(memory), 0.55, "\(pick.model) on \(memory) GB")
        }
    }

    func testMemoryIsCountedInAppleGigabytes() {
        XCTAssertEqual(ModelAdvisor.memoryGB(bytes: 17_179_869_184), 16)
        XCTAssertEqual(ModelAdvisor.memoryGB(bytes: 137_438_953_472), 128)
    }

    func testFlagsAModelFromAHigherTier() {
        XCTAssertTrue(ModelAdvisor.isTooLarge("gemma4:26b", memoryGB: 16))
        XCTAssertFalse(ModelAdvisor.isTooLarge("gemma4:26b", memoryGB: 64))
        XCTAssertFalse(ModelAdvisor.isTooLarge("gemma4:e2b-it-qat", memoryGB: 64))
        XCTAssertFalse(ModelAdvisor.isTooLarge("some-other-model", memoryGB: 8))
    }
}
