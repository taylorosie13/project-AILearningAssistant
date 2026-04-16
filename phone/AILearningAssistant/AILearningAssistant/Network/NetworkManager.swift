import Foundation

private final class UploadTaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    private let onProgress: @Sendable (Double) -> Void
    private let onServerProcessing: @Sendable () -> Void
    private let completion: (Result<(Data, URLResponse), Error>) -> Void
    private var responseData = Data()
    private var response: URLResponse?
    private var hasEnteredServerProcessing = false

    init(
        onProgress: @escaping @Sendable (Double) -> Void,
        onServerProcessing: @escaping @Sendable () -> Void,
        completion: @escaping (Result<(Data, URLResponse), Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onServerProcessing = onServerProcessing
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(max(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0), 1)
        if progress >= 1 {
            if !hasEnteredServerProcessing {
                hasEnteredServerProcessing = true
                onProgress(0.9)
                onServerProcessing()
            }
            return
        }
        onProgress(progress * 0.9)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        self.response = response
        return .allow
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }

        guard let response else {
            completion(.failure(NetworkError.invalidResponse))
            return
        }

        onProgress(1)
        completion(.success((responseData, response)))
    }
}

enum AppConfiguration {
    static let defaultBaseURL = "http://10.59.20.166:8000"

    static var apiBaseURL: String {
        let configuredURL = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
        let trimmedURL = configuredURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedURL.isEmpty ? defaultBaseURL : trimmedURL
    }
}

nonisolated struct APIErrorResponse: Decodable {
    let detail: String
}

nonisolated struct MessageResponse: Decodable {
    let message: String
}

nonisolated struct ChatRequestBody: Encodable {
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

        if lowered.contains("文件名无效") {
            return "文件名有问题，请换个文件名后再试。"
        }

        if lowered.contains("libreoffice") {
            return "暂时不能处理文档,请联系服务器管理员。"
        }

        if lowered.contains("office 文件转 pdf 失败") {
            return "文档转换失败。请确认文件没有损坏，或换一个文件后再试。"
        }

        if lowered.contains("内容为空") || lowered.contains("empty") {
            return "这个文件是空的，换一个有内容的文件再试吧。"
        }

        if lowered.contains("网络连接被中断") || lowered.contains("ssl") || lowered.contains("connectionpool") {
            return "文件在本地处理成功，但连接云端服务时出现了问题。请检查网络连接后重试。"
        }

        if lowered.contains("文件类型与内容类型不匹配") {
            return "这个文件的类型和内容不匹配。请重新导出文件后再上传。"
        }

        if lowered.contains("文件过大") || statusCode == 413 {
            return trimmed
        }

        if lowered.contains("暂不支持该文件类型上传") {
            return "当前还不支持这种文件类型。请换成图片、音频、视频、PDF或常见文档格式后再试。"
        }

        if lowered.contains("api key 无效") || lowered.contains("权限不足") {
            return "接口服务出现异常，请稍后再试。"
        }

        if lowered.contains("模型") && lowered.contains("不可用") {
            return "当前正处于高峰时段，暂时无法处理本文件，请稍后再试。"
        }

        if statusCode >= 500 {
            return "处理这次请求时出了点问题，请稍后再试。"
        }

        return trimmed
    }

    static func userFriendlyTransportMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "无网络连接，请检查网络后再试。"
        case .timedOut:
            return "上传超时。请检查网络连接或稍后再试。"
        case .networkConnectionLost:
            return "网络意外断开，请重试。"
        case .cannotConnectToHost, .cannotFindHost:
            return "无法连接到服务器，请稍后再试或联系管理员。"
        case .appTransportSecurityRequiresSecureConnection:
            return "连接被拦截了，请稍后再试。"
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
            return "现在没法安全地连接到服务，请稍后再试。"
        default:
            return "网络连接异常，请检查网络。"
        }
    }
}

final class NetworkManager: Sendable {
    static let shared = NetworkManager()
    let baseURL: String
    private let session: URLSession
    private let longRunningSession: URLSession

    private init(baseURL: String = AppConfiguration.apiBaseURL) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 10
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)

        let longRunningConfiguration = URLSessionConfiguration.default
        longRunningConfiguration.timeoutIntervalForRequest = 60
        longRunningConfiguration.timeoutIntervalForResource = 60 * 60
        longRunningConfiguration.waitsForConnectivity = false
        self.longRunningSession = URLSession(configuration: longRunningConfiguration)
    }

    nonisolated private func makeURL(path: String) throws -> URL {
        let urlString = "\(baseURL)\(path)"
        guard let url = URL(string: urlString) else {
            throw NetworkError.invalidURL(urlString)
        }
        return url
    }

    nonisolated private func send(_ request: URLRequest, using transportSession: URLSession? = nil) async throws -> Data {
        do {
            let activeSession = transportSession ?? session
            let (data, response) = try await activeSession.data(for: request)
            return try decodeResponse(data: data, response: response)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    nonisolated private func send(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            return try decodeResponse(data: data, response: response)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    nonisolated private func decodeResponse(data: Data, response: URLResponse) throws -> Data {
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
    
    nonisolated func sendMessage(prompt: String, sessionId: String?, filePaths: [String]?) async throws -> ChatResponse {
        let url = try makeURL(path: "/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequestBody(
                prompt: prompt,
                session_id: sessionId,
                file_paths: filePaths?.isEmpty == true ? nil : filePaths
            )
        )

        let data = try await send(request, using: longRunningSession)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
    
    nonisolated func uploadFile(
        data: Data,
        fileName: String,
        mimeType: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        onServerProcessing: @escaping @Sendable () -> Void = {}
    ) async throws -> UploadResponse {
        let url = try makeURL(path: "/upload/file")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        do {
            let (data, response) = try await performUpload(
                request: request,
                body: body,
                onProgress: onProgress,
                onServerProcessing: onServerProcessing
            )
            let validatedData = try decodeResponse(data: data, response: response)
            return try JSONDecoder().decode(UploadResponse.self, from: validatedData)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    nonisolated func uploadFile(
        fileURL: URL,
        fileName: String,
        mimeType: String,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in },
        onServerProcessing: @escaping @Sendable () -> Void = {}
    ) async throws -> UploadResponse {
        let url = try makeURL(path: "/upload/file")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let multipartFileURL = try createMultipartUploadFile(
            sourceFileURL: fileURL,
            fileName: fileName,
            mimeType: mimeType,
            boundary: boundary
        )

        defer {
            try? FileManager.default.removeItem(at: multipartFileURL)
        }

        do {
            let (data, response) = try await performUpload(
                request: request,
                fileURL: multipartFileURL,
                onProgress: onProgress,
                onServerProcessing: onServerProcessing
            )
            let validatedData = try decodeResponse(data: data, response: response)
            return try JSONDecoder().decode(UploadResponse.self, from: validatedData)
        } catch let error as URLError {
            throw NetworkError.transportError(message: NetworkError.userFriendlyTransportMessage(for: error))
        }
    }

    nonisolated private func createMultipartUploadFile(
        sourceFileURL: URL,
        fileName: String,
        mimeType: String,
        boundary: String
    ) throws -> URL {
        let hasAccess = sourceFileURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceFileURL.stopAccessingSecurityScopedResource()
            }
        }

        let multipartFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")

        FileManager.default.createFile(atPath: multipartFileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: multipartFileURL)
        defer { try? handle.close() }

        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        if let headerData = header.data(using: .utf8) {
            handle.write(headerData)
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceFileURL)
        defer { try? sourceHandle.close() }

        while autoreleasepool(invoking: {
            let chunk = sourceHandle.readData(ofLength: 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            handle.write(chunk)
            return true
        }) {}

        if let footerData = "\r\n--\(boundary)--\r\n".data(using: .utf8) {
            handle.write(footerData)
        }

        return multipartFileURL
    }

    nonisolated private func performUpload(
        request: URLRequest,
        body: Data,
        onProgress: @escaping @Sendable (Double) -> Void,
        onServerProcessing: @escaping @Sendable () -> Void
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var uploadSession: URLSession?
            let delegate = UploadTaskDelegate(
                onProgress: onProgress,
                onServerProcessing: onServerProcessing
            ) { result in
                uploadSession?.invalidateAndCancel()
                continuation.resume(with: result)
            }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60 * 60
            uploadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = uploadSession!.uploadTask(with: request, from: body)
            task.resume()
        }
    }

    nonisolated private func performUpload(
        request: URLRequest,
        fileURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onServerProcessing: @escaping @Sendable () -> Void
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            var uploadSession: URLSession?
            let delegate = UploadTaskDelegate(
                onProgress: onProgress,
                onServerProcessing: onServerProcessing
            ) { result in
                uploadSession?.invalidateAndCancel()
                continuation.resume(with: result)
            }

            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            uploadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = uploadSession!.uploadTask(with: request, fromFile: fileURL)
            task.resume()
        }
    }

    nonisolated func getSessions() async throws -> [ChatSession] {
        let url = try makeURL(path: "/sessions")
        let data = try await send(from: url)
        return try JSONDecoder().decode([ChatSession].self, from: data)
    }
    
    nonisolated func getSessionMessages(sessionId: String) async throws -> [ChatMessage] {
        let url = try makeURL(path: "/sessions/\(sessionId)/messages")
        let data = try await send(from: url)
        return try JSONDecoder().decode([ChatMessage].self, from: data)
    }
    
    nonisolated func deleteSession(sessionId: String) async throws {
        let url = try makeURL(path: "/sessions/\(sessionId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20

        _ = try await send(request)
    }

    // MARK: - 知识卡片 API
    nonisolated func fetchKnowledgeCards() async throws -> [KnowledgeCard] {
        let url = try makeURL(path: "/cards")
        let data = try await send(from: url)
        return try JSONDecoder().decode([KnowledgeCard].self, from: data)
    }

    nonisolated func createKnowledgeCard(card: KnowledgeCardCreate) async throws -> String {
        let url = try makeURL(path: "/cards")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(card)

        let data = try await send(request)
        let response = try JSONDecoder().decode(MessageResponse.self, from: data)
        return response.message
    }

    nonisolated func deleteKnowledgeCard(cardId: Int) async throws {
        let url = try makeURL(path: "/cards/\(cardId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20

        _ = try await send(request)
    }

    nonisolated func updateKnowledgeCard(cardId: Int, card: KnowledgeCardUpdate) async throws -> String {
        let url = try makeURL(path: "/cards/\(cardId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(card)

        let data = try await send(request)
        let response = try JSONDecoder().decode(MessageResponse.self, from: data)
        return response.message
    }

    // MARK: - 笔记 API
    nonisolated func fetchNotes() async throws -> [Note] {
        let url = try makeURL(path: "/notes")
        let data = try await send(from: url)
        return try JSONDecoder().decode([Note].self, from: data)
    }

    nonisolated func fetchNote(noteId: Int) async throws -> Note {
        let url = try makeURL(path: "/notes/\(noteId)")
        let data = try await send(from: url)
        return try JSONDecoder().decode(Note.self, from: data)
    }

    nonisolated func createNote(_ note: NoteCreate) async throws -> NoteMutationResponse {
        let url = try makeURL(path: "/notes")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(note)

        let data = try await send(request)
        return try JSONDecoder().decode(NoteMutationResponse.self, from: data)
    }

    nonisolated func updateNote(noteId: Int, note: NoteUpdate) async throws -> NoteMutationResponse {
        let url = try makeURL(path: "/notes/\(noteId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(note)

        let data = try await send(request)
        return try JSONDecoder().decode(NoteMutationResponse.self, from: data)
    }

    nonisolated func deleteNote(noteId: Int) async throws {
        let url = try makeURL(path: "/notes/\(noteId)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 20

        _ = try await send(request)
    }

    nonisolated func generateNote(_ requestBody: NoteGenerateRequest) async throws -> NoteGenerationResponse {
        let url = try makeURL(path: "/notes/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let data = try await send(request, using: longRunningSession)
        return try JSONDecoder().decode(NoteGenerationResponse.self, from: data)
    }

    nonisolated func extractKnowledgeCard(fromNoteId noteId: Int) async throws -> CardExtractionResponse {
        let url = try makeURL(path: "/notes/\(noteId)/extract-card")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20

        let data = try await send(request)
        return try JSONDecoder().decode(CardExtractionResponse.self, from: data)
    }

    nonisolated func expandCardToNote(cardId: Int) async throws -> NoteGenerationResponse {
        let url = try makeURL(path: "/cards/\(cardId)/expand-note")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20

        let data = try await send(request)
        return try JSONDecoder().decode(NoteGenerationResponse.self, from: data)
    }
}
