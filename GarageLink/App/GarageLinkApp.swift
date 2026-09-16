import SwiftUI

@main
struct GarageLinkApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(env)
                .environmentObject(env.registry)
                .environmentObject(env.log)
                .environmentObject(env.ble)
                .tint(.orange)
                .onOpenURL { url in
                    if let link = PairingLink(url: url) { env.pendingLink = link }
                }
        }
    }
}
