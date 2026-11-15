import Foundation

// Minimal application stubs isolate the production service for network contract checks.
struct EnhancementProvider { var requiresApiKey = true }
enum TranslationTargetLanguage: String { case english = "English" }
enum DictationScene { case chat; var rules: String { "" } }
enum DictationSpelling { static let rules = "" }
enum DictationFormatting { static let rules = "" }
enum DictationContext { static func sanitize(_ text: String) -> String { text } }
enum VocabularyCorrections { static func relevantTerms(_ terms: [String], in text: String) -> [String] { terms } }
struct Entry { var pair: Pair }; struct Pair { var to: String }
class EditLearningStore { static let shared = EditLearningStore(); var entries = [Entry(pair: Pair(to: "PRIVATE_LEARNED"))] }
class Settings {
 static let shared = Settings(); static let defaultEnhancementPrompt = "PRIVATE_PROMPT"
 var enhancementEnabled = false; var enhancementProvider = EnhancementProvider()
 var currentEnhancementApiKey = "test-key"; var currentEnhancementBaseURL = "https://model-check.invalid/v1"
 var currentEnhancementModel = "gpt-6-luna"; var cursorContextEnabled = true; var allowCloudContext = true
 var customVocabularyTerms = ["PRIVATE_VOCABULARY"]; var enhancementPrompt = "PRIVATE_PROMPT"
}
struct OpenAIErrorResponse: Decodable { var error: Detail; struct Detail: Decodable { var message: String } }
func debugLog(_ text: String) { fatalError("Model check must not log responses") }
class MockProtocol: URLProtocol {
 static var status = 200
 static var body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Connection check.\"}}]}"
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  var data = request.httpBody ?? Data()
  if let stream = request.httpBodyStream {
   stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
   while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
  }
  let text = String(decoding: data, as: UTF8.self)
  precondition(!text.contains("PRIVATE_")); precondition(!text.contains("temperature"))
  precondition(text.contains("Connection check.")); precondition(request.url?.path == "/v1/chat/completions")
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data(Self.body.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Checks {
 static func main() async throws {
  URLProtocol.registerClass(MockProtocol.self)
  let service = EnhancementService()
  try await service.checkModel()
  MockProtocol.body = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\" \"}}]}"
  do { try await service.checkModel(); fatalError("Empty output accepted") } catch EnhancementError.noContent {}
  MockProtocol.status = 401; MockProtocol.body = "private server error"
  do { try await service.checkModel(); fatalError("HTTP failure accepted") } catch EnhancementError.httpError(401) {}
  MockProtocol.status = 200; MockProtocol.body = "{}"
  do { try await service.checkModel(); fatalError("Malformed response accepted") } catch is DecodingError {}
  print("Model check tests passed: success, empty output, HTTP failure, malformed response, and request privacy.")
 }
}
