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
import Foundation

public struct AppVersion: Comparable, Equatable, Sendable {
    public let components: [Int]

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let body = (trimmed.first == "v" || trimmed.first == "V") ? String(trimmed.dropFirst()) : trimmed
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part) else {
                return nil
            }
            parsed.append(value)
        }
        self.components = parsed
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

public struct UpdateRelease: Equatable, Sendable {
    public let version: String
    public let tagName: String
    public let downloadURL: URL
    public let releaseNotes: String?
    public let htmlURL: URL?
    public let expectedSize: Int64?
    public let sha256: String?

    public init(
        version: String,
        tagName: String,
        downloadURL: URL,
        releaseNotes: String?,
        htmlURL: URL?,
        expectedSize: Int64? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.tagName = tagName
        self.downloadURL = downloadURL
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.expectedSize = expectedSize
        self.sha256 = sha256
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
}

public enum AppUpdateError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case httpError(Int)
    case rateLimited(Date?)
    case invalidVersion(String)
    case missingZipAsset
    case checksumMismatch
    case notUpdatableLocation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unreadable response."
        case .httpError(404):
            return "No published release found on GitHub (HTTP 404)."
        case .httpError(let status):
            return "GitHub returned HTTP \(status)."
        case .rateLimited(let resetAt):
            if let resetAt {
                let time = resetAt.formatted(date: .omitted, time: .shortened)
                return "GitHub API rate limit reached. Try again after \(time)."
            }
            return "GitHub API rate limit reached. Try again later."
        case .invalidVersion(let raw):
            return "Could not parse version '\(raw)'."
        case .missingZipAsset:
            return "The latest release does not include a .zip download."
        case .checksumMismatch:
            return "Downloaded update failed integrity verification."
        case .notUpdatableLocation(let detail):
            return detail
        }
    }
}

public enum AppUpdateChecker {
    public static let checkInterval: TimeInterval = 86_400

    public static func shouldCheck(
        automaticallyChecks: Bool,
        lastCheckedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard automaticallyChecks else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= checkInterval
    }

    public static func validateInstallTarget(
        bundleURL: URL,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) throws {
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw AppUpdateError.notUpdatableLocation("Jot is not running from an application bundle.")
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            throw AppUpdateError.notUpdatableLocation("Move Jot.app to Applications before updating automatically.")
        }
        let parentPath = bundleURL.deletingLastPathComponent().path
        guard isWritable(parentPath), isWritable(bundleURL.path) else {
            throw AppUpdateError.notUpdatableLocation("Jot cannot modify \(bundleURL.path). Move Jot.app to Applications or a writable folder.")
        }
    }

    public static func parseRelease(data: Data, currentVersion: String) throws -> UpdateCheckResult {
        guard let current = AppVersion(currentVersion) else {
            throw AppUpdateError.invalidVersion(currentVersion)
        }
        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        if payload.draft == true || payload.prerelease == true {
            return .upToDate
        }
        guard let remote = AppVersion(payload.tag_name) else {
            throw AppUpdateError.invalidVersion(payload.tag_name)
        }
        guard remote > current else {
            return .upToDate
        }
        guard let asset = payload.assets.first(where: {
            ($0.state == nil || $0.state == "uploaded")
                && ($0.size ?? 1) > 0
                && $0.name.lowercased().hasSuffix(".zip")
                && $0.browser_download_url.scheme?.lowercased() == "https"
        }) else {
            throw AppUpdateError.missingZipAsset
        }

        let trimmedTag = payload.tag_name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVersion = (trimmedTag.first == "v" || trimmedTag.first == "V")
            ? String(trimmedTag.dropFirst())
            : trimmedTag
        return .available(UpdateRelease(
            version: normalizedVersion,
            tagName: trimmedTag,
            downloadURL: asset.browser_download_url,
            releaseNotes: payload.body,
            htmlURL: payload.html_url,
            expectedSize: asset.size,
            sha256: parseSHA256(asset.digest)
        ))
    }

    public static func verifyDownloadedArchive(
        at fileURL: URL,
        expectedSize: Int64?,
        expectedSHA256: String?
    ) throws {
        if let expectedSize {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let actualSize = (attrs[.size] as? NSNumber)?.int64Value
            guard actualSize == expectedSize else {
                throw AppUpdateError.checksumMismatch
            }
        }
        if let expectedSHA256 {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1_048_576)
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            let digestHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digestHex == expectedSHA256.lowercased() else {
                throw AppUpdateError.checksumMismatch
            }
        }
    }

    private static func parseSHA256(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              trimmed.hasPrefix("sha256:") else {
            return nil
        }
        let hex = String(trimmed.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return hex
    }

    public static func fetchLatestUpdate(
        releasesURL: URL,
        currentVersion: String,
        session: URLSession? = nil
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Jot/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let ownsSession = (session == nil)
        let effectiveSession = session ?? URLSession(configuration: OpenAIClient.makeEphemeralConfiguration(timeoutForResource: 15))
        defer {
            if ownsSession {
                effectiveSession.finishTasksAndInvalidate()
            }
        }

        let (data, response) = try await effectiveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map { Date(timeIntervalSince1970: $0) }
            throw AppUpdateError.rateLimited(reset)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.httpError(http.statusCode)
        }
        return try parseRelease(data: data, currentVersion: currentVersion)
    }
}

private struct GitHubReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let state: String?
        let size: Int64?
        let digest: String?
    }

    let tag_name: String
    let draft: Bool?
    let prerelease: Bool?
    let body: String?
    let html_url: URL?
    let assets: [Asset]
}
