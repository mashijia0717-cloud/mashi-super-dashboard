import AppKit
import Testing
@testable import CPAQuotaBar

@Suite(.serialized)
@MainActor
struct DashboardLayoutTests {
    @Test func dashboardCardsFillTheAvailableWidth() throws {
        let pages: [NSView] = [
            MemoryCleanupDashboardView(frame: .zero),
            DisplayConsoleDashboardView(frame: .zero),
            QuickToolboxDashboardView(frame: .zero)
        ]
        for page in pages {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 376, height: 2400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            page.layoutSubtreeIfNeeded()
            let stack = try #require(page.subviews.first as? NSStackView)
            let cards = stack.arrangedSubviews.filter { $0 is LiquidGlassCardView }
            #expect(!cards.isEmpty)
            for card in cards where !card.isHiddenOrHasHiddenAncestor {
                #expect(abs(card.frame.width - 376) < 1)
                #expect(abs(card.frame.minX) < 1)
                let body = try #require(card.subviews.first as? NSStackView)
                for row in body.arrangedSubviews where !row.isHiddenOrHasHiddenAncestor {
                    let expectedWidth = 376 - body.edgeInsets.left - body.edgeInsets.right
                    let actualWidth = row.alignmentRect(forFrame: row.frame).width
                    #expect(abs(actualWidth - expectedWidth) < 1, "\(type(of: page)): \(type(of: row)) width \(actualWidth), expected \(expectedWidth)")
                }
            }
            window.close()
        }
    }

    @Test func dynamicallyInsertedRowsRespectInsetsAfterRemovalAndReinsertion() {
        let stack = FullWidthStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 376).isActive = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 376, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stack
        defer { window.close() }
        let row = NSTextField(labelWithString: "短文本")
        stack.insertArrangedSubview(row, at: 0)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.layoutSubtreeIfNeeded()
        #expect(abs(row.alignmentRect(forFrame: row.frame).width - 352) < 1)
        stack.removeArrangedSubview(row)
        row.removeFromSuperview()
        stack.addArrangedSubview(row)
        stack.layoutSubtreeIfNeeded()
        #expect(abs(row.alignmentRect(forFrame: row.frame).width - 352) < 1)
    }
}
