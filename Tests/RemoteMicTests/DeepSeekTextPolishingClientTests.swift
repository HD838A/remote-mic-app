import Foundation
import Testing
@testable import RemoteMic

@Suite("DeepSeek post-dictation client")
struct DeepSeekTextPolishingClientTests {
    @Test func requestIsNonStreamingAndCarriesOnlyBoundedStructuredContext() throws {
        let input = DeepSeekPolishInput(
            applicationName: "Codex",
            bundleIdentifier: "com.openai.codex",
            contextBefore: String(repeating: "前", count: 120),
            contextAfter: String(repeating: "后", count: 120),
            currentDictation: "切到 feat 斜杠 voice one 横杠 test",
            programmingTerms: [ProgrammingTerm(
                canonicalText: "feat/voice1-test",
                spokenAliases: ["feat 斜杠 voice one 横杠 test"],
                kind: .branch
            )]
        )

        let request = try DeepSeekTextPolishingClient.makeRequest(input: input, apiKey: "test-key")
        #expect(request.url == DeepSeekTextPolishingClient.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == false)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userContent = try #require(messages.last?["content"] as? String)
        let user = try #require(
            JSONSerialization.jsonObject(with: Data(userContent.utf8)) as? [String: Any]
        )
        let context = try #require(user["readOnlyContext"] as? [String: String])
        #expect(context["before"]?.count == 100)
        #expect(context["after"]?.count == 100)
        #expect(user["currentDictation"] as? String == input.currentDictation)
        #expect((user["formattingPolicy"] as? [String: Bool])?["automaticList"] == false)
        #expect(user["windowTitle"] == nil)
        #expect(user["fullText"] == nil)
    }

    @Test func responseMustContainOnlyRefinedText() throws {
        let valid = Data(#"{"choices":[{"message":{"content":"{\"refinedText\":\"整理结果\"}"}}]}"#.utf8)
        #expect(try DeepSeekTextPolishingClient.decodeRefinedText(from: valid) == "整理结果")

        let unknownField = Data(#"{"choices":[{"message":{"content":"{\"refinedText\":\"结果\",\"reason\":\"说明\"}"}}]}"#.utf8)
        #expect(throws: DeepSeekTextPolishingError.invalidResponse) {
            try DeepSeekTextPolishingClient.decodeRefinedText(from: unknownField)
        }
    }

    @Test func deterministicSafetyChecksPreserveNumbersAndProtectedTerms() {
        let input = DeepSeekPolishInput(
            applicationName: "Codex",
            bundleIdentifier: "com.openai.codex",
            contextBefore: "",
            contextAfter: "",
            currentDictation: "版本 1.7.3，切到 feat 斜杠 voice one 横杠 test",
            programmingTerms: [ProgrammingTerm(
                canonicalText: "feat/voice1-test",
                spokenAliases: ["feat 斜杠 voice one 横杠 test"],
                kind: .branch
            )]
        )

        #expect(DeepSeekTextPolishingClient.isSafe(
            result: "版本为 1.7.3，切换到 feat/voice1-test。",
            for: input
        ))
        #expect(!DeepSeekTextPolishingClient.isSafe(
            result: "版本为 1.7.4，切换到 feat/voice1-test。",
            for: input
        ))
        #expect(!DeepSeekTextPolishingClient.isSafe(
            result: "版本为 1.7.3，切换到其他分支。",
            for: input
        ))
    }
}
