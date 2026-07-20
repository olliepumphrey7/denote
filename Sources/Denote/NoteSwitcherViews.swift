import AppKit
import QuartzCore

@MainActor
final class NoteWindow: NSWindow {
    var onMiniaturize: (() -> Bool)?

    override func miniaturize(_ sender: Any?) {
        if onMiniaturize?() == true { return }
        super.miniaturize(sender)
    }
}

struct NoteSwitcherItem: Equatable {
    let title: String
    let url: URL

    var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "•"
    }
}

enum NoteSwitcherPlacement {
    case balanced
    case above
    case below
}

@MainActor
final class InitialBadgeButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    var onStep: ((Int) -> Void)?
    private var trackingAreaReference: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollStep = Date.distantPast

    init() {
        super.init(frame: .zero)
        isBordered = false
        font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        contentTintColor = .controlAccentColor
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        setAccessibilityLabel("Show note switcher")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
        onHoverChanged?(false)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollAccumulator = 0 }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 22 else { return }
        }
        let now = Date()
        guard now.timeIntervalSince(lastScrollStep) >= 0.24 else { return }
        lastScrollStep = now
        scrollAccumulator = 0
        onStep?(delta > 0 ? -1 : 1)
    }
}

@MainActor
private final class OrbitItemButton: NSButton {
    let item: NoteSwitcherItem?
    var onActivate: ((OrbitItemButton) -> Void)?
    var onHover: ((OrbitItemButton, Bool) -> Void)?
    private var trackingAreaReference: NSTrackingArea?

    init(item: NoteSwitcherItem?) {
        self.item = item
        super.init(frame: .zero)
        title = item?.initial ?? "+"
        isBordered = false
        font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 4
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow?.shadowOffset = NSSize(width: 0, height: -1)
        setAccessibilityLabel(item?.title ?? "Add note to switcher")
        target = self
        action = #selector(activate(_:))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        let hoverColor = NSColor.windowBackgroundColor.blended(withFraction: 0.18, of: .controlAccentColor)
            ?? NSColor.windowBackgroundColor
        layer?.backgroundColor = hoverColor.withAlphaComponent(1).cgColor
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        onHover?(self, false)
    }

    @objc private func activate(_ sender: Any?) {
        onActivate?(self)
    }
}

@MainActor
final class OrbitSwitcherOverlayView: NSView {
    var onSelect: ((NoteSwitcherItem) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onStep: ((Int) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var itemButtons: [OrbitItemButton] = []
    private let upperRailUnderlay = NSView()
    private let lowerRailUnderlay = NSView()
    private let namePill = NSVisualEffectView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var trackingAreaReference: NSTrackingArea?
    private var scrollAccumulator: CGFloat = 0
    private var lastScrollStep = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupRailUnderlay(upperRailUnderlay)
        setupRailUnderlay(lowerRailUnderlay)
        setupNamePill()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func scrollWheel(with event: NSEvent) {
        processScroll(event)
    }

    func processScroll(_ event: NSEvent) {
        if event.phase == .began { scrollAccumulator = 0 }
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }

        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 22 else { return }
        }

        let now = Date()
        guard now.timeIntervalSince(lastScrollStep) >= 0.24 else { return }
        lastScrollStep = now
        let direction = delta > 0 ? -1 : 1
        scrollAccumulator = 0
        onStep?(direction)
    }

    func isInteractive(at point: NSPoint) -> Bool {
        if upperRailUnderlay.isHidden == false, upperRailUnderlay.frame.contains(point) { return true }
        if lowerRailUnderlay.isHidden == false, lowerRailUnderlay.frame.contains(point) { return true }
        return itemButtons.contains { $0.frame.insetBy(dx: -5, dy: -5).contains(point) }
    }

    func configure(
        items: [NoteSwitcherItem],
        activeURL: URL,
        anchor: NSPoint,
        placement: NoteSwitcherPlacement,
        animated: Bool
    ) {
        itemButtons.forEach { $0.removeFromSuperview() }
        itemButtons.removeAll()
        namePill.isHidden = true

        let activeIndex = items.firstIndex { $0.url.standardizedFileURL == activeURL.standardizedFileURL } ?? 0
        let uniqueOtherCount = Set(items.map { $0.url.standardizedFileURL.path })
            .subtracting([activeURL.standardizedFileURL.path])
            .count
        let relativePositions: [(distance: Int, offset: CGFloat)]
        switch placement {
        case .balanced:
            switch min(uniqueOtherCount, 4) {
            case 0: relativePositions = []
            case 1: relativePositions = [(-1, 38)]
            case 2: relativePositions = [(-1, 38), (1, -38)]
            case 3: relativePositions = [(-2, 74), (-1, 38), (1, -38)]
            default: relativePositions = [(-2, 74), (-1, 38), (1, -38), (2, -74)]
            }
        case .above:
            relativePositions = (1...max(1, min(uniqueOtherCount, 4))).compactMap { distance in
                guard distance <= uniqueOtherCount else { return nil }
                return (-distance, CGFloat(38 + ((distance - 1) * 36)))
            }
        case .below:
            relativePositions = (1...max(1, min(uniqueOtherCount, 4))).compactMap { distance in
                guard distance <= uniqueOtherCount else { return nil }
                return (distance, -CGFloat(38 + ((distance - 1) * 36)))
            }
        }
        var usedPaths = Set([activeURL.standardizedFileURL.path])
        var placements: [(NoteSwitcherItem?, NSPoint)] = []
        if items.count > 1 {
            for position in relativePositions {
                let index = (activeIndex + position.distance + items.count) % items.count
                let item = items[index]
                guard usedPaths.insert(item.url.standardizedFileURL.path).inserted else { continue }
                placements.append((item, NSPoint(x: 0, y: position.offset)))
            }
        }
        let occupiedOffsets = placements.map(\.1.y)
        let addOffset: CGFloat
        switch placement {
        case .balanced, .below:
            addOffset = occupiedOffsets.filter { $0 < 0 }.min().map { $0 - 36 } ?? -38
        case .above:
            addOffset = occupiedOffsets.filter { $0 > 0 }.max().map { $0 + 36 } ?? 38
        }
        placements.append((nil, NSPoint(x: 0, y: addOffset)))

        let destinationFrames = placements.map { placement in
            NSRect(
                x: anchor.x + placement.1.x - 13,
                y: anchor.y + placement.1.y - 13,
                width: 26,
                height: 26
            )
        }
        configureRailUnderlays(for: destinationFrames, anchor: anchor)

        for (index, placement) in placements.enumerated() {
            let entry = placement.0
            let button = OrbitItemButton(item: entry)
            let destination = destinationFrames[index]
            button.frame = animated ? NSRect(x: anchor.x - 2, y: anchor.y - 2, width: 4, height: 4) : destination
            button.alphaValue = animated ? 0 : 1
            button.onActivate = { [weak self] sender in
                guard let self else { return }
                if let item = sender.item { self.onSelect?(item) } else { self.onAdd?(sender) }
            }
            button.onHover = { [weak self] sender, hovered in
                guard let self else { return }
                if hovered, let item = sender.item {
                    self.showName(item.title, beside: sender)
                } else {
                    self.namePill.isHidden = true
                }
            }
            addSubview(button)
            itemButtons.append(button)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16 + (Double(index) * 0.018)
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    button.animator().frame = destination
                    button.animator().alphaValue = 1
                }
            }
        }
        setAccessibilityLabel("Note switcher")
    }

    private func setupRailUnderlay(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.22).cgColor
        view.isHidden = true
        addSubview(view)
    }

    private func configureRailUnderlays(for buttonFrames: [NSRect], anchor: NSPoint) {
        let upperFrames = buttonFrames.filter { $0.midY > anchor.y }
        let lowerFrames = buttonFrames.filter { $0.midY < anchor.y }
        if let upperEdge = upperFrames.map(\.maxY).max() {
            upperRailUnderlay.frame = NSRect(
                x: anchor.x - 21,
                y: anchor.y + 17,
                width: 42,
                height: upperEdge - anchor.y - 11
            )
            upperRailUnderlay.isHidden = false
        } else {
            upperRailUnderlay.isHidden = true
        }
        if let lowerEdge = lowerFrames.map(\.minY).min() {
            lowerRailUnderlay.frame = NSRect(
                x: anchor.x - 21,
                y: lowerEdge - 6,
                width: 42,
                height: anchor.y - lowerEdge - 11
            )
            lowerRailUnderlay.isHidden = false
        } else {
            lowerRailUnderlay.isHidden = true
        }
        addSubview(upperRailUnderlay, positioned: .below, relativeTo: namePill)
        addSubview(lowerRailUnderlay, positioned: .below, relativeTo: namePill)
    }

    private func setupNamePill() {
        namePill.material = .popover
        namePill.blendingMode = .withinWindow
        namePill.state = .active
        namePill.wantsLayer = true
        namePill.layer?.cornerRadius = 9
        namePill.layer?.masksToBounds = true
        namePill.isHidden = true
        nameLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .labelColor
        nameLabel.alignment = .center
        namePill.addSubview(nameLabel)
        addSubview(namePill)
    }

    private func showName(_ title: String, beside button: NSView) {
        nameLabel.stringValue = title
        let width = min(max(nameLabel.intrinsicContentSize.width + 18, 70), 180)
        var x = button.frame.maxX + 5
        if x + width > bounds.maxX { x = button.frame.minX - width - 5 }
        let frame = NSRect(x: max(4, x), y: button.frame.midY - 10, width: width, height: 20)
        namePill.frame = frame
        nameLabel.frame = namePill.bounds.insetBy(dx: 6, dy: 2)
        namePill.isHidden = false
        namePill.alphaValue = 0
        namePill.animator().alphaValue = 1
        addSubview(namePill, positioned: .above, relativeTo: nil)
    }
}

@MainActor
final class FloatingSwitcherView: NSView {
    var onActivate: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onSelect: ((NoteSwitcherItem) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onStep: ((Int) -> Void)?
    var onDragging: ((NSPoint) -> Void)?
    var onMoved: ((NSPoint) -> Void)?

    private let badge = FloatingBadgeView()
    private let overlay = OrbitSwitcherOverlayView()
    private var trackingAreaReference: NSTrackingArea?
    private var activeTitle = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        overlay.onSelect = { [weak self] item in self?.onSelect?(item) }
        overlay.onAdd = { [weak self] view in self?.onAdd?(view) }
        overlay.onStep = { [weak self] direction in self?.onStep?(direction) }
        overlay.onHoverChanged = { [weak self] hovered in self?.onHoverChanged?(hovered) }
        addSubview(overlay)

        badge.onActivate = { [weak self] in self?.onActivate?() }
        badge.onHoverChanged = { [weak self] hovered in self?.onHoverChanged?(hovered) }
        badge.onDragging = { [weak self] point in self?.onDragging?(point) }
        badge.onMoved = { [weak self] point in self?.onMoved?(point) }
        addSubview(badge)

    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
    override func scrollWheel(with event: NSEvent) { overlay.processScroll(event) }

    func isInteractive(at point: NSPoint) -> Bool {
        if badge.frame.insetBy(dx: -5, dy: -5).contains(point) { return true }
        return overlay.isHidden == false && overlay.isInteractive(at: point)
    }

    func applyContrast(over backgroundColor: NSColor?) {
        badge.applyContrast(over: backgroundColor)
    }

    func configure(
        activeTitle: String,
        activeURL: URL,
        items: [NoteSwitcherItem],
        expanded: Bool,
        anchor: NSPoint,
        placement: NoteSwitcherPlacement,
        showsMinimize: Bool,
        animated: Bool
    ) {
        self.activeTitle = activeTitle
        badge.letter = activeTitle.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "•"
        badge.showsMinimize = showsMinimize
        badge.frame = NSRect(x: anchor.x - 20, y: anchor.y - 20, width: 40, height: 40)
        overlay.frame = bounds
        overlay.isHidden = expanded == false
        if expanded {
            overlay.configure(items: items, activeURL: activeURL, anchor: anchor, placement: placement, animated: animated)
        }
        badge.toolTip = nil
    }
}

@MainActor
private final class FloatingBadgeView: NSView {
    var onActivate: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragging: ((NSPoint) -> Void)?
    var onMoved: ((NSPoint) -> Void)?
    var letter: String = "•" { didSet { needsDisplay = true } }
    var showsMinimize = false { didSet { needsDisplay = true } }
    private var trackingAreaReference: NSTrackingArea?
    private var dragStartMouseLocation: NSPoint?
    private var didDrag = false
    private var letterColor = NSColor.labelColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 8
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow?.shadowOffset = NSSize(width: 0, height: -2)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        dragStartMouseLocation = NSEvent.mouseLocation
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouseLocation else { return }
        let currentMouse = NSEvent.mouseLocation
        let deltaX = currentMouse.x - startMouse.x
        let deltaY = currentMouse.y - startMouse.y
        if hypot(deltaX, deltaY) >= 3 { didDrag = true }
        if didDrag { onDragging?(currentMouse) }
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = didDrag == false
        let movedPoint = didDrag ? Optional(NSEvent.mouseLocation) : nil
        dragStartMouseLocation = nil
        didDrag = false
        if shouldActivate {
            onActivate?()
        } else if let movedPoint {
            onMoved?(movedPoint)
        }
    }

    func applyContrast(over backgroundColor: NSColor?) {
        let converted = backgroundColor?.usingColorSpace(.sRGB)
        let luminance: CGFloat
        if let converted {
            luminance = (0.2126 * converted.redComponent) + (0.7152 * converted.greenComponent) + (0.0722 * converted.blueComponent)
        } else {
            luminance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.2 : 0.8
        }
        let background: NSColor
        if luminance < 0.48 {
            background = NSColor(calibratedWhite: 0.96, alpha: 1)
            letterColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        } else {
            background = NSColor(calibratedWhite: 0.12, alpha: 1)
            letterColor = .white
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = letterColor.withAlphaComponent(0.18).cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let glyph = showsMinimize ? "−" : letter
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: showsMinimize ? 19 : 17, weight: .semibold),
            .foregroundColor: letterColor
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        let grip = "•••"
        let gripAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 5),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let gripSize = grip.size(withAttributes: gripAttributes)
        grip.draw(at: NSPoint(x: bounds.midX - gripSize.width / 2, y: 3), withAttributes: gripAttributes)
    }
}
