import SwiftUI

@main
struct FitFindApp: App {
    @StateObject private var store = OutfitStore()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
                .tint(Color(red: 0.04, green: 0.43, blue: 0.33))
        }
    }
}
