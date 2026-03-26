import Foundation

class NetworkManager {
    static let shared = NetworkManager()
    // 设为公开以便 View 层拼接图片 URL。真机测试请使用电脑在局域网的实际 IP
    let baseURL = "http://localhost:8000"
    
    func sendMessage(prompt: String, sessionId: String?, filePaths: [String]?) async throws -> ChatResponse {
        guard let url = URL(string: "\(baseURL)/chat") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = ["prompt": prompt]
        if let sessionId = sessionId {
            body["session_id"] = sessionId
        }
        if let filePaths = filePaths, !filePaths.isEmpty {
            body["file_paths"] = filePaths
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
    
    func uploadFile(imageData: Data, fileName: String) async throws -> UploadResponse {
        guard let url = URL(string: "\(baseURL)/upload/file") else {
            throw URLError(.badURL)
        }
        
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
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }
    
    func getSessions() async throws -> [ChatSession] {
        guard let url = URL(string: "\(baseURL)/sessions") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ChatSession].self, from: data)
    }
    
    func getSessionMessages(sessionId: String) async throws -> [ChatMessage] {
        guard let url = URL(string: "\(baseURL)/sessions/\(sessionId)/messages") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ChatMessage].self, from: data)
    }
    
    func deleteSession(sessionId: String) async throws {
        guard let url = URL(string: "\(baseURL)/sessions/\(sessionId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    // MARK: - 知识卡片 API
    func fetchKnowledgeCards() async throws -> [KnowledgeCard] {
        guard let url = URL(string: "\(baseURL)/cards") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([KnowledgeCard].self, from: data)
    }

    func createKnowledgeCard(card: KnowledgeCardCreate) async throws -> String {
        guard let url = URL(string: "\(baseURL)/cards") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(card)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return dict?["message"] as? String ?? "卡片创建成功"
    }

    func deleteKnowledgeCard(cardId: Int) async throws {
        guard let url = URL(string: "\(baseURL)/cards/\(cardId)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
    }
