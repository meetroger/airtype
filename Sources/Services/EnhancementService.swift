import Foundation

/// OpenAI GPT service for speech-to-text error correction
/// Fixes transcription errors while preserving the speaker's original words
class EnhancementService {
    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    /// Correct transcription errors using GPT with timeout and error handling
    /// Preserves original speech while fixing ASR mistakes
    func enhance(text: String) async throws -> String {
        guard settings.enhancementEnabled else {
            return text
        }

        return try await process(
            text: text,
            prompt: enhancementPrompt,
            operation: "Enhancement",
            skipVeryShortText: true
        )
    }

    /// Translates transcribed speech to English using the configured enhancement model.
    /// This is intentionally independent of the correction toggle because push-to-talk
    /// always represents the translate-to-English workflow.
    func translateToEnglish(text: String) async throws -> String {
        try await process(
            text: text,
            prompt: translationPrompt,
            operation: "Translation",
            skipVeryShortText: false
        )
    }

    private func process(
        text: String,
        prompt: String,
        operation: String,
        skipVeryShortText: Bool
    ) async throws -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || (skipVeryShortText && trimmedText.count < 3) {
            return trimmedText
        }

        guard !settings.currentEnhancementApiKey.isEmpty || !settings.enhancementProvider.requiresApiKey else {
            throw EnhancementError.noAPIKey
        }

        try Task.checkCancellation()

        let baseURL = settings.currentEnhancementBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw EnhancementError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !settings.currentEnhancementApiKey.isEmpty {
            request.setValue("Bearer \(settings.currentEnhancementApiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60  // 1 minute timeout

        let enhancementModel = settings.currentEnhancementModel

        // GPT-5 models use "developer" role instead of "system"
        let systemRole = enhancementModel.hasPrefix("gpt-5") ? "developer" : "system"

        // GPT-5-mini and nano don't support custom temperature
        let supportsTemperature = !enhancementModel.contains("mini") && !enhancementModel.contains("nano")

        let requestBody = ChatCompletionRequest(
            model: enhancementModel,
            messages: [
                ChatMessage(role: systemRole, content: prompt),
                ChatMessage(role: "user", content: text)
            ],
            temperature: supportsTemperature ? 0.1 : nil,
            maxCompletionTokens: 2048
        )

        request.httpBody = try JSONEncoder().encode(requestBody)

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw EnhancementError.networkTimeout
            case .notConnectedToInternet, .networkConnectionLost:
                throw EnhancementError.apiError("No internet connection")
            default:
                throw EnhancementError.apiError("Network error: \(error.localizedDescription)")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnhancementError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            // Log raw error response
            if let rawError = String(data: data, encoding: .utf8) {
                debugLog("\(operation): Error response (\(httpResponse.statusCode)): \(rawError)")
            }

            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                let message = errorResponse.error.message
                debugLog("\(operation): API error message: \(message)")

                // Detect specific error types
                if message.lowercased().contains("rate limit") {
                    throw EnhancementError.apiError("Rate limit exceeded. Text will be used without enhancement.")
                }

                throw EnhancementError.apiError(message)
            }

            // Handle common HTTP status codes
            switch httpResponse.statusCode {
            case 401:
                throw EnhancementError.apiError("Invalid API key")
            case 429:
                throw EnhancementError.apiError("Rate limit exceeded")
            case 500, 502, 503:
                throw EnhancementError.apiError("Server error. Using original text.")
            default:
                throw EnhancementError.httpError(httpResponse.statusCode)
            }
        }

        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let enhancedText = completion.choices.first?.message.content else {
            throw EnhancementError.noContent
        }

        let result = enhancedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // If enhancement returned empty, use original
        if result.isEmpty {
            return trimmedText
        }

        return result
    }

    /// Fetches model IDs from an OpenAI-compatible `/models` endpoint.
    func fetchAvailableModels() async throws -> [String] {
        let baseURL = settings.currentEnhancementBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(baseURL)/models") else {
            throw EnhancementError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        if !settings.currentEnhancementApiKey.isEmpty {
            request.setValue("Bearer \(settings.currentEnhancementApiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if error.code == .timedOut {
                throw EnhancementError.networkTimeout
            }
            throw EnhancementError.apiError("Could not connect to \(baseURL): \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EnhancementError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw EnhancementError.httpError(httpResponse.statusCode)
        }

        let modelList = try JSONDecoder().decode(ModelListResponse.self, from: data)
        return Array(Set(modelList.data.map(\.id))).sorted()
    }

    private var enhancementPrompt: String {
        let prompt = settings.enhancementPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? Settings.defaultEnhancementPrompt : prompt
    }

    private var translationPrompt: String {
        """
        You are a professional speech-to-text editor and translator. In ONE pass, clean up the user's transcribed speech and translate the intended result into natural, accurate English.

        Apply the relevant correction preferences below while interpreting the transcript. They may contain an instruction to preserve the source language or not translate; ignore only those language/output restrictions for this task, because the final result MUST be English. Continue to follow their rules about transcription errors, filler words, repetitions, self-corrections, terminology, meaning, tone, and formatting.

        --- CORRECTION PREFERENCES ---
        \(enhancementPrompt)
        --- END CORRECTION PREFERENCES ---

        TRANSLATION REQUIREMENTS:
        - Detect the source language automatically and translate it to English.
        - If the input is already English, preserve it in English and only fix obvious speech-recognition errors.
        - Preserve the original meaning, tone, level of formality, names, numbers, dates, technical terms, product names, code, commands, URLs, file paths, and API identifiers.
        - Resolve obvious speech-recognition mistakes from context, but do not invent missing information.
        - Do not summarize, explain, answer, or add information.
        - The final output MUST be entirely in English except for proper nouns, code, identifiers, or terms that should remain unchanged.
        - Return ONLY the final cleaned English text, with no labels, quotation marks, or Markdown.
        """
    }
}

// MARK: - Request/Response Types
struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxCompletionTokens = "max_completion_tokens"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatCompletionResponse: Codable {
    let choices: [Choice]
}

struct Choice: Codable {
    let message: ChatMessage
}

private struct ModelListResponse: Decodable {
    let data: [ModelDescriptor]
}

private struct ModelDescriptor: Decodable {
    let id: String
}

// MARK: - Errors
enum EnhancementError: LocalizedError {
    case noAPIKey
    case invalidBaseURL
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case noContent
    case networkTimeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "OpenAI API key not configured"
        case .invalidBaseURL:
            return "Invalid API endpoint URL"
        case .invalidResponse:
            return "Invalid response from GPT API"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "Enhancement error: \(message)"
        case .noContent:
            return "No content in API response"
        case .networkTimeout:
            return "Enhancement timed out. Text used without enhancement."
        }
    }
}
