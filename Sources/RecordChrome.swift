import SwiftUI

/// Shared lightweight chrome for record sheets and overlays. Business validation
/// and persistence stay in each editor; these views only provide visual rhythm.
struct RecordHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var accent: Color = RhythmTheme.morningGreen
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 23, weight: .semibold, design: .serif))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(RhythmLocalization.text("关闭"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(RhythmTheme.panel)
    }
}

struct RecordSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RhythmTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RhythmTheme.cardBorder))
    }
}

struct RecordField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.primary.opacity(0.075)))
        }
    }
}

struct RecordActionBar: View {
    var cancelTitle: String = RhythmLocalization.text("取消")
    var saveTitle: String = RhythmLocalization.text("保存")
    var saveDisabled = false
    var accent: Color = RhythmTheme.morningClay
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(cancelTitle, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(saveTitle, action: onSave)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .keyboardShortcut(.defaultAction)
                .disabled(saveDisabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(RhythmTheme.panel)
    }
}
