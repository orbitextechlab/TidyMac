import Foundation

/// Persistence for user-saved fan presets. Built-in presets are generated from
/// the machine's actual fans and are never stored — only what the user saves.
@MainActor
final class FanPresetStore: ObservableObject {

    @Published private(set) var saved: [FanPreset] = []

    private static let defaultsKey = "fanPresets"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([FanPreset].self, from: data) {
            saved = decoded
        }
    }

    /// Built-ins first, then anything the user saved.
    func all(for fans: [SensorService.Fan]) -> [FanPreset] {
        FanPreset.builtIns(for: fans) + saved
    }

    /// Save the current settings under a name, replacing a same-named preset.
    func save(name: String, settings: [Int: FanSettings]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saved.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        saved.append(FanPreset(name: trimmed, systemImage: "bookmark.fill", settings: settings))
        persist()
    }

    func delete(_ preset: FanPreset) {
        saved.removeAll { $0.id == preset.id }
        persist()
    }

    /// User presets can be deleted; built-ins cannot.
    func isUserPreset(_ preset: FanPreset) -> Bool {
        saved.contains { $0.id == preset.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
