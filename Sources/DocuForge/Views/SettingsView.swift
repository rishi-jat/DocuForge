import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Form {
            Section("Output") {
                Toggle("Save results to Downloads/DocuForge", isOn: $app.preferredOutputInDownloads)
                Text("When off, outputs go to a temporary folder you can still reveal in Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("App", value: "DocuForge")
                LabeledContent("Engine", value: "PDFKit · Vision · ImageIO · AppKit")
                Text("Designed for offline use. Network access is not required for any built-in tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
        .padding()
    }
}
