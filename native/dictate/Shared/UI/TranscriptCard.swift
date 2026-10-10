import SwiftUI

struct TranscriptCard: View {
    let title: String
    let text: String
    var emptyMessage: String = "Nothing captured yet."
    let tint: Color
    var onCopy: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                if let onCopy {
                    Button(action: onCopy) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                }
            }

            if text.isEmpty {
                Text(emptyMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // The window sizes to its content, so cap the card and scroll long transcripts.
                ScrollView {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
