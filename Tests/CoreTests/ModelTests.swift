import Foundation
import Testing
@testable import Core

@Test func ruleRoundTripsThroughJSON() throws {
    let repoId = UUID()
    let rule = Rule(id: "preset.review-received", name: "Review received", priority: 10, eventKind: .reviewSubmitted,
                    repoScope: .only([repoId]), conditions: [.actorKind(.human), .labelsExclude(["wip"])],
                    settleSeconds: 120, launcherId: "orca", workspacePolicy: .reuseOrCreate, promptTemplateId: "preset.review-received")
    let data = try JSONEncoder().encode(rule)
    let decoded = try JSONDecoder().decode(Rule.self, from: data)
    #expect(decoded == rule)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains(#""type":"only""#))
    #expect(json.contains(#""type":"actorKind""#))
}

@Test func unknownEventKindStillDecodes() throws {
    let kind = try JSONDecoder().decode(EventKind.self, from: Data(#""ciFailed""#.utf8))
    #expect(kind.rawValue == "ciFailed")
    #expect(!kind.isSupported)
    #expect(EventKind.reviewRequested.isSupported)
}

@Test func subjectHasStableJSONShape() throws {
    let pr = PullRequestRef(host: "github.com", repo: "o/r", number: 1, url: URL(string: "https://github.com/o/r/pull/1")!, title: "t",
                            headRef: "f", headSHA: "s", baseRef: "main", isDraft: false, isCrossRepository: false, labels: [], author: "a")
    let data = try JSONEncoder().encode(Subject.pullRequest(pr))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["type", "pullRequest"])
    #expect(json["type"] as? String == "pullRequest")
    #expect((json["pullRequest"] as? [String: Any])?["number"] as? Int == 1)
    #expect(try JSONDecoder().decode(Subject.self, from: data) == .pullRequest(pr))
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Subject.self, from: Data(#"{"type":"issue"}"#.utf8)) }

    var legacy = try #require(json["pullRequest"] as? [String: Any])
    #expect(legacy["state"] as? String == "OPEN")
    legacy["state"] = nil
    let decoded = try JSONDecoder().decode(PullRequestRef.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded == pr && decoded.state == .open)
}
