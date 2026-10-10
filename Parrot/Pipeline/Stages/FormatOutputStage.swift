import Foundation

/// Final formatting before delivery (OUT).
///
/// With the mode's Autocapitalize Insert on (the default), the first word
/// follows the caret: a capital at a sentence start, lowercase mid-sentence,
/// and a space in front when the caret sits right after a word. Skipped when
/// the text will not be pasted or the field cannot be read.
@MainActor
final class FormatOutputStage: DictationStage {
    var failurePolicy: StageFailurePolicy { .skip }
    var runsAfterFinish: Bool { false }

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func run(_ session: DictationSession) async throws -> StageResult {
        let autoPaste = DeliveryPolicy.effectiveAutoPaste(
            mode: session.mode?.autoPaste,
            global: services.settings?.output.autoPaste ?? true
        )
        guard session.mode?.autocapitalizeInsert ?? true, autoPaste,
              !session.text.isEmpty,
              let prefetch = session.pasteTargetPrefetch,
              let cursor = await prefetch.value?.cursor
        else { return .continue }

        session.text = Autocapitalizer.adjustCase(session.text, context: cursor)
        session.outputNeedsLeadingSpace = Autocapitalizer.needsLeadingSpace(session.text, context: cursor)
        return .continue
    }
}
