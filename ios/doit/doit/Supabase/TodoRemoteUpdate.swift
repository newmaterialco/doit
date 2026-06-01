import Foundation

extension Notification.Name {
    /// Posted when a push arrives while the app is foregrounded, or when we
    /// want views to refetch a specific todo. `userInfo["todo_id"]` is a `UUID`.
    static let todoRemoteUpdate = Notification.Name("doit.todoRemoteUpdate")
}

enum TodoRemoteUpdate {
    static func post(todoID: UUID) {
        NotificationCenter.default.post(
            name: .todoRemoteUpdate,
            object: nil,
            userInfo: ["todo_id": todoID]
        )
    }

    static func todoID(from notification: Notification) -> UUID? {
        notification.userInfo?["todo_id"] as? UUID
    }
}
