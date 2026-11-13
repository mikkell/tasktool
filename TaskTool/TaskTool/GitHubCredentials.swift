import Foundation
import Security

enum GitHubCredentialError: Error {
    case invalidRemote
    case emptyToken
    case keychain(OSStatus)
    case missingToken
}

struct GitHubRemote: Equatable {
    let url: URL

    init(_ value: String) throws {
        guard let components = URLComponents(string: value),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw GitHubCredentialError.invalidRemote
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { throw GitHubCredentialError.invalidRemote }
        let owner = String(parts[1])
        var name = String(parts[2])
        if name.hasSuffix(".git") { name.removeLast(4) }
        for part in [owner, name] {
            guard part != ".", part != "..", !part.isEmpty,
                  part.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                throw GitHubCredentialError.invalidRemote
            }
        }
        guard let url = URL(string: "https://github.com/\(owner)/\(name).git") else {
            throw GitHubCredentialError.invalidRemote
        }
        self.url = url
    }

    func acceptsCredentialURL(_ value: String) -> Bool {
        (try? GitHubRemote(value)) == self
    }
}

protocol GitHubTokenStore {
    func token(for remote: GitHubRemote) throws -> String
}

struct KeychainGitHubTokenStore: GitHubTokenStore {
    private let service = "com.tasktool.github-git-token"

    private func query(_ remote: GitHubRemote) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: remote.url.absoluteString
        ]
    }

    func save(_ token: String, for remote: GitHubRemote) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubCredentialError.emptyToken
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(remote) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(remote)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw GitHubCredentialError.keychain(result) }
        } else if status != errSecSuccess {
            throw GitHubCredentialError.keychain(status)
        }
    }

    func token(for remote: GitHubRemote) throws -> String {
        var item = query(remote)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { throw GitHubCredentialError.missingToken }
        guard status == errSecSuccess else { throw GitHubCredentialError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw GitHubCredentialError.missingToken
        }
        return token
    }

    func remove(for remote: GitHubRemote) throws {
        let status = SecItemDelete(query(remote) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubCredentialError.keychain(status)
        }
    }
}
