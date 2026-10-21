import Foundation

// Chat layer for Computah — makes it conversational
// When Jev finds no action (none_here), send the speech to GLM for a natural reply
// Then show the reply in the notch and speak it with TTS

@MainActor final class ChatBrain {
    private let session = URLSession(configuration: .ephemeral)
    var onReply: ((String) -> Void)?

    func reply(to text: String, apiKey: String, baseURL: String, model: String) async {
        let prompt = """
        You are Computah, a personal AI assistant on Nik's Mac. You can control apps and the system through voice commands. You are helpful, casual, and concise — like a smart friend sitting next to Nik. Keep replies under 2 sentences. You're a bit witty but not annoying.

        Nik said: "\(text)"

        This didn't trigger a tool action, so just reply conversationally. If Nik asked a question, answer it briefly. If Nik said something casual, respond naturally.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are Computah, a personal Mac assistant. Casual, witty, concise. Reply in under 2 sentences."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 100
        ]

        guard let url = URL(string: "\(baseURL)/chat/completions") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return }

            let cleanReply = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanReply.isEmpty {
                onReply?(cleanReply)
            }
        } catch {
            // Silent fail — don't interrupt the flow
        }
    }
}

// TTS using Deepgram Aura (better quality than edge-tts)
// Falls back to macOS 'say' command if Deepgram fails
@MainActor final class VoiceReply {
    func speak(_ text: String) {
        // Clean text for TTS
        let clean = text
            .replacingOccurrences(of: "✅", with: "")
            .replacingOccurrences(of: "❌", with: "")
            .replacingOccurrences(of: "⚠️", with: "")
            .replacingOccurrences(of: "🤔", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clean.isEmpty else { return }

        // Run TTS in background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.speakWithDeepgram(clean)
        }
    }

    private func speakWithDeepgram(_ text: String) {
        // Read Deepgram key from .env
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("degree/PersonalAgentic/computah/.env")

        guard let envContent = try? String(contentsOf: envPath, encoding: .utf8) else {
            self.speakWithSay(text)
            return
        }

        var apiKey = ""
        for line in envContent.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "DEEPGRAM_API_KEY" {
                apiKey = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !apiKey.isEmpty else {
            self.speakWithSay(text)
            return
        }

        // Call Deepgram TTS API
        let urlString = "https://api.deepgram.com/v1/speak?model=aura-2-thalia-en"
        guard let url = URL(string: urlString) else {
            self.speakWithSay(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = ["text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var audioData: Data?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                audioData = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        let tempPath = "/tmp/computah_deepgram_tts.mp3"
        if let audioData = audioData {
            try? audioData.write(to: URL(fileURLWithPath: tempPath))
            let play = Process()
            play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            play.arguments = [tempPath]
            try? play.run()
            play.waitUntilExit()
            try? FileManager.default.removeItem(atPath: tempPath)
        } else {
            self.speakWithSay(text)
        }
    }

    private func speakWithSay(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Daniel", text]
        try? process.run()
        process.waitUntilExit()
    }
}
