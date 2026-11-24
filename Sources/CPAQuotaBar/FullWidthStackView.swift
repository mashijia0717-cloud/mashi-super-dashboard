import AppKit

@MainActor
final class FullWidthStackView: NSStackView {
    private var childWidths: [ObjectIdentifier: NSLayoutConstraint] = [:]

    override var edgeInsets: NSEdgeInsets {
        didSet {
            for constraint in childWidths.values {
                constraint.constant = -edgeInsets.left - edgeInsets.right
            }
        }
    }

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        stretch(view)
    }

    override func insertArrangedSubview(_ view: NSView, at index: Int) {
        super.insertArrangedSubview(view, at: index)
        stretch(view)
    }

    override func removeArrangedSubview(_ view: NSView) {
        childWidths.removeValue(forKey: ObjectIdentifier(view))?.isActive = false
        super.removeArrangedSubview(view)
    }

    private func stretch(_ view: NSView) {
        let identity = ObjectIdentifier(view)
        guard childWidths[identity] == nil else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraint = view.widthAnchor.constraint(equalTo: widthAnchor, constant: -edgeInsets.left - edgeInsets.right)
        constraint.isActive = true
        childWidths[identity] = constraint
    }
}
