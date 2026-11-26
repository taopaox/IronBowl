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

@Test func parsesAgyModelsOutputAndSpinnerLines() {
    let output = """
    \r⠋ Fetching available models...
    gemini-4-neon-high\tGemini 4 Neon (High)
    gemini-3.8-flash-medium  Gemini 3.8 Flash (Medium)
    gemini-4-neon-high\tDuplicate Should Skip
    """
    let models = AIRunner.parseAgyModels(output)
    #expect(models.count == 2)
    #expect(models[0].id == "gemini-4-neon-high")
    #expect(models[0].name == "Gemini 4 Neon (High)")
    #expect(models[1].id == "gemini-3.8-flash-medium")
    #expect(models[1].name == "Gemini 3.8 Flash (Medium)")
}

@Test func parsesCodexModelsCacheSortedAndFiltered() throws {
    let json = #"""
    {
      "models": [
        {
          "slug": "gpt-reserve",
          "display_name": "GPT-Reserve",
          "visibility": "hide",
          "priority": 1
        },
        {
          "slug": "gpt-6.1-terra",
          "display_name": "GPT-6.1 Terra",
          "description": "Deep reasoning",
          "visibility": "list",
          "priority": 3,
          "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]
        },
        {
          "slug": "gpt-6.2-sol",
          "display_name": "GPT-6.2-Sol",
          "description": "Fast coding",
          "visibility": "list",
          "priority": 1,
          "supported_reasoning_levels": [{"effort": "low"}]
        }
      ]
    }
    """#
    let models = AIRunner.parseCodexModelsCache(Data(json.utf8))
    #expect(models.count == 2)
    #expect(models[0].id == "gpt-6.2-sol")
    #expect(models[0].name == "GPT-6.2-Sol")
    #expect(models[0].detail == "Fast coding")
    #expect(models[0].supportedEfforts == ["low"])
    #expect(models[1].id == "gpt-6.1-terra")
    #expect(models[1].supportedEfforts == ["low", "high"])
}
