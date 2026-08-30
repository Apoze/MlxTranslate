import SwiftUI

/// Fenêtre principale : deux onglets (Offline / Live).
struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            OfflineView(model: model)
                .tabItem { Label("Offline", systemImage: "film") }
            LiveView(model: model)
                .tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
        }
        .frame(minWidth: 540, minHeight: 400)
    }
}
