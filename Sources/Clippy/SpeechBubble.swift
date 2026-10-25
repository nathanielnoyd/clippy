import SwiftUI

struct BubbleMessage: Identifiable, Equatable {
    enum Role { case user, clippy, error }

    let id = UUID()
    var role: Role
    var text: String
}

final class BubbleModel: ObservableObject {
    static let greetings = [
        "Hi! It looks like you're trying to use a computer. Would you like help?",
        "Hi there! What can I help you with?",
        "Hello! What are we working on today?",
        "Need a hand? Ask me anything.",
        "I'm all ears. Well, all wire. What's up?",
        "Hey! Got a question for me?",
        "Ready when you are. What do you need?",
    ]

    @Published var messages = [BubbleMessage(role: .clippy, text: greetings.randomElement()!)]
    @Published var input = ""
    @Published var isThinking = false
    var onSubmit: ((String) -> Void)?
    var onNewChat: (() -> Void)?
    var onClose: (() -> Void)?

    var isFreshChat: Bool { messages.count <= 1 }

    func reset() {
        messages = [BubbleMessage(role: .clippy, text: Self.greetings.randomElement()!)]
        input = ""
        isThinking = false
    }

    /// Swaps in a different greeting if nothing has been said yet, keeping any draft.
    func regreet() {
        guard isFreshChat, !isThinking else { return }
        let current = messages.first?.text
        let text = Self.greetings.filter { $0 != current }.randomElement()!
        messages = [BubbleMessage(role: .clippy, text: text)]
    }

    func append(_ role: BubbleMessage.Role, _ text: String) {
        messages.append(BubbleMessage(role: role, text: text))
    }

    /// Replaces the text of the newest message (used while a reply streams in).
    func updateLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
    }
}

/// The classic pale-yellow tooltip balloon, holding a short chat thread.
struct SpeechBubble: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var focused: Bool

    static let balloon = Color(red: 1.0, green: 1.0, blue: 0.80)
    static let userNote = Color(red: 0.98, green: 0.92, blue: 0.62)
    static let ink = Color.black.opacity(0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider().overlay(Color.black.opacity(0.15))
            thread
            inputRow
        }
        .padding(10)
        .frame(width: 300)
        .background(
            BalloonShape()
                .fill(Self.balloon)
                .overlay(BalloonShape().stroke(.black, lineWidth: 1))
        )
        .padding(.bottom, 14) // room for the tail
        .environment(\.colorScheme, .light) // the balloon stays yellow in dark mode too
        .onAppear { focused = true }
        .onExitCommand { model.onClose?() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 11, weight: .semibold))
            Text("Clippy")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                model.onNewChat?()
                focused = true
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(model.isFreshChat && !model.isThinking)
            .opacity(model.isFreshChat && !model.isThinking ? 0.4 : 1)
            .help("Start a new conversation")

            Button { model.onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .foregroundStyle(Self.ink)
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.messages) { MessageRow(message: $0) }
                    if model.isThinking { ThinkingRow() }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear {
                // Open on the newest message; wait a beat for the first layout pass.
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.messages) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.isThinking) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField("Ask Clippy anything…", text: $model.input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Label("Ask", systemImage: "arrow.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isThinking
    }

    private func submit() {
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        model.input = ""
        model.onSubmit?(text)
    }
}

private struct MessageRow: View {
    let message: BubbleMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(SpeechBubble.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(SpeechBubble.userNote)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.25), lineWidth: 0.5))
                    )
            }
        case .clippy:
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(SpeechBubble.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.6, green: 0.2, blue: 0.0))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Clippy is thinking" with dots that fill in one at a time.
private struct ThinkingRow: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 4
            Text("Clippy is thinking" + String(repeating: ".", count: step))
                .font(.system(size: 12).italic())
                .foregroundStyle(SpeechBubble.ink.opacity(0.6))
        }
    }
}

/// Rounded rectangle with a tail pointing down toward the character.
struct BalloonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 8)
        let tailX = rect.maxX - 50
        p.move(to: CGPoint(x: tailX, y: rect.maxY - 0.5))
        p.addLine(to: CGPoint(x: tailX + 6, y: rect.maxY + 12))
        p.addLine(to: CGPoint(x: tailX + 16, y: rect.maxY - 0.5))
        return p
    }
}
