import SwiftUI
import SwiftData

@main
struct JableTVMobileApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(viewModel)
        }
        .modelContainer(for: [ServerConfiguration.self, CatalogPageCache.self])
    }
}
