import XCTest

/// Pure parts of SharedStore.swift: pairing links, addresses and settings.
/// Nothing here touches the App Group defaults.
final class SharedStoreModelsTests: XCTestCase {
    // MARK: - CompanionConfig

    func testNormalizedAddsSchemeAndStripsSlashes() {
        XCTAssertEqual(CompanionConfig.normalized("192.168.1.20:47300//"), "http://192.168.1.20:47300")
        XCTAssertEqual(CompanionConfig.normalized(" https://box.example.com/ "), "https://box.example.com")
        XCTAssertNil(CompanionConfig.normalized("   "))
        XCTAssertNil(CompanionConfig.normalized(nil))
    }

    func testIsRemoteAddress() {
        for local in ["192.168.1.20:47300", "10.0.0.5", "172.16.0.1", "172.31.255.255", "127.0.0.1",
                      "169.254.1.1", "my-mac.local", "localhost", "http://devbox:47300"] {
            XCTAssertFalse(CompanionConfig.isRemoteAddress(local), local)
        }
        for remote in ["100.64.0.10:47300", "my-mac.tailnet.ts.net", "172.32.0.1", "8.8.8.8", "box.example.com"] {
            XCTAssertTrue(CompanionConfig.isRemoteAddress(remote), remote)
        }
        XCTAssertFalse(CompanionConfig.isRemoteAddress(""))
    }

    func testParsesAPairingCodeLink() throws {
        let config = try XCTUnwrap(CompanionConfig(pairingString:
            " meterkat://pair?code=FAKE-CODE&local=192.168.1.20:47300&remote=100.64.0.10:47300&name=%20testbox%20 "))
        XCTAssertEqual(config.pairingCode, "FAKE-CODE")
        XCTAssertEqual(config.token, "")
        XCTAssertEqual(config.localURL, "http://192.168.1.20:47300")
        XCTAssertEqual(config.remoteURL, "http://100.64.0.10:47300")
        XCTAssertEqual(config.name, "testbox")
        XCTAssertTrue(config.isComplete)
        XCTAssertEqual(config.routes, [CompanionRoute(kind: .local, baseURL: "http://192.168.1.20:47300"),
                                       CompanionRoute(kind: .remote, baseURL: "http://100.64.0.10:47300")])
    }

    func testSortsALegacySingleAddressLink() throws {
        let local = try XCTUnwrap(CompanionConfig(pairingString: "meterkat://pair?url=http://192.168.1.20:47300&token=fake-token"))
        XCTAssertEqual(local.localURL, "http://192.168.1.20:47300")
        XCTAssertNil(local.remoteURL)
        XCTAssertEqual(local.token, "fake-token")
        XCTAssertNil(local.pairingCode)

        let remote = try XCTUnwrap(CompanionConfig(pairingString: "meterkat://pair?url=http://100.64.0.10:47300&token=fake-token"))
        XCTAssertNil(remote.localURL)
        XCTAssertEqual(remote.remoteURL, "http://100.64.0.10:47300")
    }

    func testRejectsBadPairingLinks() {
        XCTAssertNil(CompanionConfig(pairingString: "https://pair?code=FAKE&local=10.0.0.1"))
        XCTAssertNil(CompanionConfig(pairingString: "meterkat://pair?local=10.0.0.1"))
        XCTAssertNil(CompanionConfig(pairingString: "meterkat://pair?code=&local=10.0.0.1"))
        XCTAssertNil(CompanionConfig(pairingString: "meterkat://pair?code=FAKE"))
        XCTAssertNil(CompanionConfig(pairingString: "meterkat://pair?code=FAKE&token=fake-token&local=10.0.0.1"))
    }

    func testDecodesAVersionOneConfig() throws {
        let config = try decodeUsage(CompanionConfig.self, #"{"baseURL": "100.64.0.10:47300/", "token": " fake-token "}"#)
        XCTAssertNil(config.localURL)
        XCTAssertEqual(config.remoteURL, "http://100.64.0.10:47300")
        XCTAssertEqual(config.token, "fake-token")
    }

    func testEncodingLeavesOutThePairingCodeAndName() throws {
        var config = CompanionConfig(localURL: "10.0.0.1", remoteURL: nil, token: "fake-token", pairingCode: "FAKE-CODE")
        config.name = "testbox"
        let decoded = try JSONDecoder.usage.decode(CompanionConfig.self, from: JSONEncoder.usage.encode(config))
        XCTAssertEqual(decoded.localURL, "http://10.0.0.1")
        XCTAssertEqual(decoded.token, "fake-token")
        XCTAssertNil(decoded.pairingCode)
        XCTAssertNil(decoded.name)
    }

    // MARK: - PairedClient names

    func testPlaceholderNames() {
        XCTAssertTrue(PairedClient.isPlaceholderName(PairedClient.defaultName))
        XCTAssertTrue(PairedClient.isPlaceholderName(" "))
        XCTAssertTrue(PairedClient.isPlaceholderName("Client 2"))
        XCTAssertFalse(PairedClient.isPlaceholderName("Client "))
        XCTAssertFalse(PairedClient.isPlaceholderName("Client two"))
        XCTAssertFalse(PairedClient.isPlaceholderName("Work Mac"))
    }

    func testAdoptHostNameOnlyReplacesPlaceholders() {
        let config = CompanionConfig(localURL: "10.0.0.1", remoteURL: nil, token: "fake-token")
        var client = PairedClient(name: "Client 3", config: config)
        client.adoptHostName("  ")
        XCTAssertEqual(client.name, "Client 3")
        client.adoptHostName(" testbox ")
        XCTAssertEqual(client.name, "testbox")
        client.adoptHostName("otherbox")
        XCTAssertEqual(client.name, "testbox")
    }

    // MARK: - Settings

    func testSettingsDecodeWithMissingKeys() throws {
        let settings = try decodeUsage(UsageSettings.self, #"{"providers": {"openai": {"enabled": false}}}"#)
        XCTAssertEqual(settings.usageStyle, .bars)
        XCTAssertEqual(settings.barMode, .used)
        XCTAssertFalse(settings.isEnabled("openai"))
        XCTAssertTrue(settings.isEnabled("claude"))
        XCTAssertTrue(settings.isEnabled("from_a_newer_companion"))
        XCTAssertEqual(settings[.openai].limitThreshold, 80)
        XCTAssertEqual(settings[.openai].resetAlertWindows, ["five_hour"])
        XCTAssertTrue(settings[.openai].announcesReset(of: "five_hour"))
        XCTAssertFalse(settings[.openai].announcesReset(of: "weekly"))
        XCTAssertFalse(settings.enabledProviders.contains(.openai))
        XCTAssertEqual(settings.enabledProviders.count, ProviderID.allCases.count - 1)
    }

    func testAddingNewProviders() throws {
        let snapshot = UsageSnapshot(generatedAt: referenceNow, host: nil, companionVersion: nil, providers: [
            provider(id: "claude"),
            provider(id: "openrouter", status: "ok"),
            provider(id: "gemini", status: "not_signed_in"),
        ])
        // Nothing saved yet: onboarding sets the providers, so no change.
        XCTAssertNil(UsageSettings().addingNewProviders(from: snapshot))

        var saved = UsageSettings()
        saved[.claude].enabled = true
        let updated = try XCTUnwrap(saved.addingNewProviders(from: snapshot))
        XCTAssertEqual(updated.providers["openrouter"]?.enabled, true)
        XCTAssertEqual(updated.providers["gemini"]?.enabled, false)
        XCTAssertNil(updated.providers["copilot"])
        XCTAssertNil(updated.addingNewProviders(from: snapshot))
    }
}
