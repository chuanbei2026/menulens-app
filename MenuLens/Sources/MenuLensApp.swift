import SwiftUI

@main
struct MenuLensApp: App {
    @StateObject private var localization = Localization.shared

    init() {
        // A fresh install opens in the device's language when we speak it.
        Localization.registerDeviceDefault()
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
