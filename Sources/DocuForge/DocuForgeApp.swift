import SwiftUI
import DocuForgeCore

@main
struct DocuForgeApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Tools") {
                ForEach(ToolKind.allCases) { tool in
                    Button(tool.title) {
                        appModel.selectedTool = tool
                    }
                    .keyboardShortcut(tool.shortcutKey, modifiers: [.command, .shift])
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}

private extension ToolKind {
    var shortcutKey: KeyEquivalent {
        switch self {
        case .edit: return "e"
        case .convert: return "c"
        case .merge: return "m"
        case .split: return "s"
        case .compress: return "z"
        case .ocr: return "o"
        case .protect: return "p"
        case .watermark: return "w"
        case .pages: return "g"
        case .batch: return "b"
        }
    }
}
