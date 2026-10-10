import XCTest
@testable import Parrot

final class ElicitationTests: XCTestCase {

    private let framework = HookQuestion(
        question: "Which framework?", header: "Framework",
        options: [.init(label: "React", description: "Component library"), .init(label: "Vue"), .init(label: "Svelte Kit")]
    )
    private let extras = HookQuestion(
        question: "Which extras?", header: "Extras",
        options: [.init(label: "Router"), .init(label: "State"), .init(label: "Tests")], multiSelect: true
    )

    func testSingleSelectReplacesAndFinishesTheStep() {
        var state = AgentElicitation(questions: [framework])
        XCTAssertFalse(state.isMultiStep)
        XCTAssertTrue(state.isLastStep)
        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.choose("Vue"))
        XCTAssertTrue(state.choose("React"))
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.answers(), ["Which framework?": ["React"]])
        XCTAssertFalse(state.choose("Angular"), "unknown labels are ignored")
    }

    func testMultiSelectTogglesInOptionOrder() {
        var state = AgentElicitation(questions: [extras])
        XCTAssertFalse(state.choose("Tests"))
        XCTAssertFalse(state.choose("Router"))
        XCTAssertFalse(state.choose("State"))
        XCTAssertFalse(state.choose("State"))
        XCTAssertEqual(state.answers(), ["Which extras?": ["Router", "Tests"]])
        XCTAssertTrue(state.isSelected("Tests"))
        XCTAssertFalse(state.isSelected("State"))
    }

    func testMultiStepCollectsEveryAnswer() {
        var state = AgentElicitation(questions: [framework, extras])
        XCTAssertTrue(state.isMultiStep)
        state.choose("Vue")
        XCTAssertTrue(state.next())
        XCTAssertEqual(state.current.question, "Which extras?")
        XCTAssertFalse(state.isComplete)
        state.choose("State")
        XCTAssertFalse(state.next(), "no step after the last")
        XCTAssertTrue(state.isComplete)
        state.back()
        XCTAssertTrue(state.isSelected("Vue"), "going back keeps earlier answers")
        XCTAssertEqual(state.answers(), ["Which framework?": ["Vue"], "Which extras?": ["State"]])
    }

    func testFreeTextAnswerReplacesChoices() {
        var state = AgentElicitation(questions: [framework])
        state.choose("React")
        state.setFreeText("  Solid, honestly  ")
        XCTAssertFalse(state.isSelected("React"))
        XCTAssertEqual(state.answers(), ["Which framework?": ["Solid, honestly"]])
        state.setFreeText("   ")
        XCTAssertEqual(state.answers(), ["Which framework?": ["Solid, honestly"]], "blank text changes nothing")
    }

    func testKeyboardFocusWrapsAndChooses() {
        var state = AgentElicitation(questions: [framework])
        state.moveFocus(-1)
        XCTAssertEqual(state.focusIndex, 2)
        state.moveFocus(1)
        XCTAssertEqual(state.focusIndex, 0)
        state.moveFocus(1)
        XCTAssertTrue(state.chooseFocused())
        XCTAssertEqual(state.answers(), ["Which framework?": ["Vue"]])
    }

    func testSpokenAnswersMatchOptions() {
        XCTAssertEqual(AgentElicitation.match("React.", in: framework), ["React"])
        XCTAssertEqual(AgentElicitation.match("svelte kit", in: framework), ["Svelte Kit"])
        XCTAssertEqual(AgentElicitation.match("option two", in: framework), ["Vue"])
        XCTAssertEqual(AgentElicitation.match("the third one", in: framework), ["Svelte Kit"])
        XCTAssertEqual(AgentElicitation.match("let's go with vue please", in: framework), ["Vue"])
        XCTAssertEqual(AgentElicitation.match("router and tests", in: extras), ["Router", "Tests"])
        XCTAssertEqual(AgentElicitation.match("something else entirely", in: framework), [])
        XCTAssertEqual(AgentElicitation.match("option nine", in: framework), [])
    }

    func testApplySpokenChoosesOrFallsBackToFreeText() {
        var single = AgentElicitation(questions: [framework, extras])
        XCTAssertTrue(single.applySpoken("Vue"))
        single.next()
        XCTAssertFalse(single.applySpoken("router and state"))
        XCTAssertEqual(single.answers()["Which extras?"], ["Router", "State"])

        var free = AgentElicitation(questions: [framework])
        XCTAssertTrue(free.applySpoken("Use whatever the repo already has"))
        XCTAssertEqual(free.answers(), ["Which framework?": ["Use whatever the repo already has"]])
    }

    // MARK: - Through the Bridge

    @MainActor
    func testBridgeSendsAllAnswersTogether() async throws {
        let fixture = AgentFixture()
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        fixture.bridge.ingest(fixture.update(.question, session: "a", request: "request-a1"))
        XCTAssertEqual(fixture.bridge.elicitation?.questions.count, 2)

        // Step one, single select: a click advances.
        await fixture.bridge.chooseOption("Vue")
        XCTAssertEqual(fixture.bridge.elicitation?.step, 1)
        XCTAssertNil(try fixture.response(for: "request-a1"))

        // Step two, multi select: speak, then send.
        await fixture.bridge.receiveDictation("router and state")
        XCTAssertNil(try fixture.response(for: "request-a1"), "multi select waits for Send")
        await fixture.bridge.advanceOrSend()

        let response = try XCTUnwrap(try fixture.response(for: "request-a1"))
        XCTAssertEqual(response.action, .answer)
        XCTAssertEqual(response.answers, ["Which framework?": ["Vue"], "Which extras?": ["Router", "State"]])
        XCTAssertNil(fixture.bridge.elicitation, "state clears with the session")
    }

    @MainActor
    func testNewRequestClearsElicitationState() {
        let fixture = AgentFixture()
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        fixture.bridge.ingest(fixture.update(.question, session: "a", request: "request-a1"))
        fixture.bridge.elicitation?.choose("React")
        fixture.bridge.ingest(fixture.update(.question, session: "a", request: "request-a2"))
        XCTAssertEqual(fixture.bridge.elicitation?.isSelected("React"), false)
        fixture.bridge.ingest(fixture.update(.stop, session: "a", request: "request-a3"))
        XCTAssertNil(fixture.bridge.elicitation)
    }
}
