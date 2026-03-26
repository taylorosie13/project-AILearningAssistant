import Foundation

enum AppConfiguration {
    static let defaultBaseURL = "http://localhost:8000"

    static var apiBaseURL: String {
        let configuredURL = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let trimmedURL = configuredURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedURL.isEmpty ? defaultBaseURL : trimmedURL
    }
}

struct APIErrorResponse: Decodable {
    let detail: String
}

struct MessageResponse: Decodable {
    let message: String
}

struct ChatRequestBody: Encodable {
    let prompt: String
    let session_id: String?
    let file_paths: [String]?
}

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let urlString):
            return "无效的请求地址: \(urlString)"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .serverError(_, let message):
            return message
        }
    }
}

class NetworkManager {
    static let shared = NetworkManager()
    let baseURL: String

    private init(baseURL: String = AppConfiguration.apiBaseURL) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func makeURL(path: String) throws -> URL {
        let urlString = "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        return url
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func send(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        return try decodeResponse(data: data, response: response)
    }

    private func decodeResponse(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let serverMessage = apiError?.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackMessage = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            let message = (serverMessage?.isEmpty == false ? serverMessage! : fallbackMessage)
            throw NetworkError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }
    
    func sendMessage(prompt: String, sessionId: String?, filePaths: [String]?) async throws -> ChatResponse {
        let url = try makeURL(path: "/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequestBody(
                prompt: prompt,
                session_id: sessionId,
                file_paths: filePaths?.isEmpty == true ? nil : filePaths
            )
        )

        let data = try await send(request)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
    
    func uploadFile(imageData: Data, fileName: String) async throws -> UploadResponse {
        let url = try makeURL(path: "/upload/file")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let validatedData = try decodeResponse(data: data, response: response)
    
        return try JSONDecoder().decode(UploadResponse.self, from: validatedData)
    }

    func getSessions() async throws -> [ChatSession] {
        let url = try makeURL(path: "/sessions")
        let data = try await send(from: url)
        return try JSONDecoder().decode([ChatSession].self, from: data)
    }
    
    func getSessionMessages(sessionId: String) async throws -> [ChatMessage] {
        let url = try makeURL(path: "/sessions/\(sessionId)/messages")
        let data = try await send(from: url)
        return try JSONDecoder().decode([ChatMessage].self, from: data)
    }
    
    func deleteSession(sessionId: String) async throws {
        let url = try makeURL(path: "/sessions/\(sessionId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        _ = try await send(request)
    }

    // MARK: - 知识卡片 API
    func fetchKnowledgeCards() async throws -> [KnowledgeCard] {
        let url = try makeURL(path: "/cards")
        let data = try await send(from: url)
        return try JSONDecoder().decode([KnowledgeCard].self, from: data)
    }

    func createKnowledgeCard(card: KnowledgeCardCreate) async throws -> String {
        let url = try makeURL(path: "/cards")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(card)

        let data = try await send(request)
        let response = try JSONDecoder().decode(MessageResponse.self, from: data)
        return response.message
    }

    func deleteKnowledgeCard(cardId: Int) async throws {
        let url = try makeURL(path: "/cards/\(cardId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        _ = try await send(request)
    }

    func updateKnowledgeCard(cardId: Int, card: KnowledgeCardUpdate) async throws -> String {
        let url = try makeURL(path: "/cards/\(cardId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(card)

        let data = try await send(request)
        let response = try JSONDecoder().decode(MessageResponse.self, from: data)
        return response.message
    }
}
