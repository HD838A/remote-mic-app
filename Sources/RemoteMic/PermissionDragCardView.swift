import AppKit
import Foundation

final class PermissionDragCardView: NSVisualEffectView, NSDraggingSource {
    enum CardPhase: Equatable {
        case idle
        case checking
        case waiting
        case added
        case dragFailed
        case fallback
    }

    private let bundleURL: URL
    private let copy: PermissionDragHelperCopy
    private let onClose: () -> Void
    private let onDragStarted: () -> Void
    private let onDragEnded: (Bool) -> Void
    private let onReopen: () -> Void

    private let iconView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private let productLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let closeButton = FirstMouseButton()
    private let dragBadge: PermissionDragBadgeView
    private let statusLabel = NSTextField(labelWithString: "")
    private let reopenButton = FirstMouseButton()

    private var dragStartPoint: NSPoint?
    private var dragStarted = false
    private(set) var phase: CardPhase = .idle

    init(
        bundleURL: URL,
        copy: PermissionDragHelperCopy,
        onClose: @escaping () -> Void,
        onDragStarted: @escaping () -> Void,
        onDragEnded: @escaping (Bool) -> Void,
        onReopen: @escaping () -> Void
    ) {
        self.bundleURL = bundleURL
        self.copy = copy
        self.onClose = onClose
        self.onDragStarted = onDragStarted
        self.onDragEnded = onDragEnded
        self.onReopen = onReopen
        dragBadge = PermissionDragBadgeView(title: copy.drag)
        super.init(frame: NSRect(origin: .zero, size: PermissionDragHelperGeometry.cardSize))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 14,
            yRadius: 14
        )
        border.lineWidth = 1
        border.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.separatorColor.withAlphaComponent(0.9).setStroke()
        border.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        closeButton.contentTintColor = .secondaryLabelColor
        reopenButton.contentTintColor = .controlAccentColor
        dragBadge.needsDisplay = true
        updateStatusColor()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !closeButton.isHidden, closeButton.frame.contains(point) {
            return closeButton
        }
        if !reopenButton.isHidden, reopenButton.frame.contains(point) {
            return reopenButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let dragStartPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStartPoint.x, point.y - dragStartPoint.y) >= 4 else {
            return
        }
        dragStarted = true
        onDragStarted()
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        dragStarted = false
    }

    func setState(_ newState: CardPhase) {
        guard phase != newState else { return }
        phase = newState
        reopenButton.isHidden = newState != .fallback
        statusLabel.isHidden = newState == .fallback
        switch newState {
        case .idle:
            statusLabel.stringValue = copy.idle
        case .checking:
            statusLabel.stringValue = copy.checking
        case .waiting:
            statusLabel.stringValue = copy.waiting
        case .added:
            statusLabel.stringValue = copy.added
        case .dragFailed:
            statusLabel.stringValue = copy.dragFailed
        case .fallback:
            break
        }
        updateStatusColor()
        needsLayout = true
    }

    private func setup() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(copy.accessibilityLabel)
        setAccessibilityHelp(copy.hint)

        iconView.image = NSWorkspace.shared.icon(forFile: bundleURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 12
        iconView.layer?.masksToBounds = true
        iconView.setAccessibilityElement(false)

        filenameLabel.stringValue = bundleURL.lastPathComponent
        filenameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        filenameLabel.textColor = .labelColor
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filenameLabel.setAccessibilityElement(false)

        productLabel.stringValue = copy.product
        productLabel.font = .systemFont(ofSize: 12)
        productLabel.textColor = .secondaryLabelColor
        productLabel.lineBreakMode = .byTruncatingTail
        productLabel.maximumNumberOfLines = 1
        productLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        productLabel.setAccessibilityElement(false)

        hintLabel.stringValue = copy.hint
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.setAccessibilityElement(false)

        configureCloseButton()
        configureReopenButton()

        statusLabel.stringValue = copy.idle
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityElement(false)

        for view in [iconView, filenameLabel, productLabel, hintLabel, closeButton, dragBadge, statusLabel, reopenButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        reopenButton.isHidden = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            filenameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            filenameLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            filenameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            productLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            productLabel.trailingAnchor.constraint(equalTo: filenameLabel.trailingAnchor),
            productLabel.topAnchor.constraint(equalTo: filenameLabel.bottomAnchor, constant: 1),

            hintLabel.leadingAnchor.constraint(equalTo: filenameLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: filenameLabel.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: productLabel.bottomAnchor, constant: 1),

            dragBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dragBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            dragBadge.heightAnchor.constraint(equalToConstant: 22),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: dragBadge.centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: dragBadge.trailingAnchor,
                constant: 8
            ),

            reopenButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            reopenButton.centerYAnchor.constraint(equalTo: dragBadge.centerYAnchor),
            reopenButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: dragBadge.trailingAnchor,
                constant: 8
            )
        ])
    }

    private func configureCloseButton() {
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: copy.close
        )
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11,
            weight: .semibold
        )
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = copy.close
        closeButton.setAccessibilityLabel(copy.close)
    }

    private func configureReopenButton() {
        reopenButton.isBordered = false
        reopenButton.bezelStyle = .regularSquare
        reopenButton.title = copy.reopen
        reopenButton.font = .systemFont(ofSize: 12, weight: .medium)
        reopenButton.contentTintColor = .controlAccentColor
        reopenButton.target = self
        reopenButton.action = #selector(reopenTapped)
        reopenButton.toolTip = copy.reopen
        reopenButton.setAccessibilityLabel(copy.reopen)
    }

    private func updateStatusColor() {
        switch phase {
        case .checking:
            statusLabel.textColor = .controlAccentColor
        case .added:
            statusLabel.textColor = .systemGreen
        case .dragFailed:
            statusLabel.textColor = .systemRed
        case .idle, .waiting, .fallback:
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func startDrag(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let image = dragImage()
        let mouse = NSEvent.mouseLocation
        let frame = NSRect(
            x: mouse.x - 20,
            y: mouse.y - 24,
            width: image.size.width,
            height: image.size.height
        )
        item.setDraggingFrame(frame, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func dragImage() -> NSImage {
        let filename = bundleURL.lastPathComponent
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let measured = (filename as NSString).size(withAttributes: [.font: font]).width
        let textWidth = min(160, ceil(measured))
        let size = NSSize(width: 40 + 8 + textWidth + 10, height: 48)
        return NSImage(size: size, flipped: false) { [bundleURL] rect in
            let background = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 10,
                yRadius: 10
            )
            NSColor.windowBackgroundColor.setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.lineWidth = 1
            background.stroke()

            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            icon.draw(
                in: NSRect(x: 4, y: 4, width: 40, height: 40),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            let textRect = NSRect(
                x: 52,
                y: (size.height - 16) / 2,
                width: size.width - 52 - 8,
                height: 16
            )
            (filename as NSString).draw(
                in: textRect,
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
            )
            return true
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded(operation.contains(.copy))
    }

    @objc private func closeTapped() {
        onClose()
    }

    @objc private func reopenTapped() {
        onReopen()
    }
}

final class PermissionDragBadgeView: NSView {
    private let label: NSTextField

    init(title: String) {
        label = NSTextField(labelWithString: "⠿ \(title)")
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 18, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 11,
            yRadius: 11
        )
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        label.textColor = .controlAccentColor
        needsDisplay = true
    }
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
