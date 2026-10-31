// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import SwiftUI
import JotCore

/// The personal dictionary: teach it your terms once, they're spelled right forever.
/// Vocabulary is output directly to ASR and LLM formatting passes.
struct DictionaryView: View {
    private let store = DictionaryStore()

    @State private var entries: [DictionaryEntry] = []
    @State private var newTerm = ""
    @FocusState private var isInputFocused: Bool
    @State private var feedback: String?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            addRow
            if entries.isEmpty {
                emptyState
            } else {
                tagsView
            }
            footer
        }
        .onAppear {
            reload()
            isInputFocused = true
        }
    }

    private var addRow: some View {
        HStack(spacing: JotUI.Spacing.s) {
            TextField("Add a term or phrase…", text: $newTerm)
                .textFieldStyle(.plain)
                .font(JotUI.TypeScale.body(grad: grad))
                .focused($isInputFocused)
                .onSubmit(add)
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? JotUI.Colors.onSurfaceVariant.opacity(0.4)
                                     : JotUI.Colors.primary)
            }
            .buttonStyle(.plain)
            .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(JotUI.Spacing.s)
        .background(RoundedRectangle(cornerRadius: JotUI.Radius.medium).fill(JotUI.Colors.surfaceContainer))
        .padding(JotUI.Spacing.m)
    }

    private var tagsView: some View {
        ScrollView {
            FlowLayout(spacing: 8) {
                ForEach(entries) { entry in
                    HStack(spacing: 6) {
                        Text(entry.term)
                            .font(JotUI.TypeScale.body(grad: grad))
                            .foregroundStyle(JotUI.Colors.onSurface)
                        Button {
                            store.remove(id: entry.id)
                            reload()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(JotUI.Colors.surfaceContainer))
                    .overlay(
                        Capsule()
                            .strokeBorder(JotUI.Colors.outlineVariant.opacity(0.6), lineWidth: 1)
                    )
                }
            }
            .padding(JotUI.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: JotUI.Spacing.s) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
            Text("Teach it your words")
                .font(JotUI.TypeScale.title(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurface)
            Text("Names, jargon, product terms — add them once,\nthey're spelled right in every dictation.")
                .font(JotUI.TypeScale.body(grad: grad))
                .foregroundStyle(JotUI.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(feedback ?? "\(entries.count) \(entries.count == 1 ? "word" : "words")")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(feedback == nil ? JotUI.Colors.onSurfaceVariant : JotUI.Colors.primary)
            Spacer()
            Button("Import…", action: importWords)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
            Button("Export…", action: exportWords)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .disabled(entries.isEmpty)
        }
        .buttonStyle(.link)
        .padding(JotUI.Spacing.m)
    }

    // MARK: - Actions

    private func add() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard store.add(term: trimmed) else {
            showFeedback(trimmed.count > 60 ? "Keep terms under 60 characters" : "Already in your dictionary")
            newTerm = ""
            isInputFocused = true
            return
        }
        newTerm = ""
        isInputFocused = true
        reload()
    }

    private func reload() {
        entries = store.entries()
    }

    private func showFeedback(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }

    private func importWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else if let utf16 = try? String(contentsOf: url, encoding: .utf16) {
            text = utf16
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            text = latin1
        } else {
            showFeedback("Could not read file (unsupported encoding)")
            return
        }

        let isCSV = url.pathExtension.lowercased() == "csv"
        let count = isCSV ? store.importCSV(text) : store.importText(text)
        Log.ui.info("Dictionary: imported \(count) entries")
        reload()
        showFeedback(count == 0 ? "Nothing new to import" : "Imported \(count) \(count == 1 ? "word" : "words")")
    }

    private func exportWords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jot-dictionary.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = store.exportText()
            try text.write(to: url, atomically: true, encoding: .utf8)
            showFeedback("Exported \(entries.count) \(entries.count == 1 ? "word" : "words")")
        } catch {
            Log.ui.error("Dictionary export failed: \(error)")
            showFeedback("Export failed — couldn't write the file")
        }
    }
}

// MARK: - Flow / Wrapping Tags Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxW && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: maxW.isFinite ? maxW : currentX, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
