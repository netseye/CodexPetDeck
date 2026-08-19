import SwiftUI

@main
struct CodexPetDeckApp: App {
    /// VM 持有在 Scene 层 — headless 恢复(无窗口)时 tail 也要跑,
    /// 不能依赖 ContentView body 评估。
    @StateObject private var deck = PetDeckViewModel()

    var body: some Scene {
        WindowGroup {
            PetDeckView(deck: deck)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1_080, height: 700)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
