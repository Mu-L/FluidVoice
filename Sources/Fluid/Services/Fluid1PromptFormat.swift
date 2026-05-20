import Foundation

enum Fluid1PromptFormat {
    static let promptSelectionID = "__FLUID_1__"

    nonisolated static func matches(model: String) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compact = normalized
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        return compact.contains("fluid-1") || compact.contains("fluid1") || normalized.contains("fluid one")
    }

    static func isAvailable(settings: SettingsStore = .shared) -> Bool {
        self.matches(model: self.selectedDictationModel(settings: settings))
    }

    private static func selectedDictationModel(settings: SettingsStore) -> String {
        let providerID = settings.selectedProviderID
        let selectedModelByProvider = settings.selectedModelByProvider

        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            let key = "custom:\(saved.id)"
            return selectedModelByProvider[key] ?? saved.models.first ?? ""
        }

        if ModelRepository.shared.isBuiltIn(providerID) {
            return selectedModelByProvider[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? ""
        }

        return selectedModelByProvider[providerID] ?? ""
    }
}
