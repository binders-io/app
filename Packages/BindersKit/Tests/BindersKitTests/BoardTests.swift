import XCTest
@testable import BindersKit

final class BoardTests: XCTestCase {
    private let agentA = BoardActor(name: "Claude Code · repo", kind: .agent)
    private let agentB = BoardActor(name: "Cursor", kind: .agent)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testClaimingStartsWorkAndALease() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertEqual(card.column, .inProgress)
        XCTAssertEqual(card.assignee, agentA.name)
        XCTAssertEqual(card.claimExpires, now.addingTimeInterval(BoardRules.lease))
        let mine = try BoardRules.claim(CardState(column: .backlog), by: .you, at: now)
        XCTAssertNil(mine.claimExpires, "people's claims don't lapse")
    }

    func testOnlyOneOwnerAtATime() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.claim(card, by: agentB, at: now.addingTimeInterval(60))) {
            guard case BoardError.claimedBy(let name, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(name, self.agentA.name)
        }
        XCTAssertNoThrow(try BoardRules.claim(card, by: agentA, at: now.addingTimeInterval(60)), "claiming again renews")
        // Once the lease lapses, anyone can take it.
        XCTAssertNoThrow(try BoardRules.claim(card, by: agentB, at: now.addingTimeInterval(BoardRules.lease + 1)))
    }

    func testAgentsHandOverForReview() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.move(card, to: .done, by: agentA, agentsMayFinish: false, at: now)) {
            XCTAssertEqual($0 as? BoardError, .agentsCannotFinish)
        }
        let handed = try BoardRules.complete(card, by: agentA, agentsMayFinish: false, at: now)
        XCTAssertEqual(handed.column, .review)
        XCTAssertEqual(handed.assignee, agentA.name, "keeps who did it")
        XCTAssertNil(handed.claimExpires)
        XCTAssertEqual(try BoardRules.complete(card, by: agentA, agentsMayFinish: true, at: now).column, .done)
        XCTAssertEqual(try BoardRules.move(handed, to: .done, by: .you, agentsMayFinish: false, at: now).column, .done, "you approve")
    }

    func testAgentsCantTouchSomeoneElsesCard() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertThrowsError(try BoardRules.move(card, to: .review, by: agentB, agentsMayFinish: true, at: now))
        XCTAssertThrowsError(try BoardRules.release(card, by: agentB, at: now))
        XCTAssertThrowsError(try BoardRules.complete(card, by: agentB, agentsMayFinish: true, at: now))
        // You can always take over.
        let released = try BoardRules.release(card, by: .you, at: now)
        XCTAssertNil(released.assignee)
        XCTAssertEqual(released.column, .ready)
    }

    func testAskingBlocksUntilAPersonAnswers() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let asked = try BoardRules.ask(card, by: agentA, at: now.addingTimeInterval(600))
        XCTAssertEqual(asked.column, .blocked)
        XCTAssertEqual(asked.claimExpires, now.addingTimeInterval(600 + BoardRules.lease), "asking counts as reporting in")
        XCTAssertEqual(BoardRules.answered(asked, by: agentB).column, .blocked, "only a person's answer unblocks")
        XCTAssertEqual(BoardRules.answered(asked, by: .you).column, .inProgress)
    }

    func testQuietAgentsLoseTheirCard() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        XCTAssertNil(BoardRules.expire(card, at: now.addingTimeInterval(60)))
        let lapsed = BoardRules.expire(card, at: now.addingTimeInterval(BoardRules.lease))
        XCTAssertEqual(lapsed?.column, .ready)
        XCTAssertNil(lapsed?.assignee)
        let reported = BoardRules.renew(card, by: agentA, at: now.addingTimeInterval(20 * 60))
        XCTAssertNil(BoardRules.expire(reported, at: now.addingTimeInterval(BoardRules.lease)), "reporting in extends the lease")
        let mine = try BoardRules.claim(CardState(column: .ready), by: .you, at: now)
        XCTAssertNil(BoardRules.expire(mine, at: now.addingTimeInterval(86_400)))
    }

    func testMovingBackToTheQueueLetsGo() throws {
        let card = try BoardRules.claim(CardState(column: .ready), by: agentA, at: now)
        let back = try BoardRules.move(card, to: .ready, by: agentA, agentsMayFinish: false, at: now)
        XCTAssertNil(back.assignee)
        let started = try BoardRules.move(CardState(column: .ready), to: .inProgress, by: .you, agentsMayFinish: false, at: now)
        XCTAssertEqual(started.assignee, "You", "starting work means taking it")
        XCTAssertThrowsError(try BoardRules.claim(CardState(column: .done), by: .you, at: now))
    }

    func testLooseColumnNamesAndAgentNames() {
        XCTAssertEqual(BoardColumn(loose: "In Progress"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "in_progress"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "doing"), .inProgress)
        XCTAssertEqual(BoardColumn(loose: "Ready for review"), .review)
        XCTAssertNil(BoardColumn(loose: "someday maybe"))
        XCTAssertEqual(BoardRules.agentName(fromClient: "claude-code"), "Claude Code")
        XCTAssertEqual(BoardRules.agentName(fromClient: ""), "AI agent")
    }
}
