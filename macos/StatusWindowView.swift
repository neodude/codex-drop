import AppKit

/// Presentation only. The app delegate owns all receiver, login, and quit behavior.
@MainActor final class StatusWindowView: NSView {
    struct Actions {
        let start, stop, pair, accessibility, project, log, login, loginSettings, close, quit: Selector
    }

    let status = NSTextField(wrappingLabelWithString: "Starting…")
    let accessibility = NSTextField(wrappingLabelWithString: "Accessibility: checking…")
    let start: NSButton
    let stop: NSButton
    let pair: NSButton
    let login: NSButton
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let stateSurface = DropStatusSurface()
    fileprivate static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 179 / 255, green: 185 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 86 / 255, green: 95 / 255, blue: 219 / 255, alpha: 1)
    }
    private static let secondary = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 179 / 255, green: 179 / 255, blue: 191 / 255, alpha: 1)
            : .secondaryLabelColor
    }

    init(target: AnyObject, actions: Actions, mark: NSImage? = nil) {
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: target, action: action)
            button.bezelStyle = .rounded
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            return button
        }
        start = button("Start Receiver", actions.start)
        stop = button("Stop Receiver", actions.stop)
        pair = DropPairButton(title: "Pair Phone…", target: target, action: actions.pair)
        pair.bezelStyle = .rounded
        login = NSButton(checkboxWithTitle: "Open at Login", target: target, action: actions.login)
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = mark ?? Bundle.main.url(forResource: "DropMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 48), icon.heightAnchor.constraint(equalToConstant: 48)])
        let title = label("Codex Drop", size: 23, weight: .semibold)
        let subtitle = label("Phone screenshots to your Codex draft", size: 12, secondary: true)
        let heading = column([title, subtitle], spacing: 4)
        let header = NSStackView(views: [icon, heading]); header.spacing = 12; header.alignment = .centerY

        status.font = .systemFont(ofSize: 14, weight: .semibold)
        status.setAccessibilityIdentifier("receiver-status")
        accessibility.font = .systemFont(ofSize: 12)
        accessibility.textColor = Self.secondary
        accessibility.setAccessibilityIdentifier("accessibility-status")
        let stateTitle = label("RECEIVER", size: 10, weight: .semibold)
        stateTitle.textColor = Self.accent
        let stateContent = column([
            stateTitle,
            status,
            accessibility
        ], spacing: 7)
        inset(stateContent, in: stateSurface, amount: 14)
        let note = label("Share 1–10 images on the same Wi-Fi. Codex opens and attaches them to its last active thread.", size: 12, secondary: true)
        pair.controlSize = .large
        pair.font = .systemFont(ofSize: 13, weight: .semibold)
        pair.contentTintColor = Self.accent
        pair.setAccessibilityHelp("Show the pairing code for a phone. Available when the receiver is running.")

        let settings = button("Accessibility Settings…", actions.accessibility)
        let project = button("Reveal Project", actions.project)
        let log = button("Reveal Receiver Log", actions.log)
        let loginSettings = button("Login Items Settings…", actions.loginSettings)
        let close = button("Close Window", actions.close)
        let quit = button("Quit Codex Drop…", actions.quit)
        let tools = column([
            label("Receiver & settings", size: 12, weight: .semibold),
            row([start, stop]),
            row([settings]),
            row([project, log]),
            row([login, loginSettings], equal: false)
        ], spacing: 8)
        let background = label("Close keeps the receiver running. Reopen Codex Drop from Finder or Spotlight. Quit stops the receiver.", size: 11, secondary: true)
        let footer = column([background, row([close, quit])], spacing: 10)
        for view in [header, stateSurface, note, pair, tools, footer] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.setCustomSpacing(20, after: header)
        stack.setCustomSpacing(10, after: note)
        stack.setCustomSpacing(22, after: pair)
        stack.setCustomSpacing(20, after: tools)
        for view in [stateSurface, note, pair, tools, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        // Native scrolling keeps every action reachable in a short window.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = DropFlippedView()
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        inset(stack, in: document, amount: 24)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(srgbRed: 16 / 255, green: 16 / 255, blue: 20 / 255, alpha: 1) : .windowBackgroundColor).setFill()
        dirtyRect.fill()
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? Self.secondary : .labelColor
        return label
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let column = NSStackView(views: views); column.orientation = .vertical; column.alignment = .leading; column.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }
    private func row(_ views: [NSView], equal: Bool = true) -> NSStackView {
        let row = NSStackView(views: views); row.spacing = 8; row.alignment = .centerY
        row.distribution = equal ? .fillEqually : .fill
        return row
    }
    private func inset(_ child: NSView, in parent: NSView, amount: CGFloat) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: amount),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -amount),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: amount),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -amount)
        ])
    }
}

@MainActor private final class DropFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class DropStatusSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(srgbRed: 27 / 255, green: 27 / 255, blue: 34 / 255, alpha: 1) : .controlBackgroundColor).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        shape.fill()
        if !dark {
            NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
            shape.lineWidth = 1; shape.stroke()
        }
    }
}

/// Keep native button rendering and disabled state while giving the primary title
/// the brand accent, including when an accessory window is not the key window.
@MainActor private final class DropPairButton: NSButton {
    override var isEnabled: Bool { didSet { updateTitle() } }
    override var font: NSFont? { didSet { updateTitle() } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTitle()
    }
    private func updateTitle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isEnabled ? StatusWindowView.accent : NSColor.disabledControlTextColor
        ])
    }
}
