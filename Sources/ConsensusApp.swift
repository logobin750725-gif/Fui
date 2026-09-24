import SwiftUI
import Security

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

struct ContentView: View {
    @State private var prompt = ""
    @State private var output = ""
    @State private var busy = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Variant.title).font(.largeTitle.bold())
                    Text(Variant.subtitle).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $prompt)
                    .frame(minHeight: 150)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))

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
                .disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        }
    }

    @MainActor
    private func runConsensus() async {
        busy = true
        defer { busy = false }
        do {
            output = try await ConsensusEngine.run(prompt: prompt, ultra: Variant.isUltra)
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
    static func run(prompt: String, ultra: Bool) async throws -> String {
        ultra ? try await runUltra(prompt) : try await runPro(prompt)
    }

    static func runPro(_ prompt: String) async throws -> String {
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
                group.addTask { try await AI.gemini(key: key, system: role, prompt: prompt) }
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
        return try await AI.gemini(key: key, system: "你是多模型共識裁判。", prompt: judge)
    }

    static func runUltra(_ prompt: String) async throws -> String {
        var tasks: [(String, () async throws -> String)] = []

        if let k = Keychain.get("gemini"), !k.isEmpty {
            tasks.append(("Gemini", { try await AI.gemini(key: k, system: "獨立回答，重視事實與不確定性。", prompt: prompt) }))
        }
        if let k = Keychain.get("openai"), !k.isEmpty {
            tasks.append(("OpenAI", { try await AI.openAI(key: k, prompt: prompt) }))
        }
        if let k = Keychain.get("claude"), !k.isEmpty {
            tasks.append(("Claude", { try await AI.claude(key: k, prompt: prompt) }))
        }
        if let k = Keychain.get("grok"), !k.isEmpty {
            tasks.append(("Grok", { try await AI.grok(key: k, prompt: prompt) }))
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

        let dossier = results.map { "### \($0.0)\n\($0.1)" }.joined(separator: "\n\n")
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
            return try await AI.gemini(key: k, system: "證據優先，不因模型數量多就判定正確。", prompt: synthesisPrompt)
        }
        if let k = Keychain.get("openai"), !k.isEmpty {
            return try await AI.openAI(key: k, prompt: synthesisPrompt)
        }
        return dossier
    }
}

enum AI {
    static func gemini(key: String, system: String, prompt: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(key)")!
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]]
        ]
        let json = try await post(url: url, headers: [:], body: body)

        guard
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else {
            throw AppError.message("Gemini 回傳格式異常。")
        }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func openAI(key: String, prompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "messages": [["role": "user", "content": prompt]]
        ]
        let json = try await post(url: url, headers: ["Authorization": "Bearer \(key)"], body: body)

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
            headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
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
        let json = try await post(url: url, headers: ["Authorization": "Bearer \(key)"], body: body)

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String {
            return text
        }
        throw AppError.message("Grok 回傳格式異常。")
    }

    private static func post(url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
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
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AppError.message(msg)
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

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
