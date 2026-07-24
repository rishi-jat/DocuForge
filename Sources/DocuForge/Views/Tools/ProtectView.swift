import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct ProtectView: View {
    @EnvironmentObject private var app: AppModel
    @State private var item: DocumentItem?
    @State private var mode: Mode = .lock
    @State private var password: String = ""
    @State private var confirm: String = ""
    @State private var job: JobState = .idle

    enum Mode: String, CaseIterable, Identifiable {
        case lock, unlock
        var id: String { rawValue }
        var title: String { self == .lock ? "Add password" : "Remove password" }
    }

    var body: some View {
        ToolChrome(
            title: "Password",
            subtitle: "Encrypt or unlock PDFs with standard PDF passwords. Keys never leave your Mac.",
            systemImage: "lock.doc",
            content: {
                if let item {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "lock.doc")
                            Text(item.displayName).font(.headline)
                            Spacer()
                            Button("Clear") { self.item = nil; job = .idle; password = ""; confirm = "" }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))

                        Picker("Action", selection: $mode) {
                            ForEach(Mode.allCases) { m in Text(m.title).tag(m) }
                        }
                        .pickerStyle(.segmented)

                        SecureField(mode == .lock ? "Password" : "Current password", text: $password)
                            .textFieldStyle(.roundedBorder)
                        if mode == .lock {
                            SecureField("Confirm password", text: $confirm)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    DropZoneView(
                        title: "Drop a PDF",
                        subtitle: "Protect or unlock offline with PDFKit",
                        systemImage: "lock.doc",
                        allowedTypes: [.pdf],
                        allowsMultiple: false
                    ) { urls in
                        if let url = urls.first { item = DocumentItem(url: url) }
                    }
                }
            },
            controls: {
                HStack {
                    PrimaryActionButton(
                        title: mode == .lock ? "Protect" : "Unlock",
                        systemImage: mode == .lock ? "lock.fill" : "lock.open.fill",
                        enabled: canRun
                    ) {
                        Task { await run() }
                    }
                    Spacer()
                }
                JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
            }
        )
    }

    private var canRun: Bool {
        guard item != nil, !job.isRunning, !password.isEmpty else { return false }
        if mode == .lock { return password == confirm }
        return true
    }

    private func run() async {
        guard let item else { return }
        job = .running(progress: 0.4, message: mode == .lock ? "Encrypting…" : "Unlocking…")
        do {
            let dir = try app.makeOutputDirectory(named: "Password")
            let base = item.url.deletingPathExtension().lastPathComponent
            let result: ProcessingResult
            if mode == .lock {
                let out = dir.appendingPathComponent("\(base)-protected.pdf")
                result = try await app.pdf.protect(url: item.url, userPassword: password, ownerPassword: password, outputURL: out)
            } else {
                let out = dir.appendingPathComponent("\(base)-unlocked.pdf")
                result = try await app.pdf.unlock(url: item.url, password: password, outputURL: out)
            }
            app.recordOutputs(result.outputURLs)
            job = .succeeded(outputURLs: result.outputURLs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
