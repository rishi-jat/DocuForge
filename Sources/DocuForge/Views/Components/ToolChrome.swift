import SwiftUI
import AppKit
import DocuForgeCore

/// Shared page chrome for tool screens. Uses high-contrast surfaces that stay
/// readable in light and dark appearance.
struct ToolChrome<Controls: View, Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                // Main content (drop zone / forms)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Actions
                controls()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct JobStatusBanner: View {
    let state: JobState
    var onReveal: ((URL) -> Void)?
    var onOpen: ((URL) -> Void)?

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .running(let progress, let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                ProgressView(value: progress)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(roundedCard)
        case .succeeded(let urls):
            VStack(alignment: .leading, spacing: 10) {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                ForEach(urls, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        if let onOpen {
                            Button("Open") { onOpen(url) }
                        }
                        if let onReveal {
                            Button("Show in Finder") { onReveal(url) }
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
            )
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
        }
    }

    private var roundedCard: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
    }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 160)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }
}
