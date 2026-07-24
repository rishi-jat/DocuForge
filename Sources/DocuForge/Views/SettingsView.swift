import SwiftUI
import DocuForgeCore

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var envLines: [String] = []

    var body: some View {
        Form {
            Section("Output") {
                Toggle("Save results to Downloads/DocuForge", isOn: $app.preferredOutputInDownloads)
                Text("When off, outputs go to a temporary folder you can still reveal in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Engines") {
                if envLines.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(envLines, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                Text("Grant Automation access for Pages/Keynote/Numbers in System Settings → Privacy & Security → Automation for high-fidelity iWork export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "DocuForge")
                LabeledContent("Engine", value: "PDFKit · Vision · ImageIO · textutil · iWork · Quick Look")
                Text("Offline-first. LibreOffice is used only if you install it separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
        .padding()
        .task {
            envLines = await app.conversion.environmentSummary()
        }
    }
}
