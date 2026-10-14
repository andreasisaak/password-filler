import Foundation

extension StoredItem {
    /// Example item for tests; only the fields a test cares about need values.
    static func example(
        id: String = "1",
        title: String = "T",
        hostnames: [String],
        username: String = "user",
        password: String = "pass",
        sourceVault: String? = nil,
        cachedAt: Date = Date()
    ) -> StoredItem {
        StoredItem(
            itemId: id,
            title: title,
            hostnames: hostnames,
            username: username,
            password: password,
            sourceVault: sourceVault,
            cachedAt: cachedAt
        )
    }
}
