import SwiftUI

@main
struct MenuLensApp: App {
    @StateObject private var localization = Localization.shared

    init() {
        // A fresh install opens in the device's language when we speak it.
        Localization.registerDeviceDefault()
        // Listens for StoreKit transactions from launch on, so a purchase
        // paid but not yet credited (app killed, offline) is retried.
        _ = CreditShop.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Our own strings come from `L(...)`; this is for the parts
                // SwiftUI formats itself (dates, numbers, search fields).
                .environment(\.locale, localization.locale)
        }
    }
}
