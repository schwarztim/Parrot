import SwiftUI

/// The agent's questions, one step at a time: click, use the arrow keys and
/// Return, press a number, or speak an option. [AGT]
struct AgentElicitationView: View {
    @Bindable var bridge: AgentBridge
    @FocusState private var focused: Bool

    var body: some View {
        if let state = bridge.elicitation {
            let question = state.current
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let header = question.header, !header.isEmpty {
                        Text(header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isMultiStep {
                        Text("\(state.step + 1) of \(state.questions.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(question.question).font(.subheadline.weight(.semibold))
                if question.multiSelect {
                    Text("Choose any that apply.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option, state: state)
                }
                if let free = state.freeText[state.step] {
                    Label("Your answer: \(free)", systemImage: "text.bubble")
                        .font(.caption)
                }
                HStack {
                    if state.step > 0 {
                        Button("Back") { bridge.elicitation?.back() }
                    }
                    Button("Answer in Terminal") { Task { await bridge.dismissCurrent() } }
                    Spacer()
                    Button(state.isLastStep ? "Send" : "Next") {
                        Task { await bridge.advanceOrSend() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.currentStepAnswered)
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { bridge.elicitation?.moveFocus(-1); return .handled }
            .onKeyPress(.downArrow) { bridge.elicitation?.moveFocus(1); return .handled }
            .onKeyPress(.return) { chooseFocused(); return .handled }
            .onKeyPress(.space) { chooseFocused(); return .handled }
            .onKeyPress(characters: .decimalDigits) { press in
                guard let number = Int(press.characters), question.options.indices.contains(number - 1) else { return .ignored }
                Task { await bridge.chooseOption(question.options[number - 1].label) }
                return .handled
            }
        }
    }

    private func optionRow(index: Int, option: HookQuestion.Option, state: AgentElicitation) -> some View {
        let selected = state.isSelected(option.label)
        let multi = state.current.multiSelect
        return Button {
            Task { await bridge.chooseOption(option.label) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multi
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(index + 1). \(option.label)")
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(index == state.focusIndex ? Color.accentColor.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func chooseFocused() {
        guard let state = bridge.elicitation, state.current.options.indices.contains(state.focusIndex) else { return }
        let label = state.current.options[state.focusIndex].label
        Task { await bridge.chooseOption(label) }
    }
}
