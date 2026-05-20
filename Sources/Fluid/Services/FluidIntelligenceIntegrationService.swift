import FluidIntelligence
import Foundation

actor FluidIntelligenceIntegrationService {
    static let shared = FluidIntelligenceIntegrationService()
    static let localModelPathDefaultsKey = "FluidIntelligenceLocalModelPath"

    struct RuntimeConfiguration: Sendable, Equatable {
        let selectedProviderID: String
        let providerKey: String
        let baseURL: String
        let model: String
        let apiKey: String
        let localModelPath: String?
    }

    struct AppContext: Sendable, Equatable {
        let appName: String
        let bundleID: String
        let windowTitle: String
        let appVersion: String?
    }

    struct EnhancementResult: Sendable, Equatable {
        let outputText: String
        let backendKind: String?
        let latencyMilliseconds: Int?
    }

    private var cachedRuntime: RuntimeConfiguration?
    private var cachedClient: (any FluidIntelligenceClient)?

    private init() {}

    nonisolated static var configuredLocalModelPath: String? {
        let value = UserDefaults.standard.string(forKey: Self.localModelPathDefaultsKey)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated static var isLocalRuntimeConfigured: Bool {
        self.configuredLocalModelPath != nil
    }

    nonisolated static func shouldHandleDictation(model: String) -> Bool {
        self.isLocalRuntimeConfigured || Fluid1PromptFormat.matches(model: model)
    }

    func status(for runtime: RuntimeConfiguration) async -> FluidIntelligenceStatus {
        do {
            return try await self.client(for: runtime).status()
        } catch {
            return FluidIntelligenceStatus(
                state: .failed,
                message: Self.errorMessage(for: error)
            )
        }
    }

    func enhanceDictation(
        _ inputText: String,
        runtime: RuntimeConfiguration,
        context: AppContext
    ) async throws -> EnhancementResult {
        let client = try self.client(for: runtime)
        let request = FluidIntelligenceRequest(
            task: .dictationEnhancement,
            inputText: inputText,
            context: FluidIntelligenceContext(
                localeIdentifier: Locale.current.identifier,
                activeAppBundleID: context.bundleID.isEmpty ? nil : context.bundleID,
                activeAppName: context.appName.isEmpty ? nil : context.appName,
                activeWindowTitle: context.windowTitle.isEmpty ? nil : context.windowTitle,
                appVersion: context.appVersion
            ),
            options: FluidIntelligenceRequestOptions(
                allowRemoteFallback: false,
                diagnosticsLevel: .summary,
                maxOutputTokens: 256
            )
        )

        let response = try await client.run(request)
        let backendKind = response.diagnostics.backendKind?.rawValue
        let latencyMilliseconds = response.diagnostics.latencyMilliseconds
        await MainActor.run {
            DebugLogger.shared.info(
                "FluidIntelligence completed dictation enhancement via \(backendKind ?? "unknown") in \(latencyMilliseconds ?? -1)ms",
                source: "FluidIntelligence"
            )
        }
        return EnhancementResult(
            outputText: response.outputText,
            backendKind: backendKind,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    private func client(for runtime: RuntimeConfiguration) throws -> any FluidIntelligenceClient {
        let normalized = Self.normalized(runtime)
        if let cachedRuntime, cachedRuntime == normalized, let cachedClient {
            return cachedClient
        }

        let client = try FluidIntelligenceFactory.makeClient(
            configuration: Self.backendConfiguration(for: normalized)
        )
        self.cachedRuntime = normalized
        self.cachedClient = client
        return client
    }

    private static func backendConfiguration(
        for runtime: RuntimeConfiguration
    ) throws -> FluidIntelligenceBackendConfiguration {
        if let modelPath = runtime.localModelPath, !modelPath.isEmpty {
            return .llamaSwift(
                LlamaSwiftRuntimeConfiguration(
                    modelPath: NSString(string: modelPath).expandingTildeInPath,
                    contextTokenLimit: LlamaSwiftRuntimeConfiguration.defaultContextTokenLimit,
                    batchTokenLimit: LlamaSwiftRuntimeConfiguration.defaultBatchTokenLimit
                )
            )
        }

        guard !runtime.model.isEmpty else {
            throw FluidIntelligenceError.invalidConfiguration("Fluid Intelligence model is not configured.")
        }

        guard let baseURL = URL(string: runtime.baseURL), baseURL.host != nil else {
            throw FluidIntelligenceError.invalidConfiguration("Fluid Intelligence endpoint is not configured.")
        }

        if !Self.isLocalEndpoint(baseURL), runtime.apiKey.isEmpty {
            throw AIProcessingError.missingAPIKey(provider: runtime.providerKey)
        }

        return .openAICompatible(
            OpenAICompatibleRuntimeConfiguration(
                baseURL: baseURL,
                model: runtime.model,
                apiKey: runtime.apiKey.isEmpty ? nil : runtime.apiKey,
                timeoutSeconds: 120
            )
        )
    }

    private static func normalized(_ runtime: RuntimeConfiguration) -> RuntimeConfiguration {
        RuntimeConfiguration(
            selectedProviderID: runtime.selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines),
            providerKey: runtime.providerKey.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: runtime.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: runtime.model.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: runtime.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            localModelPath: runtime.localModelPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }

        if host.hasPrefix("172.") {
            let components = host.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16,
               secondOctet <= 31
            {
                return true
            }
        }

        return false
    }

    private static func errorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return String(describing: error)
    }
}
