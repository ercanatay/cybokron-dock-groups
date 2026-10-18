import AppKit

/// The icon of a website item: a white globe on a blue rounded square, drawn to sit among app
/// icons (same body size and corner shape as macOS app icons). It's drawn locally; nothing is
/// fetched from the website.
@MainActor
public enum WebsiteIcon {
    /// Resolution independent: drawn afresh at whatever size it's shown.
    public static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.accessibilityDescription = "Website"
        return image
    }()

    /// The rounded square takes the middle 80 % of the image, as app icon bodies do.
    static let bodyFraction: CGFloat = 0.8
    /// Corner radius of the rounded square, as a fraction of its side.
    static let cornerFraction: CGFloat = 0.225

    private static func draw(in rect: NSRect) {
        let side = min(rect.width, rect.height) * bodyFraction
        let body = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let shape = NSBezierPath(roundedRect: body, xRadius: side * cornerFraction, yRadius: side * cornerFraction)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.015)
        shadow.shadowBlurRadius = side * 0.03
        shadow.set()
        NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        let gradient = NSGradient(
            starting: NSColor(srgbRed: 0.33, green: 0.68, blue: 1, alpha: 1),
            ending: NSColor(srgbRed: 0.1, green: 0.36, blue: 0.88, alpha: 1)
        )
        gradient?.draw(in: shape, angle: -90)

        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.58, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = globe.size
        globe.draw(
            in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }
}
