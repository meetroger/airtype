import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT

@MainActor
enum MLXAudioRunner {
    private static let idleUnloadDelayNanoseconds: UInt64 = 60_000_000_000
    private static var loadedQwenModel: Qwen3ASRModel?
    private static var loadedModelID: String?
    private static var idleUnloadTask: Task<Void, Never>?

    static func installModel(modelID: String) async throws {
        if modelID.contains("Qwen3-ASR") {
            cancelIdleUnload()
            releaseLoadedModel(reason: "installing model")
            do {
                try await loadModelForInstallation(modelID: modelID)
                clearUnusedMemory(context: "after model installation")
            } catch {
                clearUnusedMemory(context: "after failed model installation")
                throw error
            }
            return
        }
        throw LocalMLXTranscriptionError.runtimeExecutionFailed("Unsupported model: \(modelID)")
    }

    static func removeModel(modelID: String) {
        if loadedModelID == modelID {
            cancelIdleUnload()
            releaseLoadedModel(reason: "removing model")
        }

        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface/hub/mlx-audio", isDirectory: true)
        let modelDir = cacheRoot?.appendingPathComponent(modelID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        if let modelDir {
            try? FileManager.default.removeItem(at: modelDir)
        }
    }

    static func transcribe(
        modelID: String,
        audioPath: String,
        languageCode: String?
    ) async throws -> String {
        cancelIdleUnload()

        do {
            let text = try await performTranscription(
                modelID: modelID,
                audioPath: audioPath,
                languageCode: languageCode
            )
            clearUnusedMemory(context: "after transcription")
            scheduleIdleUnload()
            return text
        } catch let error as LocalMLXTranscriptionError {
            clearUnusedMemory(context: "after failed transcription")
            scheduleIdleUnload()
            throw error
        } catch {
            clearUnusedMemory(context: "after failed transcription")
            scheduleIdleUnload()
            throw LocalMLXTranscriptionError.runtimeExecutionFailed(error.localizedDescription)
        }
    }

    private static func performTranscription(
        modelID: String,
        audioPath: String,
        languageCode: String?
    ) async throws -> String {
        guard modelID.contains("Qwen3-ASR") else {
            throw LocalMLXTranscriptionError.runtimeUnavailable(
                model: modelID,
                language: languageCode ?? "auto",
                computeMode: "balanced"
            )
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        let (_, audio) = try loadAudioArray(from: audioURL, sampleRate: 16_000)
        let model = try await qwenModel(for: modelID)
        let output = model.generate(audio: audio, language: normalizeLanguage(languageCode))
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw LocalMLXTranscriptionError.emptyRecording
        }
        return text
    }

    private static func qwenModel(for modelID: String) async throws -> Qwen3ASRModel {
        if loadedModelID == modelID, let loadedQwenModel {
            debugLog("Reusing loaded MLX model: \(modelID)")
            return loadedQwenModel
        }

        if loadedQwenModel != nil {
            releaseLoadedModel(reason: "switching model")
        }

        debugLog("Loading MLX model: \(modelID)")
        let model = try await Qwen3ASRModel.fromPretrained(modelID)
        loadedQwenModel = model
        loadedModelID = modelID
        clearUnusedMemory(context: "after loading model")
        return model
    }

    private static func loadModelForInstallation(modelID: String) async throws {
        _ = try await Qwen3ASRModel.fromPretrained(modelID)
    }

    private static func scheduleIdleUnload() {
        cancelIdleUnload()
        idleUnloadTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: idleUnloadDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            idleUnloadTask = nil
            releaseLoadedModel(reason: "60 seconds idle")
        }
    }

    private static func cancelIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private static func releaseLoadedModel(reason: String) {
        let releasedModelID = loadedModelID
        loadedQwenModel = nil
        loadedModelID = nil
        clearUnusedMemory(context: "after unloading model")
        if let releasedModelID {
            debugLog("Unloaded MLX model after \(reason): \(releasedModelID)")
        }
    }

    private static func clearUnusedMemory(context: String) {
        Memory.clearCache()
        let memory = Memory.snapshot()
        debugLog(
            "MLX memory \(context): active=\(formatMemory(memory.activeMemory)), "
                + "cache=\(formatMemory(memory.cacheMemory)), peak=\(formatMemory(memory.peakMemory))"
        )
    }

    private static func formatMemory(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    private static func normalizeLanguage(_ languageCode: String?) -> String? {
        guard let code = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !code.isEmpty else {
            return nil
        }

        switch code {
        case "en", "english":
            return "English"
        case "zh", "zh-cn", "chinese":
            return "Chinese"
        default:
            return languageCode
        }
    }
}
