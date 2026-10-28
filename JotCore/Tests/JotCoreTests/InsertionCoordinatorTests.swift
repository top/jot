import AppKit
import ApplicationServices
import XCTest
@testable import JotCore

final class InsertionCoordinatorTests: XCTestCase {
    @MainActor
    func testDisabledAutomaticInsertionCopiesWithoutInserting() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "automaticInsertion")
        defer { defaults.set(original, forKey: "automaticInsertion") }
        SettingsStore().setAutomaticInsertion(false)
        try await assertClipboardOnly()
    }

    @MainActor
    func testMissingAccessibilityCopiesWithoutInserting() async throws {
        guard !AXIsProcessTrusted() else { throw XCTSkip("Requires no Accessibility permission") }
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "automaticInsertion")
        defer { defaults.set(original, forKey: "automaticInsertion") }
        SettingsStore().setAutomaticInsertion(true)
        try await assertClipboardOnly()
    }

    @MainActor
    private func assertClipboardOnly() async throws {
        guard !SecureInput.isActive else { throw XCTSkip("Secure input blocks clipboard writes") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Previous copy", forType: .string)
        let inserter = InsertionCoordinator(pasteboard: pasteboard)
        let outcome = await inserter.insert("Dictated words", context: DictationContext())
        XCTAssertEqual(outcome, .fellBackToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated words")
        XCTAssertNotNil(pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }
}