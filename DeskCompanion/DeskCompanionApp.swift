import SwiftUI

@main
struct DeskCompanionApp: App {
    @StateObject private var viewModel = DeskCompanionViewModel()

    var body: some Scene {
        WindowGroup {
            DeskCompanionContentView(viewModel: viewModel)
                .frame(minWidth: 420, minHeight: 480)
        }
    }
}
