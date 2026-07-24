import SwiftUI
import DocuForgeCore

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        // HSplitView is more reliable than NavigationSplitView for SPM/macOS apps:
        // detail content was collapsing / not painting under NavigationSplitView.
        HSplitView {
            SidebarView(selection: $app.selectedTool)
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                .background(Color(nsColor: .windowBackgroundColor))

            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selectedTool {
        case .edit: EditView()
        case .convert: ConvertView()
        case .merge: MergeView()
        case .split: SplitView()
        case .compress: CompressView()
        case .ocr: OCRView()
        case .protect: ProtectView()
        case .watermark: WatermarkView()
        case .pages: PageManageView()
        case .batch: BatchView()
        }
    }
}
