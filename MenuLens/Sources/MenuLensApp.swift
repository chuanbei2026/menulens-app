import SwiftUI

@main
struct MenuLensApp: App {
    @StateObject private var localization = Localization.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // A fresh install opens in the device's language when we speak it.
        Localization.registerDeviceDefault()
        // Listens for StoreKit transactions from launch on, so a purchase
        // paid but not yet credited (app killed, offline) is retried.
        _ = CreditShop.shared
        // Learns the App Store region (and its model catalog) before the
        // first request needs the X-Storefront header.
        _ = RegionStore.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Our own strings come from `L(...)`; this is for the parts
                // SwiftUI formats itself (dates, numbers, search fields).
                .environment(\.locale, localization.locale)
        }
        // Launch and every return to the foreground: the membership's
        // current entitlement goes to the server (renewals, lapses).
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { Task { await CreditShop.shared.syncSubscription() } }
        }
    }
}
