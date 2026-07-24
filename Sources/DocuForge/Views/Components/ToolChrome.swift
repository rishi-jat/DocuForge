import SwiftUI
import AppKit
import DocuForgeCore

/// Reliable tool layout for SPM SwiftUI macOS apps.
struct ToolChrome<Content: View, Controls: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Unmissable build banner so we can confirm the binary
                Text("DocuForge UI · Build UI-VERIFY-233406 · if you see this, you have the new build")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("DocuForge UI build banner")
                    .accessibilityIdentifier("docuforge-build-banner")

                // Header
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue)
                            .frame(width: 48, height: 48)
                        Image(systemName: systemImage)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundStyle(colorScheme == .dark ? .white : .primary)
                            .accessibilityAddTraits(.isHeader)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(colorScheme == .dark ? Color(white: 0.85) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                content()

                controls()
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(colorScheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobStatusBanner: View {
    let state: JobState
    var onReveal: ((URL) -> Void)?
    var onOpen: ((URL) -> Void)?

    var body: some View {
        switch state {
        case .idle: EmptyView()
        case .running(let progress, let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                ProgressView(value: progress)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.2)))
        case .succeeded(let urls):
            VStack(alignment: .leading, spacing: 8) {
                Label("Finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ForEach(urls, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent)
                        Spacer()
                        if let onOpen { Button("Open") { onOpen(url) } }
                        if let onReveal { Button("Show in Finder") { onReveal(url) } }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.15)))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.15)))
        }
    }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}
