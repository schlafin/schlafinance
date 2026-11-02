import SwiftUI

@main
struct SchlafinanceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("schlafinance") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await model.refreshLoop() }
        }

        Settings {
            Form {
                Toggle("Show times in US Eastern", isOn: $model.showEastern)
            }
            .padding(20)
            .frame(width: 320)
            .preferredColorScheme(.dark)
        }
    }
}
