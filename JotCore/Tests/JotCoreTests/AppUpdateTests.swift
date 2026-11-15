// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CryptoKit
import XCTest
@testable import JotCore

final class AppUpdateTests: XCTestCase {
    private final class MockProtocol: URLProtocol, @unchecked Sendable {
        static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, headers, data) = try Self.handler!(request)
                var merged = ["Content-Type": "application/json"]
                for (key, value) in headers { merged[key] = value }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: merged
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func session(handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        sessionWithHeaders { request in
            let (status, data) = try handler(request)
            return (status, [:], data)
        }
    }

    private func sessionWithHeaders(handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> URLSession {
        MockProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: "automaticallyChecksForUpdates")
        UserDefaults.standard.removeObject(forKey: "lastUpdateCheckAt")
    }

    func testVersionParsingAndComparison() {
        XCTAssertEqual(AppVersion("v0.6.2"), AppVersion("0.6.2"))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertLessThan(AppVersion("0.6.2")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0.0")!)
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("0.6.2-beta.1"))
        XCTAssertNil(AppVersion("1..0"))
    }

    func testShouldCheckRespectsPreferenceAndInterval() {
        let now = Date(timeIntervalSince1970: 200_000)
        XCTAssertFalse(AppUpdateChecker.shouldCheck(automaticallyChecks: false, lastCheckedAt: nil, now: now))
        XCTAssertTrue(AppUpdateChecker.shouldCheck(automaticallyChecks: true, lastCheckedAt: nil, now: now))

        let twentyThreeHoursAgo = now.addingTimeInterval(-82_800)
        XCTAssertFalse(AppUpdateChecker.shouldCheck(automaticallyChecks: true, lastCheckedAt: twentyThreeHoursAgo, now: now))

        let twentyFourHoursAgo = now.addingTimeInterval(-86_400)
        XCTAssertTrue(AppUpdateChecker.shouldCheck(automaticallyChecks: true, lastCheckedAt: twentyFourHoursAgo, now: now))
    }

    func testValidateInstallTargetChecksBundleTranslocationAndWritability() {
        XCTAssertNoThrow(try AppUpdateChecker.validateInstallTarget(
            bundleURL: URL(fileURLWithPath: "/Applications/Jot.app"),
            isWritable: { _ in true }
        ))
        XCTAssertThrowsError(try AppUpdateChecker.validateInstallTarget(
            bundleURL: URL(fileURLWithPath: "/Applications/Jot"),
            isWritable: { _ in true }
        ))
        XCTAssertThrowsError(try AppUpdateChecker.validateInstallTarget(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Jot.app"),
            isWritable: { _ in true }
        ))
        XCTAssertThrowsError(try AppUpdateChecker.validateInstallTarget(
            bundleURL: URL(fileURLWithPath: "/Applications/Jot.app"),
            isWritable: { path in path != "/Applications" }
        ))
    }

    func testParseReleaseFindsNewerZipAsset() throws {
        let sha = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name": "v0.7.0",
          "draft": false,
          "prerelease": false,
          "body": "Bug fixes and improvements.",
          "html_url": "https://github.com/top/jot/releases/tag/v0.7.0",
          "assets": [
            { "name": "notes.txt", "browser_download_url": "https://github.com/top/jot/releases/download/v0.7.0/notes.txt", "state": "uploaded", "size": 100 },
            { "name": "Jot-0.7.0-UNNOTARIZED.zip", "browser_download_url": "https://github.com/top/jot/releases/download/v0.7.0/Jot-0.7.0-UNNOTARIZED.zip", "state": "starter", "size": 123 },
            { "name": "Jot-0.7.0-UNNOTARIZED.zip", "browser_download_url": "https://github.com/top/jot/releases/download/v0.7.0/Jot-0.7.0-UNNOTARIZED.zip", "state": "uploaded", "size": 9079549, "digest": "sha256:\(sha)" }
          ]
        }
        """.data(using: .utf8)!

        let result = try AppUpdateChecker.parseRelease(data: json, currentVersion: "0.6.2")
        XCTAssertEqual(
            result,
            .available(UpdateRelease(
                version: "0.7.0",
                tagName: "v0.7.0",
                downloadURL: URL(string: "https://github.com/top/jot/releases/download/v0.7.0/Jot-0.7.0-UNNOTARIZED.zip")!,
                releaseNotes: "Bug fixes and improvements.",
                htmlURL: URL(string: "https://github.com/top/jot/releases/tag/v0.7.0")!,
                expectedSize: 9_079_549,
                sha256: sha
            ))
        )
    }

    func testVerifyDownloadedArchiveChecksSizeAndSHA256() throws {
        let payload = Data("zip-archive-bytes".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let digestHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try AppUpdateChecker.verifyDownloadedArchive(
            at: url,
            expectedSize: Int64(payload.count),
            expectedSHA256: digestHex
        ))
        XCTAssertThrowsError(try AppUpdateChecker.verifyDownloadedArchive(
            at: url,
            expectedSize: Int64(payload.count + 1),
            expectedSHA256: digestHex
        )) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }
        XCTAssertThrowsError(try AppUpdateChecker.verifyDownloadedArchive(
            at: url,
            expectedSize: Int64(payload.count),
            expectedSHA256: String(repeating: "0", count: 64)
        )) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }
    }

    func testParseReleaseReturnsUpToDateForSameOrPrerelease() throws {
        let sameVersion = """
        { "tag_name": "v0.6.2", "draft": false, "prerelease": false, "assets": [] }
        """.data(using: .utf8)!
        XCTAssertEqual(try AppUpdateChecker.parseRelease(data: sameVersion, currentVersion: "0.6.2"), .upToDate)

        let prerelease = """
        { "tag_name": "v0.7.0", "draft": false, "prerelease": true, "assets": [] }
        """.data(using: .utf8)!
        XCTAssertEqual(try AppUpdateChecker.parseRelease(data: prerelease, currentVersion: "0.6.2"), .upToDate)
    }

    func testParseReleaseRequiresHttpsZipAsset() {
        let missingZip = """
        { "tag_name": "v0.7.0", "draft": false, "prerelease": false, "assets": [] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AppUpdateChecker.parseRelease(data: missingZip, currentVersion: "0.6.2")) { error in
            XCTAssertEqual(error as? AppUpdateError, .missingZipAsset)
        }

        let insecureZip = """
        {
          "tag_name": "v0.7.0",
          "draft": false,
          "prerelease": false,
          "assets": [
            { "name": "Jot-0.7.0-UNNOTARIZED.zip", "browser_download_url": "http://example.com/Jot.zip" }
          ]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try AppUpdateChecker.parseRelease(data: insecureZip, currentVersion: "0.6.2")) { error in
            XCTAssertEqual(error as? AppUpdateError, .missingZipAsset)
        }
    }

    func testFetchLatestUpdateSendsHeadersAndHandlesErrors() async throws {
        let url = URL(string: "https://api.github.com/repos/top/jot/releases/latest")!
        let okSession = session { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Jot/0.6.2")
            return (200, Data(#"{"tag_name":"v0.6.2","assets":[]}"#.utf8))
        }
        let result = try await AppUpdateChecker.fetchLatestUpdate(releasesURL: url, currentVersion: "0.6.2", session: okSession)
        XCTAssertEqual(result, .upToDate)

        let failSession = session { _ in (503, Data()) }
        do {
            _ = try await AppUpdateChecker.fetchLatestUpdate(releasesURL: url, currentVersion: "0.6.2", session: failSession)
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .httpError(503))
        }

        let rateLimitedSession = sessionWithHeaders { _ in
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1794768195"], Data())
        }
        do {
            _ = try await AppUpdateChecker.fetchLatestUpdate(releasesURL: url, currentVersion: "0.6.2", session: rateLimitedSession)
            XCTFail("Expected rate limit error")
        } catch {
            XCTAssertEqual(error as? AppUpdateError, .rateLimited(Date(timeIntervalSince1970: 1_794_768_195)))
        }
    }

    func testUpdateSettingsDefaultsAndPersistence() {
        let store = SettingsStore()
        XCTAssertTrue(store.automaticallyChecksForUpdates)
        XCTAssertNil(store.lastUpdateCheckAt)

        store.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(SettingsStore().automaticallyChecksForUpdates)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.setLastUpdateCheckAt(now)
        XCTAssertEqual(SettingsStore().lastUpdateCheckAt, now)
    }
}
