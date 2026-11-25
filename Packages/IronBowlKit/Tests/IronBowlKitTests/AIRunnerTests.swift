import Foundation
import Testing
@testable import IronBowlKit

@Test func extractsJSONFromNoisyText() throws {
    let data = try AIRunner.extractJSONObject("log line\n```json\n{\"a\":\"}{\",\"b\":{\"c\":1}}\n```")
    let s = String(decoding: data, as: UTF8.self)
    #expect(s == "{\"a\":\"}{\",\"b\":{\"c\":1}}")
}

@Test func parsesAgyEnvelope() throws {
    let out = #"{"status":"SUCCESS","response":"{\"answer\":\"x\"}","structured_output":{"answer":"饭碗"}}"#
    let data = try AIRunner.parseAgy(out)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(obj?["answer"] == "饭碗")
}
