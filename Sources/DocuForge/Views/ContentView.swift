import SwiftUI
import DocuForgeCore

struct ContentView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $app.selectedTool)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(app.selectedTool.title)
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
