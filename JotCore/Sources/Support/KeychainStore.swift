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

import Foundation
import Security

/// API-key storage per TN3137: SecItem + data-protection keychain when the build
/// carries the keychain-access-groups entitlement (provisioned/notarized builds),
/// with a graceful fallback to the login keychain for dev and fork builds that
/// lack it (errSecMissingEntitlement, -34018). Never UserDefaults/JSON
/// (Superwhisper's documented failure).
public enum KeychainStore {
    private static let service = "org.ie9.app"
    private static let account = "openai-api-key"

    private static func account(for providerId: String) -> String {
        "openai-api-key-\(providerId)"
    }

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func loadKey(account: String) -> String? {
        for dataProtection in [true, false] {
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    public static func loadAPIKey() -> String? {
        loadKey(account: account)
    }

    public static func loadAPIKey(forProviderId providerId: String) -> String? {
        if let key = loadKey(account: account(for: providerId)), !key.isEmpty {
            return key
        }
        if providerId == "default" || providerId.isEmpty {
            return loadAPIKey()
        }
        return nil
    }

    @discardableResult
    private static func saveKey(_ key: String, account: String, label: String) -> Bool {
        deleteKey(account: account)
        for dataProtection in [true, false] {
            var attributes = baseQuery(account: account, dataProtection: dataProtection)
            attributes[kSecAttrLabel as String] = label
            attributes[kSecValueData as String] = Data(key.utf8)
            if dataProtection {
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess {
                Log.permissions.info("KeychainStore: key saved for \(account, privacy: .public) (\(dataProtection ? "data-protection" : "login", privacy: .public) keychain)")
                return true
            }
            if status != errSecMissingEntitlement {
                Log.permissions.error("KeychainStore: save failed for \(account, privacy: .public) (\(status))")
                return false
            }
            // -34018: unprovisioned build — fall through to the login keychain.
        }
        return false
    }

    @discardableResult
    public static func saveAPIKey(_ key: String) -> Bool {
        let success = saveKey(key, account: account, label: "Jot — API key")
        if success {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        }
        return success
    }

    @discardableResult
    public static func saveAPIKey(_ key: String, forProviderId providerId: String) -> Bool {
        let success = saveKey(key, account: account(for: providerId), label: "Jot — API key (\(providerId))")
        if success {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        }
        return success
    }

    @discardableResult
    private static func deleteKey(account: String) -> Bool {
        var deleted = false
        for dataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
            deleted = deleted || status == errSecSuccess
        }
        return deleted
    }

    @discardableResult
    public static func deleteAPIKey(notify: Bool = false) -> Bool {
        let deleted = deleteKey(account: account)
        // saveAPIKey's internal delete-before-add must not announce "key removed"
        // mid-save — only user-initiated removal notifies.
        if deleted, notify {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        }
        return deleted
    }

    @discardableResult
    public static func deleteAPIKey(forProviderId providerId: String, notify: Bool = false) -> Bool {
        let deleted = deleteKey(account: account(for: providerId))
        if deleted, notify {
            NotificationCenter.default.post(name: .gtSettingDidChange, object: "apiKey")
        }
        return deleted
    }

    /// Dev bootstrap: if ~/.config/jot/openai-apikey.dev
    /// exists, migrate its contents into the Keychain and DELETE the file. Lets
    /// contributors seed a key without any UI, without leaving plaintext behind.
    public static func migrateDevKeyFileIfPresent() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jot/openai-apikey.dev")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if saveAPIKey(key, forProviderId: "default") {
            try? FileManager.default.removeItem(at: fileURL)
            Log.permissions.info("KeychainStore: migrated dev key file into Keychain (file deleted)")
        }
    }
}
