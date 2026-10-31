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
    @State private var feedbackTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var scheme
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                emptyState
            } else {
                tagsView
            }
        }
        .onAppear {
            reload()
            isInputFocused = true
        }
    }

    // MARK: - Header (stats + add)

    private var header: some View {
        VStack(spacing: JotUI.Spacing.s) {
            HStack(spacing: JotUI.Spacing.xl) {
                stat(value: "\(entries.count)", label: entries.count == 1 ? "term" : "terms")
                if let feedback {
                    Text(feedback)
                        .font(JotUI.TypeScale.labelSmall(grad: grad))
                        .foregroundStyle(JotUI.Colors.primary)
                }
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(JotUI.Colors.brandQuad[index])
                            .frame(width: 12, height: 4)
                    }
                }
                optionsMenu
            }
            addRow
        }
        .padding(.horizontal, JotUI.Spacing.l)
        .padding(.top, JotUI.Spacing.l)
        .padding(.bottom, JotUI.Spacing.s)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Import Terms…", action: importWords)
            Button("Export Terms…", action: exportWords)
                .disabled(entries.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(JotUI.TypeScale.title(grad: grad))
                .monospacedDigit()
            Text(label)
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    private var addRow: some View {
        HStack(spacing: JotUI.Spacing.xs) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
            TextField("Add a term or phrase…", text: $newTerm)
                .textFieldStyle(.plain)
                .font(JotUI.TypeScale.body(grad: grad))
                .focused($isInputFocused)
                .onSubmit(add)
            if !newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(JotUI.Colors.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, JotUI.Spacing.s)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: JotUI.Radius.small).fill(.quaternary.opacity(0.5)))
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
            .padding(.horizontal, JotUI.Spacing.l)
            .padding(.vertical, JotUI.Spacing.m)
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
        feedbackTask?.cancel()
        feedback = message
        feedbackTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                feedback = nil
            }
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
        showFeedback(count == 0 ? "Nothing new to import" : "Imported \(count) \(count == 1 ? "term" : "terms")")
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
            showFeedback("Exported \(entries.count) \(entries.count == 1 ? "term" : "terms")")
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
