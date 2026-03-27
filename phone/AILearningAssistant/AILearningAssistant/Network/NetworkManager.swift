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
    case transportError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let urlString):
            return "无效的请求地址: \(urlString)"
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .serverError(_, let message):
            return message
        case .transportError(let message):
            return message
        }
    }
}

private extension NetworkError {
    static func userFriendlyServerMessage(statusCode: Int, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if lowered.contains("libreoffice") {
            return "后端暂时不能处理 Office 文档。请确认电脑上已安装 LibreOffice，并重启后端后再试。"
        }

        if lowered.contains("office 文件转 pdf 失败") {
            return "文档转换失败。请确认文件没有损坏，或换一个文件后再试。"
        }

        if lowered.contains("网络连接被中断") || lowered.contains("ssl") || lowered.contains("connectionpool") {
            return "文件已经在本地处理成功，但连接 Gemini 服务时中断了。请稍后重试，并检查当前网络或代理设置。"
        }

        if lowered.contains("文件类型与内容类型不匹配") {
            return "这个文件的类型和内容不匹配。请重新导出文件后再上传。"
        }

        if lowered.contains("文件过大") {
            return "文件太大了，请上传 20MB 以内的文件。"
        }

        if lowered.contains("暂不支持该文件类型上传") {
            return "当前还不支持这种文件类型。请换成 PDF、图片、音频或常见文档格式后再试。"
        }

        if statusCode >= 500 {
            return "后端处理这次请求时出了点问题，请稍后再试。"
        }

        return trimmed
    }

    static func userFriendlyTransportMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "当前设备没有联网，请检查网络后再试。"
        case .timedOut:
            return "请求超时了，请稍后再试。"
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return "暂时连不上本地后端服务，请确认后端已经启动。"
        default:
            return "网络连接异常，请检查当前网络和本地后端服务。"
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
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return try decodeResponse(data: data, response: response)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    private func send(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            return try decodeResponse(data: data, response: response)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    private func decodeResponse(data: Data, response: URLResponse) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            let serverMessage = apiError?.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackMessage = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            let rawMessage = (serverMessage?.isEmpty == false ? serverMessage! : fallbackMessage)
            let message = NetworkError.userFriendlyServerMessage(statusCode: httpResponse.statusCode, message: rawMessage)
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
    
    func uploadFile(data: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        let url = try makeURL(path: "/upload/file")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let validatedData = try decodeResponse(data: data, response: response)
            return try JSONDecoder().decode(UploadResponse.self, from: validatedData)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
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
