import SwiftUI

@main
struct FitFindApp: App {
    @StateObject private var store = OutfitStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
                .tint(FitStyle.accent)
                .preferredColorScheme(.dark)
        }
    }
}
