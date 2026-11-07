import Foundation

/// Static content of the About window: every external URL lives here.
enum AboutData {
    struct Donation: Identifiable {
        let title: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    /// One language edition of a book; the label is written in its own language and is never translated.
    struct Edition: Identifiable {
        let label: String
        let url: URL
        var id: String { label }
    }

    struct Book: Identifiable {
        let title: String
        let turkishTitle: String
        let editions: [Edition]
        let coverURL: URL
        var id: String { title }
        var titleLine: String { "\(title) · \(turkishTitle)" }
    }

    struct Link: Identifiable {
        let title: String
        let subtitle: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    static let websiteURL = url("https://cybokron.com")
    static let issuesURL = url("https://github.com/ercanatay/cybokron-dock-groups/issues")

    static let donations = [
        Donation(title: "Buy Me a Coffee", symbol: "cup.and.saucer.fill", url: url("https://buymeacoffee.com/ercanatay")),
        Donation(title: "Ko-fi", symbol: "heart.fill", url: url("https://ko-fi.com/ercanatay")),
        Donation(title: "GitHub Sponsors", symbol: "star.circle.fill", url: url("https://github.com/sponsors/ercanatay")),
    ]

    static let books = [
        Book(title: "HOPE", turkishTitle: "UMUT",
             editions: [
                 Edition(label: "English", url: url("https://www.ercanatay.com/en/hope/")),
                 Edition(label: "Türkçe", url: url("https://www.ercanatay.com/umut/")),
             ],
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover1-LQ-scaled.jpeg")),
        Book(title: "YELLOW", turkishTitle: "SARI",
             editions: [
                 Edition(label: "English", url: url("https://www.ercanatay.com/en/yellow/")),
                 Edition(label: "Türkçe", url: url("https://www.ercanatay.com/sari/")),
             ],
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover-scaled.jpg")),
        Book(title: "Digital Marketing in Healthcare", turkishTitle: "Sağlık Sektöründe Dijital Pazarlama",
             editions: [
                 Edition(label: "English", url: url("https://www.ercanatay.com/en/digital-marketing-in-healthcare/")),
                 Edition(label: "Türkçe", url: url("https://www.ercanatay.com/saglik")),
             ],
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/English-Book-2.png")),
        Book(title: "International SEO", turkishTitle: "Uluslararası SEO",
             editions: [
                 Edition(label: "English", url: url("https://www.ercanatay.com/en/international-seo/")),
                 Edition(label: "Türkçe", url: url("https://www.ercanatay.com/uluslararasi-seo/")),
             ],
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Book-2-EN.png")),
        Book(title: "Marketing in Health Tourism", turkishTitle: "Sağlık Turizminde Pazarlama",
             editions: [
                 Edition(label: "Türkçe", url: url("https://www.ercanatay.com/saglik-turizminde-pazarlama/")),
                 Edition(label: "English", url: url("https://www.ercanatay.com/en/marketing-in-health-tourism/")),
                 Edition(label: "Deutsch", url: url("https://www.ercanatay.com/de/marketing-im-gesundheitstourismus/")),
                 Edition(label: "العربية", url: url("https://www.ercanatay.com/ar/marketing-in-health-tourism/")),
             ],
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/saglik-turizminde-pazarlama-kapak.webp")),
    ]

    static let projects = [
        Link(title: "cybokron-dock-groups", subtitle: L10n.About.Project.dockGroups,
             symbol: "square.stack.3d.up.fill", url: url("https://github.com/ercanatay/cybokron-dock-groups")),
        Link(title: "intel-computer-use", subtitle: L10n.About.Project.intelComputerUse,
             symbol: "desktopcomputer", url: url("https://github.com/ercanatay/intel-computer-use")),
        Link(title: "cybokron-exchange-rate-and-portfolio-tracking", subtitle: L10n.About.Project.exchangeRate,
             symbol: "chart.line.uptrend.xyaxis", url: url("https://github.com/ercanatay/cybokron-exchange-rate-and-portfolio-tracking")),
        Link(title: "cybokron-backlink-checker", subtitle: L10n.About.Project.backlinkChecker,
             symbol: "link", url: url("https://github.com/ercanatay/cybokron-backlink-checker")),
        Link(title: "cybokron-consent-manager-translations-yootheme", subtitle: L10n.About.Project.consentManager,
             symbol: "globe", url: url("https://github.com/ercanatay/cybokron-consent-manager-translations-yootheme")),
        Link(title: "cybokron-antigravity-manager-updater", subtitle: L10n.About.Project.antigravityUpdater,
             symbol: "arrow.triangle.2.circlepath", url: url("https://github.com/ercanatay/cybokron-antigravity-manager-updater")),
        Link(title: "cybokron-advanced-widget-visibility", subtitle: L10n.About.Project.widgetVisibility,
             symbol: "eye", url: url("https://github.com/ercanatay/cybokron-advanced-widget-visibility")),
        Link(title: "cybokron-forbidden-content-checker", subtitle: L10n.About.Project.forbiddenContent,
             symbol: "exclamationmark.shield", url: url("https://github.com/ercanatay/cybokron-forbidden-content-checker")),
        Link(title: "cybokron-limit-guard", subtitle: L10n.About.Project.limitGuard,
             symbol: "gauge.with.needle", url: url("https://github.com/ercanatay/cybokron-limit-guard")),
    ]

    static let blogs = [
        Link(title: "Medium (Türkçe)", subtitle: "ercanatay.medium.com", symbol: "text.book.closed",
             url: url("https://ercanatay.medium.com")),
        Link(title: "Medium (English)", subtitle: "ercanataycom.medium.com", symbol: "text.book.closed",
             url: url("https://ercanataycom.medium.com")),
    ]

    private static func url(_ string: String) -> URL { URL(string: string)! }
}
