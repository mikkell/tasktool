import XCTest
@testable import TaskToolCore

final class GitHubCredentialsTests: XCTestCase {
    func testRemoteValidationAndCredentialScope() throws {
        let remote = try GitHubRemote("https://github.com/example/tasks")
        XCTAssertEqual(remote.url.absoluteString, "https://github.com/example/tasks.git")
        XCTAssertTrue(remote.acceptsCredentialURL("https://github.com/example/tasks.git"))
        for value in [
            "http://github.com/example/tasks", "https://github.com.evil.invalid/example/tasks",
            "https://user:secret@github.com/example/tasks", "https://github.com:443/example/tasks",
            "https://github.com/example/tasks?token=test", "https://github.com/example/tasks#fragment",
            "https://github.com/example/tasks/extra", "git@github.com:example/tasks.git"
        ] {
            XCTAssertThrowsError(try GitHubRemote(value))
            XCTAssertFalse(remote.acceptsCredentialURL(value))
        }
        XCTAssertFalse(remote.acceptsCredentialURL("https://github.com/example/other.git"))
    }

    func testKeychainSaveUpdateReadAndRemove() throws {
        let remote = try GitHubRemote("https://github.com/tasktool-tests/\(UUID().uuidString)")
        let store = KeychainGitHubTokenStore()
        defer { try? store.remove(for: remote) }
        XCTAssertThrowsError(try store.save(" ", for: remote))
        try store.save("test-only-placeholder", for: remote)
        XCTAssertEqual(try store.token(for: remote), "test-only-placeholder")
        try store.save("updated-test-placeholder", for: remote)
        XCTAssertEqual(try store.token(for: remote), "updated-test-placeholder")
        try store.remove(for: remote)
        XCTAssertThrowsError(try store.token(for: remote))
    }
}
