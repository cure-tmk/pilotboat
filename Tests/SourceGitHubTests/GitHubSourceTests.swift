import Core
import Foundation
import Testing
@testable import SourceGitHub

@Suite struct GitHubSourceTests {
    let r1 = t0.addingTimeInterval(-600)
    let r2 = t0.addingTimeInterval(-120)

    @Test func firstPollBuildsBothKinds() async throws {
        let (r1, r2) = (r1, r2)
        let stub = Stub { body in
            isQ1(body)
                ? searchPage([pr(1, author: "alice", timeline: [requested(r1, user: "me"), requested(r2, user: "Me"), requested(r2.addingTimeInterval(10), user: "bob")])])
                : searchPage([pr(2, reviews: [review(77, by: "alice", at: r2, state: "CHANGES_REQUESTED")])])
        }
        let result = try await makeSource(stub).poll(context: context())

        #expect(result.cursor == t0)
        #expect(result.events.count == 2)
        let rr = try #require(result.events.first { $0.kind == .reviewRequested })
        #expect(rr.dedupeKey == "rr:github.com/acme/app#1:\(iso(r2))")
        #expect(rr.occurredAt == r2)
        #expect(rr.subject.pullRequest?.author == "alice")
        #expect(rr.subject.pullRequest?.labels == ["bug"])
        let rs = try #require(result.events.first { $0.kind == .reviewSubmitted })
        #expect(rs.dedupeKey == "rs:github.com/acme/app#2:77")
        #expect(rs.occurredAt == r2)
        #expect(rs.actor == Actor(login: "alice", isBot: false))
        #expect(rs.review == ReviewInfo(id: 77, state: "CHANGES_REQUESTED"))
        #expect(result.openReviewRequests.map(\.number) == [1])

        let q2 = try #require(stub.variables.first { ($0["q"] as! String).contains("author:@me") })
        #expect(q2["q"] as? String == "is:pr is:open archived:false author:@me updated:>=\(iso(t0.addingTimeInterval(-300)))")
        let q1 = try #require(stub.variables.first { ($0["q"] as! String).contains("review-requested") })
        #expect(q1["q"] as? String == "is:pr is:open archived:false user-review-requested:@me")
    }

    @Test func cursorDrivesQ2Window() async throws {
        let cursor = t0.addingTimeInterval(-1000)
        let stub = Stub { _ in searchPage([pr(2, reviews: [review(1, by: "a", at: cursor.addingTimeInterval(-400)), review(2, by: "a", at: cursor.addingTimeInterval(-200))])]) }
        let result = try await makeSource(stub).poll(context: context([.reviewSubmitted], cursor: cursor))
        #expect(result.events.map(\.review?.id) == [2])
        #expect(stub.variables[0]["q"] as? String == "is:pr is:open archived:false author:@me updated:>=\(iso(cursor.addingTimeInterval(-300)))")
    }

    @Test func pagination() async throws {
        let r1 = r1
        let stub = Stub { body in
            let after = (body["variables"] as! [String: Any])["after"] as? String
            return after == nil
                ? searchPage([pr(1, timeline: [requested(r1, user: "me")])], next: "c1")
                : searchPage([pr(2, timeline: [requested(r1, user: "me")])])
        }
        let result = try await makeSource(stub).poll(context: context([.reviewRequested]))
        #expect(result.events.map(\.subject.pullRequest?.number) == [1, 2])
        #expect(stub.variables.map { $0["after"] as? String } == [nil, "c1"])
    }

    @Test func reRequestChangesKeyButPushDoesNot() async throws {
        func key(_ times: [Date], sha: String) async throws -> String {
            let stub = Stub { _ in
                var node = pr(1, timeline: times.map { requested($0, user: "me") })
                node["headRefOid"] = sha
                return searchPage([node])
            }
            return try await makeSource(stub).poll(context: context([.reviewRequested])).events[0].dedupeKey
        }
        let first = try await key([r1], sha: "a")
        let pushed = try await key([r1], sha: "b")
        let rerequested = try await key([r1, r2], sha: "b")
        #expect(first == pushed)
        #expect(first != rerequested)
    }

    @Test(arguments: [true, false]) func teamRequests(includeTeams: Bool) async throws {
        let (r1, r2) = (r1, r2)
        let stub = Stub { _ in searchPage([pr(1, timeline: [requested(r1, user: "me"), requested(r2, team: "core")]), pr(2, timeline: [requested(r1, team: "core")])]) }
        let result = try await makeSource(stub, includeTeams: includeTeams).poll(context: context([.reviewRequested]))
        if includeTeams {
            #expect(result.events.map(\.occurredAt) == [r2, r1])
            #expect(stub.variables[0]["q"] as? String == "is:pr is:open archived:false review-requested:@me")
        } else {
            #expect(result.events.map(\.occurredAt) == [r1])
            #expect(result.openReviewRequests.count == 2)
        }
    }

    @Test func reviewFilters() async throws {
        let r2 = r2
        let stub = Stub { _ in
            searchPage([pr(2, reviews: [
                review(1, by: "me", at: r2), review(2, by: "Noisy", at: r2), review(3, by: "alice", at: r2, state: "PENDING"),
                review(4, by: "alice", at: nil, state: "PENDING"), review(5, by: "copilot", at: r2, state: "COMMENTED", bot: true),
                review(6, by: "alice", at: r2),
            ])])
        }
        let result = try await makeSource(stub, excluded: ["noisy"]).poll(context: context([.reviewSubmitted]))
        #expect(result.events.map(\.review?.id) == [5, 6])
        #expect(result.events.map(\.actor?.isBot) == [true, false])
    }

    @Test func repoFilter() async throws {
        let r1 = r1
        let stub = Stub { _ in searchPage(["acme/app", "acme/off", "acme/other", "ACME/App"].enumerated().map { pr($0.offset, repo: $0.element, timeline: [requested(r1, user: "me")]) }) }
        let repos = [Repository(fullName: "acme/app"), Repository(fullName: "acme/off", monitoring: false), Repository(host: "ghe.example.com", fullName: "acme/other")]
        let result = try await makeSource(stub).poll(context: context([.reviewRequested], repos: repos))
        #expect(result.events.map(\.repo) == ["acme/app", "ACME/App"])
        #expect(result.openReviewRequests.count == 2)
    }

    @Test(arguments: [[EventKind.reviewRequested], [.reviewSubmitted], []]) func requestedKindsSkipQueries(kinds: [EventKind]) async throws {
        let stub = Stub { _ in searchPage([]) }
        _ = try await makeSource(stub).poll(context: context(Set(kinds)))
        #expect(stub.queries.count == kinds.count)
        #expect(stub.queries.allSatisfy { $0.contains("timelineItems") == (kinds.first == .reviewRequested) })
    }

    @Test func noToken() async throws {
        let stub = Stub { _ in searchPage([]) }
        await #expect(throws: GitHubError.self) { try await makeSource(stub, tokens: false).poll(context: context()) }
        let items = await makeSource(stub, tokens: false).diagnose()
        #expect(items.map(\.level) == [.error])
        #expect(stub.queries.isEmpty)
    }

    @Test func unauthorized() async throws {
        let stub = Stub { _ in StubResponse(status: 401, body: ["message": "Bad credentials"]) }
        await #expect { try await makeSource(stub).poll(context: context()) } throws: { if case GitHubError.unauthorized = $0 { true } else { false } }
        #expect(await makeSource(stub).diagnose().map(\.level) == [.error])
    }

    @Test func ssoRequired() async throws {
        let stub = Stub { _ in StubResponse(status: 403, headers: ["X-GitHub-SSO": "required; url=https://github.com/orgs/acme/sso?authorization_request=x"], body: ["message": "SSO"]) }
        await #expect { try await makeSource(stub).poll(context: context()) } throws: { if case GitHubError.ssoRequired(["acme"]) = $0 { true } else { false } }
        let items = await makeSource(stub).diagnose()
        #expect(items.first?.detail?.contains("acme") == true)
        #expect(GraphQLClient.ssoOrgs("partial-results; organizations=21955855,20582480") == ["21955855", "20582480"])
    }

    @Test func lowRateLimitThrowsAndBlocksNextTick() async throws {
        let stub = Stub { _ in searchPage([], remaining: 499) }
        let source = makeSource(stub)
        await #expect { try await source.poll(context: context()) } throws: { if case GitHubError.rateLimited(t0.addingTimeInterval(3600)) = $0 { true } else { false } }
        await #expect(throws: GitHubError.self) { try await source.poll(context: context()) }
        #expect(stub.queries.count == 1)
        #expect(await source.lastRateLimit?.remaining == 499)
    }

    @Test(arguments: [403, 429]) func retryAfter(status: Int) async throws {
        let stub = Stub { _ in StubResponse(status: status, headers: ["Retry-After": "60"], body: ["message": "slow down"]) }
        await #expect { try await makeSource(stub).poll(context: context()) } throws: { if case GitHubError.rateLimited(t0.addingTimeInterval(60)) = $0 { true } else { false } }
    }

    @Test func pullRequestURL() async throws {
        let stub = Stub { _ in StubResponse(body: ["data": ["rateLimit": ["limit": 5000, "remaining": 4000, "resetAt": iso(t0)], "repository": ["pullRequest": pr(42, author: "alice")]]]) }
        let ref = try await makeSource(stub).pullRequest(url: URL(string: "https://github.com/acme/app/pull/42/files")!)
        #expect(ref.number == 42 && ref.repo == "acme/app" && ref.headSHA == "sha42" && ref.author == "alice" && ref.state == .open)
        #expect(stub.queries[0].contains("state"))
        #expect(stub.variables[0]["owner"] as? String == "acme")
        #expect(stub.variables[0]["number"] as? Int == 42)

        for bad in ["https://github.com/acme/app/issues/42", "https://gitlab.com/acme/app/pull/42", "https://github.com/acme/app/pull/x"] {
            await #expect { try await makeSource(stub).pullRequest(url: URL(string: bad)!) } throws: { if case GitHubError.invalidURL = $0 { true } else { false } }
        }
        #expect(stub.queries.count == 1)
    }

    @Test(arguments: [("MERGED", PullRequestState.merged), ("CLOSED", .closed)])
    func pullRequestState(raw: String, expected: PullRequestState) async throws {
        let stub = Stub { _ in StubResponse(body: ["data": ["rateLimit": ["limit": 5000, "remaining": 4000, "resetAt": iso(t0)], "repository": ["pullRequest": pr(42, state: raw)]]]) }
        #expect(try await makeSource(stub).pullRequest(url: URL(string: "https://github.com/acme/app/pull/42")!).state == expected)
    }

    @Test func graphQLErrors() async throws {
        let stub = Stub { _ in StubResponse(body: ["data": NSNull(), "errors": [["message": "token ghp_abcdef123 bad"]]]) }
        await #expect { try await makeSource(stub).pullRequest(url: URL(string: "https://github.com/a/b/pull/1")!) } throws: {
            if case GitHubError.graphQL(let m) = $0 { m == ["token [REDACTED] bad"] } else { false }
        }
    }

    @Test func diagnoseAndVerify() async throws {
        let stub = Stub { _ in StubResponse(body: ["data": ["viewer": ["login": "me"], "rateLimit": ["limit": 5000, "remaining": 4000, "resetAt": iso(t0)]]]) }
        let source = makeSource(stub)
        #expect(await source.diagnose().map(\.level) == [.ok])
        #expect(try await makeSource(stub, tokens: false).verifyToken(stub.token) == "me")
    }

    @Test func tokenMasker() {
        let text = "a ghp_AbC123 b gho_x c ghu_y ghs_z ghr_w github_pat_11AA_bb d ghx_keep"
        #expect(TokenMasker.mask(text) == "a [REDACTED] b [REDACTED] c [REDACTED] [REDACTED] [REDACTED] [REDACTED] d ghx_keep")
    }
}
