import SwiftUI

/// Shared by settings and onboarding; configuration changes discard stale results.
struct ModelCheckView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        ModelCheckControl(settings: settings)
            .id([settings.enhancementProvider.rawValue,
                 settings.currentEnhancementBaseURL,
                 settings.currentEnhancementModel,
                 settings.currentEnhancementApiKey])
    }
}

private struct ModelCheckControl: View {
    let settings: Settings
    @State private var task: Task<Void, Never>?
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(task == nil ? "Check" : "Checking…") {
                result = nil
                task = Task { @MainActor in
                    defer { task = nil }
                    do {
                        try await EnhancementService(settings: settings).checkModel()
                        try Task.checkCancellation()
                        succeeded = true
                        result = "Model responded successfully."
                    } catch {
                        guard !Task.isCancelled else { return }
                        succeeded = false
                        result = failureMessage(error)
                    }
                }
            }
            .controlSize(.small)
            .disabled(task != nil || settings.currentEnhancementModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send a small test request to this model. Provider usage charges may apply.")

            if let result {
                Text(result)
                    .font(.system(size: 10))
                    .foregroundStyle(succeeded ? Theme.statusGreen : Theme.statusRed)
                    .accessibilityLabel(result)
            }
        }
        .onDisappear { task?.cancel() }
    }

    // Do not display raw server messages, which may echo credentials or request data.
    private func failureMessage(_ error: Error) -> String {
        guard let error = error as? EnhancementError else {
            return "Check failed. Verify the endpoint and its response format."
        }
        switch error {
        case .noAPIKey: return "Enter an API key first."
        case .invalidBaseURL: return "Invalid API endpoint URL."
        case .networkTimeout: return "Request timed out. Try again."
        case .noContent: return "The model returned no text."
        case .httpError(401), .httpError(403): return "Access denied. Check the API key and model permissions."
        case .httpError(404): return "Model or endpoint not found."
        case .httpError(429): return "Rate limit or quota exceeded."
        case .httpError(let code): return "Request failed (HTTP \(code)). Check model compatibility."
        case .apiError: return "Could not connect. Check the endpoint and network."
        case .invalidResponse: return "The endpoint returned an invalid response."
        }
    }
}
