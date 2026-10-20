import AppleTasksServerCore
import XCTest

final class KeychainSecretTests: XCTestCase {
    /// Read-only: a name that is not in the login Keychain must return nil.
    /// Never writes.
    func testMissingAccountReturnsNil() {
        let name = "apple-tasks.test.nonexistent.\(UUID().uuidString)"
        XCTAssertNil(KeychainSecret.read(account: name))
    }
}
