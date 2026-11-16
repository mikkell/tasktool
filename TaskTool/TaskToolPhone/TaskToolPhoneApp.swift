import SwiftUI
import TaskToolCore

@main
struct TaskToolPhoneApp: App {
    @StateObject private var store = MobileTaskStore()

    var body: some Scene {
        WindowGroup {
            PhoneContentView()
                .environmentObject(store)
        }
    }
}
