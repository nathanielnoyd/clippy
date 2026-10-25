import AppKit
import Security
import SwiftUI

/// What happens when you ask Clippy something.
enum Destination: String, CaseIterable, Identifiable {
    case balloon, shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balloon: return "Answer in the balloon"
        case .shortcut: return "Run a Shortcut"
        }
    }
}

/// Which model answers in the balloon.
enum Brain: String, CaseIterable, Identifiable {
    case jokes, appleIntelligence, server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jokes: return "Offline jokes"
        case .appleIntelligence: return "Apple Intelligence (on this Mac)"
        case .server: return "Model server (OpenAI-compatible)"
        }
    }
}

/// How Clippy answers. Choices live in UserDefaults; the API key in the Keychain.
struct AssistantSettings {
    private static let destinationKey = "assistantDestination"
    private static let brainKey = "assistantBrain"
    private static let legacyUseServerKey = "assistantUseServer"
    private static let serverURLKey = "assistantServerURL"
    private static let modelKey = "assistantModel"
    private static let shortcutKey = "assistantShortcut"
    private static let keychainAccount = "model-server-api-key"

    var destination = Destination.balloon
    var brain = Brain.jokes
    var serverURL = ""
    var model = ""
    var apiKey = ""
    var shortcutName = ""

    static func load() -> AssistantSettings {
        let d = UserDefaults.standard
        return AssistantSettings(
            destination: Destination(rawValue: d.string(forKey: destinationKey) ?? "") ?? .balloon,
            brain: Brain(rawValue: d.string(forKey: brainKey) ?? "")
                ?? (d.bool(forKey: legacyUseServerKey) ? .server : .jokes),
            serverURL: d.string(forKey: serverURLKey) ?? "",
            model: d.string(forKey: modelKey) ?? "",
            apiKey: Keychain.read(keychainAccount) ?? "",
            shortcutName: d.string(forKey: shortcutKey) ?? ""
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(destination.rawValue, forKey: Self.destinationKey)
        d.set(brain.rawValue, forKey: Self.brainKey)
        d.set(serverURL, forKey: Self.serverURLKey)
        d.set(model, forKey: Self.modelKey)
        d.set(shortcutName, forKey: Self.shortcutKey)
        Keychain.write(apiKey, account: Self.keychainAccount)
    }

    /// The model that answers in the balloon.
    func makeProvider() throws -> AssistantProvider {
        switch brain {
        case .jokes:
            return SatireProvider()
        case .appleIntelligence:
            guard #available(macOS 26, *) else {
                throw AppleIntelligenceError("Apple Intelligence needs macOS 26 or later.")
            }
            return AppleIntelligenceProvider()
        case .server:
            break
        }
        return OpenAICompatibleProvider(baseURL: try OpenAICompatibleProvider.normalize(serverURL),
                                        model: model, apiKey: apiKey.isEmpty ? nil : apiKey)
    }

    var summary: String {
        switch destination {
        case .balloon: return brain == .server ? "\(model) @ \(serverURL)" : brain.title
        case .shortcut: return "Shortcut “\(shortcutName)”"
        }
    }

    var isComplete: Bool {
        switch destination {
        case .balloon: return brain != .server || (!serverURL.isEmpty && !model.isEmpty)
        case .shortcut: return !shortcutName.isEmpty
        }
    }
}

enum Keychain {
    private static let service = "Clippy"

    static func read(_ account: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String, account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - Settings window

final class AssistantSettingsModel: ObservableObject {
    @Published var settings: AssistantSettings
    @Published var models: [String] = []
    @Published var shortcuts: [String] = []
    @Published var status = ""
    @Published var checking = false
    var onSave: ((AssistantSettings) -> Void)?
    var onCancel: (() -> Void)?

    init(_ settings: AssistantSettings) {
        self.settings = settings
    }

    @MainActor
    func check() async {
        checking = true
        status = "Connecting…"
        defer { checking = false }
        do {
            guard let provider = try settings.makeProvider() as? OpenAICompatibleProvider else { return }
            models = try await provider.listModels()
            if models.isEmpty {
                status = "Connected, but the server lists no models."
            } else {
                status = "Connected to \(provider.baseURL.absoluteString). \(models.count) model(s) available."
                if !models.contains(settings.model) { settings.model = models[0] }
            }
        } catch {
            status = "Couldn't connect: \(error.localizedDescription)"
        }
    }

    @MainActor
    func loadShortcuts() async {
        shortcuts = await ShortcutRunner.list()
    }
}

struct AssistantSettingsView: View {
    @ObservedObject var model: AssistantSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("When you ask Clippy", selection: $model.settings.destination) {
                ForEach(Destination.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Divider()

            switch model.settings.destination {
            case .balloon: balloonSection
            case .shortcut: shortcutSection
            }

            HStack {
                Spacer()
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.onSave?(model.settings) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.settings.isComplete)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var balloonSection: some View {
        Picker("Brain", selection: $model.settings.brain) {
            ForEach(Brain.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.radioGroup)

        if model.settings.brain == .appleIntelligence {
            if let reason = appleIntelligenceProblem {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Ready. Answers stay on this Mac.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            note("Apple's on-device model is free, private and works offline. It's smaller than most server models, so it's best for quick questions.")
        }

        if model.settings.brain == .server {
            Form {
                TextField("Server", text: $model.settings.serverURL, prompt: Text("http://192.168.1.20:11434"))
                HStack {
                    TextField("Model", text: $model.settings.model, prompt: Text("llama3.2"))
                    if !model.models.isEmpty {
                        Menu("Choose") {
                            ForEach(model.models, id: \.self) { id in
                                Button(id) { model.settings.model = id }
                            }
                        }
                        .fixedSize()
                    }
                }
                SecureField("API key", text: $model.settings.apiKey, prompt: Text("Optional"))
            }

            HStack {
                Button("Check Connection") { Task { await model.check() } }
                    .disabled(model.settings.serverURL.isEmpty || model.checking)
                if model.checking { ProgressView().controlSize(.small) }
            }
            if !model.status.isEmpty {
                note(model.status)
            }
            note("Works with Ollama (port 11434), LM Studio (1234), llama.cpp (8080), vLLM (8000) and other servers with an OpenAI-style API. For another machine, make sure the server listens on the network, not just localhost.")
        }

    }

    @ViewBuilder private var shortcutSection: some View {
        HStack {
            TextField("Shortcut", text: $model.settings.shortcutName, prompt: Text("Shortcut name"))
            if !model.shortcuts.isEmpty {
                Menu("Choose") {
                    ForEach(model.shortcuts, id: \.self) { name in
                        Button(name) { model.settings.shortcutName = name }
                    }
                }
                .fixedSize()
            }
        }
        .task { await model.loadShortcuts() }
        note("Your question is passed in as text. If the shortcut ends with text (for example from Apple Intelligence's “Use Model” action), it's shown in the balloon.")
    }

    private var appleIntelligenceProblem: String? {
        if #available(macOS 26, *) { return AppleIntelligenceProvider.unavailableReason }
        return "Apple Intelligence needs macOS 26 or later."
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
