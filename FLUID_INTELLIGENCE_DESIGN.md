# Fluid Intelligence PRD

## Summary

Fluid Intelligence is the local model runtime layer for FluidVoice. FluidVoice
should capture audio, produce raw transcript text, know which user workflow is
running, and display the result. Fluid Intelligence should own everything about
turning that raw text into an intelligence result: prompt selection, chat
template, backend selection, model loading, decoding defaults, diagnostics, and
runtime failures.

The goal is a hard API boundary. A change to prompts, model format, runtime
backend, quantization, or Fluid-1-specific behavior should not require FluidVoice
UI or workflow code to change.

## Decision

Create a Swift package/framework named `FluidIntelligence`.

FluidVoice depends only on the public API:

- `FluidIntelligenceClient`
- task enums
- request/response structs
- capability/status structs
- typed errors

FluidVoice must not depend on:

- Fluid-1 model-name matching
- Fluid-1 prompt text
- GGUF, MLX, Core ML, llama.cpp, or LM Studio details
- provider-specific message formatting
- generation parameters such as temperature, top-p, stop tokens, or chat template

## Product Goal

Make FluidVoice able to use Fluid-1 and future local intelligence models without
coupling the app to any specific model, prompt, runtime, or serving stack.

The first user-visible workflow is dictation enhancement:

1. FluidVoice records audio.
2. FluidVoice transcribes speech to raw text.
3. FluidVoice sends `task = dictationEnhancement` and `inputText = raw text` to
   Fluid Intelligence.
4. Fluid Intelligence runs the model using its internal prompt/runtime contract.
5. FluidVoice receives final cleaned text plus diagnostics.
6. FluidVoice inserts text, updates history, and shows success or failure.

That is the intended ownership split.

## Non-Goals

- Do not make FluidVoice a model host.
- Do not make FluidVoice understand Fluid-1 internals.
- Do not expose backend-specific settings directly in normal FluidVoice UI.
- Do not make model-name strings control product behavior long term.
- Do not require a local model to ship in the first integration milestone.
- Do not rewrite command mode or rewrite mode until dictation enhancement is
  stable through the new API.

## Current State

The current branch has moved the Fluid-1 runtime path behind the
`FluidIntelligenceIntegrationService` bridge:

- `Sources/Fluid/Services/Fluid1PromptFormat.swift` only keeps the temporary
  Fluid-1 UI/test selection marker and model-name shim.
- The Fluid-1 default dictation prompt lives in the sibling FluidIntelligence
  package resources.
- `ContentView.processTextWithAI(...)` sends dictation text to
  `FluidIntelligenceClient.run(.dictationEnhancement)` for Fluid Intelligence
  routes.
- `DictationPostProcessingService.process(...)` uses the same bridge for local
  API post-processing.
- Settings and overlay UI still show Fluid-1 as a temporary prompt profile and
  lock normal prompt choices while a Fluid-1 model is selected.

The remaining FluidVoice-side model-name check is a compatibility shim for the
current Fluid-1 test path. The long-term migration target is capability gating
from FluidIntelligence instead of model-name gating in FluidVoice UI.

## Problem

FluidVoice currently owns decisions that belong to the model runtime layer:

- Which prompt profile is valid for a model.
- Whether a model should use a system prompt or a folded user message.
- Which selected model names imply special behavior.
- Which decoding defaults are safe.
- Which provider/backend is active.
- Which runtime errors are model errors versus app configuration errors.

That means a Fluid-1 model update can force FluidVoice changes. It also means
future backends can leak into app code.

## Target Architecture

```text
FluidVoice
  records audio
  transcribes audio
  resolves user workflow
  sends task request
  displays result
  stores history/settings

        stable Swift API
              |
              v

FluidIntelligence
  validates capability
  selects prompt/template
  selects model profile
  selects backend
  loads model/session
  runs generation
  returns structured result

        internal backend API
              |
      -------------------
      |        |        |
   GGUF     MLX    OpenAI-compatible
 llama.cpp         LM Studio/llama-server
```

FluidVoice should see the runtime as a service, not as a provider/model/prompt
matrix.

## Ownership Boundary

### FluidVoice Owns

- Audio capture.
- ASR/transcription provider selection.
- User mode: dictation, rewrite, command, prompt test.
- Recording slot and hotkey behavior.
- Active app/window context collection.
- UI state: recording, processing, retry, error display.
- History write and replay behavior.
- User-facing settings for enabling/disabling Fluid Intelligence.
- Privacy copy and local/remote disclosure.

### Fluid Intelligence Owns

- Task-specific prompt text.
- Prompt versioning.
- Chat template and message shape.
- Whether transcript goes in `system`, `user`, or a model-specific template.
- Model profile and capability map.
- Backend choice: OpenAI-compatible, GGUF, MLX, Core ML, Foundation Models.
- Model load/unload and warmup.
- Context length, temperature, top-p, stop tokens, max output tokens.
- Structured diagnostics.
- Runtime-specific error mapping.

## Public API Sketch

The API should be small and task-first.

```swift
public enum FluidIntelligenceTask: String, Sendable, Codable, Hashable {
    case dictationEnhancement
    case rewrite
    case command
}

public enum FluidIntelligenceDiagnosticsLevel: String, Sendable, Codable {
    case off
    case summary
    case debug
}

public struct FluidIntelligenceRequest: Sendable, Codable {
    public var task: FluidIntelligenceTask
    public var inputText: String
    public var context: FluidIntelligenceContext
    public var options: FluidIntelligenceRequestOptions
}

public struct FluidIntelligenceContext: Sendable, Codable {
    public var localeIdentifier: String?
    public var activeAppBundleID: String?
    public var activeAppName: String?
    public var activeWindowTitle: String?
    public var selectedText: String?
    public var appVersion: String?
}

public struct FluidIntelligenceRequestOptions: Sendable, Codable {
    public var allowRemoteFallback: Bool
    public var diagnosticsLevel: FluidIntelligenceDiagnosticsLevel
}

public struct FluidIntelligenceResponse: Sendable, Codable {
    public var outputText: String
    public var task: FluidIntelligenceTask
    public var diagnostics: FluidIntelligenceDiagnostics
}

public protocol FluidIntelligenceClient: Sendable {
    func capabilities() async -> FluidIntelligenceCapabilities
    func status() async -> FluidIntelligenceStatus
    func run(_ request: FluidIntelligenceRequest) async throws -> FluidIntelligenceResponse
}
```

FluidVoice should construct a request and call `run`. It should not construct LLM
messages for Fluid Intelligence tasks.

## Capability Model

Replace model-name gating with capability gating.

```swift
public enum FluidIntelligenceBackendKind: String, Sendable, Codable, Hashable {
    case openAICompatible
    case ggufLlamaCpp
    case mlxSwift
    case coreML
    case foundationModels
}

public struct FluidIntelligenceCapabilities: Sendable, Codable {
    public var isAvailable: Bool
    public var supportedTasks: Set<FluidIntelligenceTask>
    public var activeProfileID: String?
    public var activeBackendKind: FluidIntelligenceBackendKind?
    public var supportsLocalOnly: Bool
    public var supportsStreaming: Bool
}
```

FluidVoice asks:

- Is Fluid Intelligence available?
- Does it support `.dictationEnhancement`?
- Is local-only mode required by the user?
- Is the runtime ready, loading, missing model, or failed?

FluidVoice does not ask:

- Is the selected model named Fluid-1?
- Which prompt should I use?
- Which chat template does this model need?

## Runtime Status

Status should be explicit enough for UI and debugging.

```swift
public enum FluidIntelligenceRuntimeState: String, Sendable, Codable {
    case unavailable
    case disabled
    case missingModel
    case loading
    case warming
    case ready
    case failed
}

public struct FluidIntelligenceStatus: Sendable, Codable {
    public var state: FluidIntelligenceRuntimeState
    public var message: String?
    public var activeProfileID: String?
    public var activeModelIdentifier: String?
    public var activeBackendKind: FluidIntelligenceBackendKind?
}
```

FluidVoice maps this to simple UI states:

- Ready: use Fluid Intelligence.
- Loading/warming: show processing/loading state.
- Missing model: show setup state.
- Failed: show concise error and fallback behavior.
- Disabled/unavailable: use existing non-Fluid path.

## Prompt Policy

For now, every request that goes through Fluid Intelligence should use the
default Fluid-1 dictation prompt unless explicitly changed later.

Prompt ownership:

- Source of truth should move out of FluidVoice.
- Recommended package path:
  `FluidIntelligence/Sources/FluidIntelligence/Resources/Prompts/fluid1_dictation_default.md`
- Swift should expose it through an internal prompt registry, not through
  FluidVoice.
- A compiled fallback constant is acceptable so the app can still run if resource
  loading fails.
- Prompt versions should be tracked in diagnostics.

Example internal shape:

```swift
enum PromptProfileID: String, Sendable, Codable {
    case fluid1DictationDefault = "fluid1.dictation.default"
}

struct PromptProfile: Sendable, Codable {
    var id: PromptProfileID
    var version: String
    var task: FluidIntelligenceTask
    var systemPrompt: String
    var userTemplate: String
}
```

For the first milestone:

- `task = .dictationEnhancement`
- `systemPrompt = Fluid-1 default prompt`
- `userTemplate = "{transcript}"`
- transcript is sent as raw user text
- temperature is `0`

## Backend Strategy

### Backend 0: OpenAI-Compatible Adapter

Use this first to prove the API boundary. It can call LM Studio, `llama-server`,
or another local OpenAI-compatible endpoint.

Why first:

- Fastest path.
- Matches current testing setup.
- Allows prompt/API validation before embedding a model runtime.
- Keeps FluidVoice decoupled immediately.

This backend is not the final runtime. It is the integration bridge.

### Backend 1: GGUF / llama.cpp

This should be the first serious local runtime target.

Why:

- C/C++ backend is acceptable.
- GGUF quantization is mature.
- llama.cpp supports Apple Silicon Metal and many quantization levels.
- Existing `llama-server` can also preserve the OpenAI-compatible path during
  development.
- Swift can integrate either through a binary `.xcframework`, a C bridge, or an
  embedded process boundary.

Preferred path:

1. Keep OpenAI-compatible `llama-server` for early validation.
2. Add an in-process or packaged `llama.cpp` backend later.
3. Use GGUF model profiles with explicit quantization and memory requirements.

### Backend 2: MLX Swift

MLX Swift is a strong Apple Silicon path, especially if the model is converted
and packaged specifically for MLX.

Why not first:

- More model-format-specific.
- More custom packaging and tokenizer work.
- Apple Silicon focused; weaker fallback story for Intel Macs.

Use MLX as a performance experiment after the API is stable.

### Backend 3: Core ML

Core ML is a future polished Apple-native deployment path, not the first path.

Why later:

- Conversion and optimization complexity is higher.
- LLM performance depends heavily on quantization, stateful KV cache, tensor
  shape choices, and device-specific profiling.
- It may be the best shipping path later, but it is not the fastest way to prove
  product behavior.

### Backend 4: Foundation Models

Foundation Models can be a fallback or separate task provider on macOS 26+.

It should not be treated as Fluid-1 runtime because it runs Apple's on-device
model, not our custom model. It can still fit behind the same backend interface
for generic rewrite/command tasks if useful.

## Backend Interface

Backends stay internal.

```swift
protocol FluidModelBackend: Sendable {
    var kind: FluidIntelligenceBackendKind { get }
    func capabilities() async -> FluidIntelligenceBackendCapabilities
    func load(profile: FluidModelProfile) async throws
    func generate(_ request: FluidModelRequest) async throws -> FluidModelResponse
}
```

FluidVoice should never import or reference these backend types directly.

## Model Profiles

Fluid Intelligence should describe models with profiles, not app settings.

```swift
struct FluidModelProfile: Sendable, Codable {
    var id: String
    var displayName: String
    var modelIdentifier: String
    var backendKind: FluidIntelligenceBackendKind
    var supportedTasks: Set<FluidIntelligenceTask>
    var promptProfileID: String
    var defaultGeneration: FluidGenerationDefaults
    var localArtifact: FluidModelArtifact?
}
```

Profiles allow the model to change without FluidVoice changes.

Examples:

- `fluid1.local.gguf.q4`
- `fluid1.local.gguf.q8`
- `fluid1.local.mlx.4bit`
- `fluid1.remote.openai-compatible.dev`

## Diagnostics

Diagnostics must make runtime behavior provable without exposing internals to
normal users.

```swift
public struct FluidIntelligenceDiagnostics: Sendable, Codable {
    public var requestID: String
    public var task: FluidIntelligenceTask
    public var backendKind: FluidIntelligenceBackendKind
    public var modelProfileID: String
    public var modelIdentifier: String
    public var promptProfileID: String
    public var promptVersion: String
    public var usedSystemPrompt: Bool
    public var usedUserTemplate: Bool
    public var inputCharacterCount: Int
    public var outputCharacterCount: Int
    public var loadState: FluidIntelligenceRuntimeState
    public var latencyMilliseconds: Int?
    public var tokenCount: Int?
}
```

Debug logs should answer:

- Which task ran?
- Which backend ran?
- Which model profile ran?
- Which prompt version ran?
- Was the transcript raw user text or template-wrapped?
- Did failure happen before load, during load, during generation, or parsing?

## Error Model

Use typed errors so FluidVoice can show correct UI.

```swift
public enum FluidIntelligenceError: Error, Sendable {
    case unavailable(reason: String)
    case disabled
    case unsupportedTask(FluidIntelligenceTask)
    case missingModel(profileID: String)
    case modelLoadFailed(profileID: String, reason: String)
    case generationFailed(reason: String)
    case emptyResponse
    case cancelled
}
```

FluidVoice behavior:

- Empty input returns empty output.
- Missing model should show setup guidance, not pretend AI succeeded.
- Runtime failure should preserve raw transcript and record the AI error path.
- User cancellation should not create scary errors.
- If fallback is used, diagnostics should say fallback happened.

## Integration Points In FluidVoice

Initial integration should be narrow:

- `DictationPostProcessingService.process(...)` becomes the main service bridge.
- `ContentView.processTextWithAI(...)` should stop owning Fluid-1 prompt logic for
  dictation once the bridge is live.
- `DictationAIPostProcessingGate` should move from model-name checks to
  capability checks.
- Settings/overlay UI should show "Fluid Intelligence" availability, not a
  fake prompt profile named Fluid-1.
- Existing prompt editor remains for non-Fluid providers until migrated.

First bridge behavior:

```text
raw transcript
  -> DictationPostProcessingService
  -> FluidIntelligenceClient.run(.dictationEnhancement)
  -> response.outputText
  -> ASRService.applyGAAVFormatting(...)
  -> insert/history
```

Current implementation notes:

- FluidVoice links the sibling Swift package at `../FluidIntelligence`.
- FluidVoice imports Fluid Intelligence only in
  `Sources/Fluid/Services/FluidIntelligenceIntegrationService.swift`.
- Live dictation and local API post-processing call the bridge for Fluid-1.
- The bridge returns a local result type so FluidVoice callers do not handle
  Fluid Intelligence runtime structs directly.
- The default Fluid-1 prompt lives in the FluidIntelligence package resources,
  not in FluidVoice.

Runtime selection for this milestone:

- If `UserDefaults` key `FluidIntelligenceLocalModelPath` is set, the bridge
  uses the in-process `llama.swift` GGUF runtime.
- A configured local model path also lets dictation AI run without a verified
  remote provider because no API key or server is needed.
- If no local model path is set, the bridge uses the selected OpenAI-compatible
  provider/model for the current Fluid-1 test path.
- Public source builds without API keys or bundled models. No secret is checked
  into the repo.
- The app bundle embeds `llama.framework` through SwiftPM, so a DMG/app build can
  carry the runtime. The GGUF model file remains external until a locked model URL
  and checksum are chosen.

## Package Shape

The first implementation uses a sibling package for speed, then can move to a
separate repo or binary framework when stable.

Recommended first structure:

```text
Packages/
  FluidIntelligence/
    Package.swift
    Sources/
      FluidIntelligence/
        FluidIntelligenceClient.swift
        FluidIntelligenceTypes.swift
        FluidIntelligenceRuntime.swift
        Prompts/
          PromptRegistry.swift
          fluid1_dictation_default.md
        Backends/
          OpenAICompatibleBackend.swift
          GGUFBackend.swift
          MLXBackend.swift
          CoreMLBackend.swift
        Profiles/
          FluidModelProfile.swift
```

The package can later become:

- a separate source package, or
- a closed binary `.xcframework`, without changing the FluidVoice call site.

## Migration Plan

### Phase 0: Document And Freeze Boundary

- Agree that FluidVoice only sends task/input/context.
- Keep current Fluid-1 test shim working.
- Do not expand Fluid-1 app-specific logic.

### Phase 1: Add Package And OpenAI-Compatible Backend

- Add `FluidIntelligence` package in-repo.
- Move Fluid-1 prompt into package resources.
- Implement `OpenAICompatibleBackend`.
- Keep LM Studio / llama-server as the first backend.
- Make dictation enhancement use the package path.
- Add diagnostics.

### Phase 2: Replace Model-Name Gating

- Add `capabilities()` and `status()`.
- Replace `Fluid1PromptFormat.matches(...)` checks in FluidVoice.
- UI gates on `.supports(.dictationEnhancement)` and runtime status.
- Keep old path behind a temporary fallback until verified.

### Phase 3: GGUF Local Runtime

- Add GGUF model profile support.
- Choose process boundary versus in-process C bridge.
- Start with Q4/Q5/Q8 profiles for 2B/4B/8B testing.
- Benchmark load time, first-token latency, tokens/sec, memory, and quality.

### Phase 4: MLX Experiment

- Add MLX backend behind the same backend protocol.
- Compare with GGUF on the same benchmark set.
- Keep it only if it clearly improves latency, memory, packaging, or quality.

### Phase 5: Core ML Evaluation

- Convert one candidate model.
- Test int4/stateful KV cache path.
- Compare with GGUF and MLX on real FluidVoice dictation workloads.

## Verification Plan

Before replacing the current path:

- Unit-test request construction: FluidVoice never builds Fluid-1 messages.
- Unit-test capability gating.
- Unit-test missing model, disabled runtime, unsupported task, empty response.
- Smoke-test OpenAI-compatible endpoint with `Fluid-1`.
- Verify retry/reprocess uses the same Fluid Intelligence path.
- Verify history records final text and AI error behavior correctly.
- Verify prompt diagnostics show the expected prompt profile/version.
- Run `sh build_incremental.sh` for FluidVoice changes.

Before commit-ready code:

```sh
swiftformat --config .swiftformat Sources
swiftlint --strict --config .swiftlint.yml Sources/
sh build_incremental.sh
```

## Performance Requirements

Target behavior for local dictation enhancement:

- Keep FluidVoice main thread free.
- Avoid extra app-level background servers unless a backend explicitly requires a
  process boundary during development.
- Reuse loaded model/session when possible.
- Warm lazily or during app/process lifecycle when enabled.
- Keep diagnostics cheap and string-light in normal mode.
- Support low-memory devices with smaller quantized profiles.
- Make local-only mode explicit.

Initial target ranges to measure, not promise:

- 2B model: fastest default candidate.
- 4B model: quality/performance middle.
- 8B model: quality candidate for higher-memory Macs.
- Q4_K_M or similar: default memory-friendly GGUF test.
- Q8 or f16: quality comparison only, not low-resource default.

## Privacy And Security

- Default product direction should be local-first.
- If `allowRemoteFallback = false`, no remote backend may run.
- If OpenAI-compatible backend points at localhost, treat as local.
- If endpoint is not local, FluidVoice UI must disclose remote processing.
- API keys and endpoint secrets stay in FluidVoice settings until a separate
  secure runtime configuration exists.
- Diagnostics must not log full transcript by default.
- Prompt trace mode may log full input/output only when explicitly enabled.

## Acceptance Criteria

The first integration is correct when:

- FluidVoice calls one Fluid Intelligence API for dictation enhancement.
- FluidVoice passes raw transcript and lightweight context only.
- FluidVoice does not import or reference Fluid-1 prompt text.
- FluidVoice does not decide Fluid-1 chat formatting.
- FluidVoice does not gate behavior on model-name strings.
- Fluid Intelligence reports capabilities and status.
- Fluid Intelligence owns the default Fluid-1 prompt.
- Changing prompt/backend/model profile does not require FluidVoice UI changes.
- Existing dictation retry/reprocess still uses the same enhancement path.
- Failures preserve raw transcript and expose clear diagnostics.

## Risks

- OpenAI-compatible backend can hide issues that appear in embedded runtimes.
- llama.cpp APIs and packaging can change.
- MLX may outperform GGUF but cost more package/model conversion work.
- Core ML may be fastest later but slowest to iterate now.
- Prompt version drift can make history replay appear inconsistent.
- If capability checks are too vague, FluidVoice may still leak runtime logic.

## Open Questions

- Should Fluid Intelligence live in-repo for one release before splitting?
- Should the first GGUF backend be embedded in-process or launched as a helper?
- Which model size is the default target: 2B, 4B, or 8B?
- What is the minimum supported macOS version for local Fluid Intelligence?
- Should model download/update belong to FluidVoice UI or Fluid Intelligence?
- Should diagnostics be user-visible, debug-only, or both?

## Runtime References

- `llama.cpp`: C/C++ local inference, GGUF, Apple Silicon Metal, quantization,
  OpenAI-compatible `llama-server`: https://github.com/ggml-org/llama.cpp
- `MLX Swift`: Swift API for MLX on Apple Silicon:
  https://github.com/ml-explore/mlx-swift
- `MLX Swift LM`: Swift LLM/VLM package for MLX:
  https://github.com/ml-explore/mlx-swift-lm
- `Core ML`: on-device model runtime with compression, stateful models, and
  transformer support: https://developer.apple.com/machine-learning/core-ml/
- Apple Core ML Llama 3.1 8B optimization writeup:
  https://machinelearning.apple.com/research/core-ml-on-device-llama
- Foundation Models framework:
  https://developer.apple.com/documentation/FoundationModels
