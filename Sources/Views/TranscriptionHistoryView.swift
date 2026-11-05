import SwiftUI

struct TranscriptionHistoryView: View {
    let target: DictationTarget?
    var onInserted: () -> Void
    @State private var entries: [TranscriptionHistory.Entry] = []
    @State private var copiedId: UUID?
    @State private var isInserting = false
    @State private var insertionError: String?

    var body: some View {
        VStack(spacing: 0) {
            Text(target.map { "Insert into \($0.applicationName) — the editor focused before opening History." }
                 ?? "To insert directly, focus an editor and open Recent Transcriptions from the menu bar.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            if let insertionError {
                Text(insertionError).font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 12)
            }
            if entries.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No transcriptions yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.date, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if entry.inserted {
                                    Text("Paste sent").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                if !entry.inserted {
                                    Text("Not inserted")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                    copiedId = entry.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if copiedId == entry.id { copiedId = nil }
                                    }
                                } label: {
                                    Image(systemName: copiedId == entry.id ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 11))
                                        .foregroundStyle(copiedId == entry.id ? .green : .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy to clipboard")
                                if let target {
                                    Button("Insert") {
                                        guard !isInserting else { return }
                                        isInserting = true
                                        insertionError = nil
                                        Task { @MainActor in
                                            defer { isInserting = false }
                                            do {
                                                try await target.restoreFocus()
                                                try await TextInserter().insert(text: entry.text, target: target)
                                                TranscriptionHistory.shared.save(text: entry.text, inserted: true, id: entry.id)
                                                entries = TranscriptionHistory.shared.entries
                                                onInserted()
                                            } catch {
                                                insertionError = error.localizedDescription
                                                NSApp.activate(ignoringOtherApps: true)
                                            }
                                        }
                                    }
                                    .help("Return to the captured editor in \(target.applicationName) and paste this text")
                                }
                            }
                            Text(entry.text)
                                .font(.system(size: 12))
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .disabled(isInserting)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { entries = TranscriptionHistory.shared.entries }
    }
}
