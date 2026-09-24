import SwiftUI
import Security
import PhotosUI
import UniformTypeIdentifiers

@main
struct ConsensusApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Variant {
    static var isUltra: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".ultra") == true
    }
    static var title: String { isUltra ? "Consensus Ultra" : "Consensus Pro" }
    static var subtitle: String {
        isUltra ? "多模型交叉驗證・分歧警報・證據優先" : "4 Agent 盲測・互挑錯・裁判共識"
    }
}

struct AttachmentItem: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data

    var isTextLike: Bool {
        mimeType.hasPrefix("text/") ||
        mimeType == "application/json" ||
        mimeType == "application/xml"
    }

    var extractedText: String? {
        guard isTextLike else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct ContentView: View {
    @State private var prompt = ""
    @State private var output = ""
    @State private var busy = false
    @State private var showSettings = false
    @State private var showFileImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var attachments: [AttachmentItem] = []
    @State private var attachmentError = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Variant.title).font(.largeTitle.bold())
                    Text(Variant.subtitle).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $prompt)
                    .frame(minHeight: 130)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

                HStack(spacing: 12) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("圖片", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("檔案", systemImage: "paperclip")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if !attachments.isEmpty {
                        Text("\(attachments.count)/4")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { item in
                                HStack(spacing: 6) {
                                    Image(systemName: item.mimeType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                                    Text(item.name)
                                        .lineLimit(1)
                                        .font(.caption)
                                    Button {
                                        attachments.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.thinMaterial, in: Capsule())
                            }
                        }
                    }
                }

                if !attachmentError.isEmpty {
                    Text(attachmentError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await runConsensus() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "分析中…" : "開始共識分析").bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    busy ||
                    (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                )

                ScrollView {
                    Text(output.isEmpty ? "結果會顯示在這裡。" : output)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "key.fill") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.image, .pdf, .plainText, .text, .json, .data],
                allowsMultipleSelection: true
            ) { result in
                handleFiles(result)
            }
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await handlePhoto(newItem) }
            }
        }
    }

    @MainActor
    private func handlePhoto(_ item: PhotosPickerItem) async {
        attachmentError = ""
        guard attachments.count < 4 else {
            attachmentError = "最多可加入 4 個附件。"
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                attachmentError = "無法讀取圖片。"
                return
            }
            guard data.count <= 15 * 1024 * 1024 else {
                attachmentError = "單一附件不可超過 15 MB。"
                return
            }
            let type = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            attachments.append(
                AttachmentItem(
                    name: "圖片-\(attachments.count + 1)",
                    mimeType: type,
                    data: data
                )
            )
        } catch {
            attachmentError = "圖片讀取失敗：\(error.localizedDescription)"
        }
        photoItem = nil
    }

    @MainActor
    private func handleFiles(_ result: Result<[URL], Error>) {
        attachmentError = ""
        do {
            let urls = try result.get()
            for url in urls {
                guard attachments.count < 4 else {
                    attachmentError = "最多可加入 4 個附件。"
                    break
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }

                let data = try Data(contentsOf: url)
                guard data.count <= 15 * 1024 * 1024 else {
                    attachmentError = "\(url.lastPathComponent) 超過 15 MB，已略過。"
                    continue
                }

                let values = try? url.resourceValues(forKeys: [.contentTypeKey])
                let mime = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
                attachments.append(
                    AttachmentItem(
                        name: url.lastPathComponent,
                        mimeType: mime,
                        data: data
                    )
                )
            }
        } catch {
            attachmentError = "檔案讀取失敗：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func runConsensus() async {
        busy = true
        attachmentError = ""
        defer { busy = false }

        do {
            output = try await ConsensusEngine.run(
                prompt: prompt,
                ultra: Variant.isUltra,
                attachments: attachments
            )
        } catch {
            output = "錯誤：\(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gemini = Keychain.get("gemini") ?? ""
    @State private var openai = Keychain.get("openai") ?? ""
    @State private var claude = Keychain.get("claude") ?? ""
    @State private var grok = Keychain.get("grok") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section("API Keys") {
                    SecureField("Gemini API Key", text: $gemini)
                    if Variant.isUltra {
                        SecureField("OpenAI API Key", text: $openai)
                        SecureField("Anthropic API Key", text: $claude)
                        SecureField("xAI / Grok API Key", text: $grok)
                    }
                }

                Section("附件") {
                    Text("圖片、PDF 與文字檔會傳給 Gemini。文字類檔案也會抽出文字給其他模型。每次最多 4 個、單檔 15 MB。")
                        .font(.footnote)
                }

                Section {
                    Text(Variant.isUltra
                         ? "Ultra 會使用已填入金鑰的模型並行回答，再做衝突偵測與綜合。只填 Gemini 也能使用。"
                         : "Pro 只需要 Gemini Key，會讓 4 個獨立角色盲測回答、互相挑錯，再產生裁判版共識。")
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        Keychain.set(gemini, for: "gemini")
                        Keychain.set(openai, for: "openai")
                        Keychain.set(claude, for: "claude")
                        Keychain.set(grok, for: "grok")
                        dismiss()
                    }
                }
            }
        }
    }
}

enum ConsensusEngine {
    static func run(
        prompt: String,
        ultra: Bool,
        attachments: [AttachmentItem]
    ) async throws -> String {
        ultra
            ? try await runUltra(prompt, attachments: attachments)
            : try await runPro(prompt, attachments: attachments)
    }

    private static func promptForOtherModels(
        _ prompt: String,
        attachments: [AttachmentItem]
    ) -> String {
        let texts = attachments.compactMap { item -> String? in
            guard let text = item.extractedText else { return nil }
            return """
            
            --- 附件：\(item.name) ---
            \(text)
            """
        }.joined()

        let nonText = attachments
            .filter { !$0.isTextLike }
            .map(\.name)

        let note = nonText.isEmpty
            ? ""
            : "\n\n[注意：以下非文字附件僅由 Gemini 直接讀取：\(nonText.joined(separator: ", "))]"

        return prompt + texts + note
    }

    static func runPro(
        _ prompt: String,
        attachments: [AttachmentItem]
    ) async throws -> String {
        guard let key = Keychain.get("gemini"), !key.isEmpty else {
            throw AppError.message("請先在右上角鑰匙設定 Gemini API Key。")
        }

        let roles = [
            "你是嚴格的事實分析師。只處理可驗證主張，標出不確定處。",
            "你是反方審查員。優先找漏洞、反例、遺漏條件與過度自信。",
            "你是實務決策顧問。提出可執行方案、風險與取捨。",
            "你是資深研究員。整合背景、因果、替代解釋，避免幻覺。"
        ]

        var answers: [String] = []
        try await withThrowingTaskGroup(of: String.self) { group in
            for role in roles {
                group.addTask {
                    try await AI.gemini(
                        key: key,
                        system: role,
                        prompt: prompt,
                        attachments: attachments
                    )
                }
            }
            for try await answer in group { answers.append(answer) }
        }

        let joined = answers.enumerated().map {
            "Agent \($0.offset + 1):\n\($0.element)"
        }.joined(separator: "\n\n---\n\n")

        let judge = """
        你是裁判。以下是四個彼此獨立的回答。
        請：
        1. 先列共同結論
        2. 列重大分歧與哪一方證據較強
        3. 指出疑似幻覺/無法驗證內容
        4. 給最後整合答案，不能只做多數決
        5. 對需要查證的地方明確標「需外部查證」

        原問題：
        \(prompt)

        四份回答：
        \(joined)
        """

        return try await AI.gemini(
            key: key,
            system: "你是多模型共識裁判。",
            prompt: judge,
            attachments: []
        )
    }

    static func runUltra(
        _ prompt: String,
        attachments: [AttachmentItem]
    ) async throws -> String {
        var tasks: [(String, () async throws -> String)] = []
        let expandedPrompt = promptForOtherModels(prompt, attachments: attachments)

        if let k = Keychain.get("gemini"), !k.isEmpty {
            tasks.append(("Gemini", {
                try await AI.gemini(
                    key: k,
                    system: "獨立回答，重視事實與不確定性。",
                    prompt: prompt,
                    attachments: attachments
                )
            }))
        }
        if let k = Keychain.get("openai"), !k.isEmpty {
            tasks.append(("OpenAI", { try await AI.openAI(key: k, prompt: expandedPrompt) }))
        }
        if let k = Keychain.get("claude"), !k.isEmpty {
            tasks.append(("Claude", { try await AI.claude(key: k, prompt: expandedPrompt) }))
        }
        if let k = Keychain.get("grok"), !k.isEmpty {
            tasks.append(("Grok", { try await AI.grok(key: k, prompt: expandedPrompt) }))
        }

        guard !tasks.isEmpty else {
            throw AppError.message("至少設定一個 API Key。")
        }

        var results: [(String, String)] = []
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for (name, task) in tasks {
                group.addTask { (name, try await task()) }
            }
            for try await pair in group { results.append(pair) }
        }

        let dossier = results.map {
            "### \($0.0)\n\($0.1)"
        }.joined(separator: "\n\n")

        let synthesisPrompt = """
        你是多模型審查裁判。比較以下模型輸出。
        請輸出：
        【共識】
        【分歧】
        【可驗證主張】
        【疑似幻覺/薄弱點】
        【最後整合答案】
        【仍需外部查證】

        原問題：
        \(prompt)

        模型輸出：
        \(dossier)
        """

        if let k = Keychain.get("gemini"), !k.isEmpty {
            return try await AI.gemini(
                key: k,
                system: "證據優先，不因模型數量多就判定正確。",
                prompt: synthesisPrompt,
                attachments: []
            )
        }
        if let k = Keychain.get("openai"), !k.isEmpty {
            return try await AI.openAI(key: k, prompt: synthesisPrompt)
        }
        return dossier
    }
}

enum AI {
    static func gemini(
        key: String,
        system: String,
        prompt: String,
        attachments: [AttachmentItem]
    ) async throws -> String {
        let models = [
            "gemini-3.6-flash",
            "gemini-3.7-flash",
            "gemini-3.5-flash-lite"
        ]

        var userParts: [[String: Any]] = [["text": prompt.isEmpty ? "請分析附件內容。" : prompt]]

        for item in attachments {
            userParts.append([
                "inline_data": [
                    "mime_type": item.mimeType,
                    "data": item.data.base64EncodedString()
                ]
            ])
        }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": userParts]]
        ]

        var lastError: Error?

        for model in models {
            let url = URL(
                string: "https://generativelanguage.googleapis.com/v1beta/models/\\(model):generateContent"
            )!

            do {
                let json = try await postWithRetry(
                    url: url,
                    headers: ["x-goog-api-key": key],
                    body: body,
                    maxAttempts: 4
                )

                guard
                    let candidates = json["candidates"] as? [[String: Any]],
                    let content = candidates.first?["content"] as? [String: Any],
                    let parts = content["parts"] as? [[String: Any]]
                else {
                    throw AppError.message("Gemini 回傳格式異常。")
                }

                return parts.compactMap { $0["text"] as? String }.joined(separator: "\\n")
            } catch {
                lastError = error

                if case AppError.httpStatus(let code, _) = error,
                   code == 429 || code == 503 || (500...599).contains(code) {
                    continue
                }

                throw error
            }
        }

        throw lastError ?? AppError.message("Gemini 目前不可用，請稍後再試。")
    }

    static func openAI(key: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "messages": [["role": "user", "content": prompt]]
        ]
        let json = try await post(
            url: url,
            headers: ["Authorization": "Bearer \(key)"],
            body: body
        )

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text
        }
        throw AppError.message("OpenAI 回傳格式異常。")
    }

    static func claude(key: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]
        let json = try await post(
            url: url,
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01"
            ],
            body: body
        )

        if let content = json["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        throw AppError.message("Claude 回傳格式異常。")
    }

    static func grok(key: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.x.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "grok-4-fast",
            "messages": [["role": "user", "content": prompt]]
        ]
        let json = try await post(
            url: url,
            headers: ["Authorization": "Bearer \(key)"],
            body: body
        )

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text
        }
        throw AppError.message("Grok 回傳格式異常。")
    }

    private static func postWithRetry(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        maxAttempts: Int
    ) async throws -> [String: Any] {
        var attempt = 0
        var delayNanoseconds: UInt64 = 1_000_000_000
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1

            do {
                return try await post(url: url, headers: headers, body: body)
            } catch {
                lastError = error

                if case AppError.httpStatus(let code, _) = error,
                   code == 408 || code == 429 || (500...599).contains(code),
                   attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    delayNanoseconds = min(delayNanoseconds * 2, 8_000_000_000)
                    continue
                }

                throw error
            }
        }

        throw lastError ?? AppError.message("網路請求失敗。")
    }

    private static func post(
        url: URL,
        headers: [String: String],
        body: [String: Any]
    ) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.message("網路回應無效。")
        }

        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \\(http.statusCode)"
            throw AppError.httpStatus(http.statusCode, msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("JSON 解析失敗。")
        }

        return json
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ] as CFDictionary)

        SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ] as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

enum AppError: LocalizedError {
    case message(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .httpStatus(_, let message):
            return message
        }
    }
}
