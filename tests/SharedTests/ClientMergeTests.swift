import XCTest

final class ClientMergeTests: XCTestCase {
    private let config = CompanionConfig(localURL: "192.168.1.20:47300", remoteURL: nil, token: "fake-token")
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func client(_ id: UUID, _ name: String, generatedAt: Date = referenceNow, host: String? = nil,
                        providers: [ProviderUsage]?, history: UsageHistory? = nil) -> PairedClient {
        let snapshot = providers.map { UsageSnapshot(generatedAt: generatedAt, host: host, companionVersion: "2.5.0", providers: $0) }
        return PairedClient(id: id, name: name, config: config, snapshot: snapshot, history: history)
    }

    private func fiveHour(_ percent: Double) -> UsageWindow {
        window(percent: percent, resetsAt: referenceNow.addingTimeInterval(3_600))
    }

    func testNilWithoutAnySnapshot() {
        XCTAssertNil(ClientMerge.snapshot([]))
        XCTAssertNil(ClientMerge.snapshot([client(firstID, "Mac", providers: nil)]))
    }

    func testSingleClientIsTaggedWithItsSource() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([client(firstID, "Mac", host: "mac", providers: [provider()])]))
        XCTAssertEqual(merged.host, "mac")
        XCTAssertEqual(merged.companionVersion, "2.5.0")
        XCTAssertEqual(merged.providers.count, 1)
        XCTAssertEqual(merged.providers[0].sourceClientID, firstID)
        XCTAssertEqual(merged.providers[0].sourceClientName, "Mac")
        XCTAssertEqual(merged.providers[0].sourceIsStale, false)
    }

    func testSameAccountOnTwoMachinesIsOneProvider() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", generatedAt: referenceNow, host: "mac", providers: [provider(account: "user@example.com", windows: [fiveHour(10)])]),
            client(secondID, "Linux", generatedAt: referenceNow.addingTimeInterval(30), host: "linux",
                   providers: [provider(account: "USER@example.com", windows: [fiveHour(20)])]),
        ]))
        XCTAssertEqual(merged.providers.count, 1)
        // Equal scores: the default (first) client wins.
        XCTAssertEqual(merged.providers[0].sourceClientID, firstID)
        XCTAssertEqual(merged.providers[0].windows.first?.percent, 10)
        XCTAssertEqual(merged.generatedAt, referenceNow.addingTimeInterval(30))
        XCTAssertEqual(merged.host, "mac")
    }

    func testDifferentAccountsStaySeparate() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(account: "work@example.com")]),
            client(secondID, "Linux", providers: [provider(account: "home@example.com")]),
        ]))
        XCTAssertEqual(merged.providers.map(\.account), ["work@example.com", "home@example.com"])
    }

    func testOKResultBeatsAnError() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(status: "error")]),
            client(secondID, "Linux", providers: [provider(status: "ok")]),
        ]))
        XCTAssertEqual(merged.providers.count, 1)
        XCTAssertEqual(merged.providers[0].sourceClientID, secondID)
        XCTAssertTrue(merged.providers[0].isOK)
    }

    func testFreshResultBeatsStaleOne() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(stale: true)]),
            client(secondID, "Linux", providers: [provider(stale: false)]),
        ]))
        XCTAssertEqual(merged.providers[0].sourceClientID, secondID)
    }

    func testReachableClientBeatsUnreachableOne() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider()]),
            client(secondID, "Linux", providers: [provider()]),
        ], unavailable: [firstID]))
        XCTAssertEqual(merged.providers.count, 1)
        XCTAssertEqual(merged.providers[0].sourceClientID, secondID)
        XCTAssertEqual(merged.providers[0].sourceIsStale, false)

        let onlyOffline = try XCTUnwrap(ClientMerge.snapshot([client(firstID, "Mac", providers: [provider()])], unavailable: [firstID]))
        XCTAssertEqual(onlyOffline.providers[0].sourceIsStale, true)
        XCTAssertTrue(onlyOffline.providers[0].isStale)
    }

    func testErroredProviderWithoutAccountAdoptsTheOnlyKnownAccount() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(account: nil, status: "error")]),
            client(secondID, "Linux", providers: [provider(account: "User@Example.com")]),
        ]))
        XCTAssertEqual(merged.providers.count, 1)
        XCTAssertEqual(merged.providers[0].sourceClientID, secondID)
    }

    func testUnknownAccountStaysSeparateWhenSeveralAreKnown() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(account: nil, status: "error")]),
            client(secondID, "Linux", providers: [provider(account: "a@example.com"), provider(account: "b@example.com")]),
        ]))
        XCTAssertEqual(merged.providers.map(\.identityKey), ["claude|unknown", "claude|a@example.com", "claude|b@example.com"])
    }

    func testNotSignedInIsDroppedWhenAnotherMachineIsSignedIn() throws {
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(account: nil, status: "not_signed_in"), provider(id: "openai", account: nil, status: "not_signed_in")]),
            client(secondID, "Linux", providers: [provider(account: "user@example.com")]),
        ]))
        XCTAssertEqual(merged.providers.map(\.identityKey), ["openai|unknown", "claude|user@example.com"])
    }

    func testAPICostIsSummedPerAccount() throws {
        let cost = APICost(weekUSD: 2, monthUSD: 5, priced: 1, unpriced: 0, machines: 7)
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(apiCost: cost)]),
            client(secondID, "Linux", providers: [provider(apiCost: cost)]),
        ]))
        let total = try XCTUnwrap(merged.providers[0].apiCost)
        XCTAssertEqual(total.weekUSD, 4)
        XCTAssertEqual(total.monthUSD, 10)
        // Each snapshot counts as one machine, whatever it claimed.
        XCTAssertEqual(total.machines, 2)
    }

    func testNewestBreakdownWins() throws {
        func split(_ asOf: Date?, _ title: String) -> UsageBreakdown {
            UsageBreakdown(title: title, window: "weekly", asOf: asOf, rows: [])
        }
        let merged = try XCTUnwrap(ClientMerge.snapshot([
            client(firstID, "Mac", providers: [provider(breakdown: split(referenceNow, "old"))]),
            client(secondID, "Linux", providers: [provider(breakdown: split(referenceNow.addingTimeInterval(60), "new"))]),
        ]))
        XCTAssertEqual(merged.providers[0].sourceClientID, firstID)
        XCTAssertEqual(merged.providers[0].breakdown?.title, "new")
    }

    func testHistoryFollowsTheChosenSourceAndIsKeyedByIdentity() throws {
        func history(_ percent: Double) -> UsageHistory {
            UsageHistory(generatedAt: referenceNow, series: [
                UsageSeries(provider: "claude", window: "five_hour", resetsAt: nil, windowSeconds: nil,
                            points: [[referenceNow.timeIntervalSince1970, percent]], prediction: nil),
                UsageSeries(provider: "openai", window: "five_hour", resetsAt: nil, windowSeconds: nil,
                            points: [], prediction: nil),
            ])
        }
        let clients = [
            client(firstID, "Mac", providers: [provider(status: "error")], history: history(1)),
            client(secondID, "Linux", providers: [provider()], history: history(2)),
        ]
        let snapshot = try XCTUnwrap(ClientMerge.snapshot(clients))
        let merged = try XCTUnwrap(ClientMerge.history(clients, snapshot: snapshot))
        XCTAssertEqual(merged.series.count, 1)
        XCTAssertEqual(merged.series[0].provider, "claude|user@example.com")
        XCTAssertEqual(merged.series[0].samples.first?.percent, 2)
        XCTAssertEqual(merged.generatedAt, snapshot.generatedAt)

        XCTAssertNil(ClientMerge.history(clients, snapshot: nil))
    }
}
