import Foundation

/// Static content of the About window: every external URL lives here.
enum AboutData {
    struct Donation: Identifiable {
        let title: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    struct Book: Identifiable {
        let title: String
        let turkishTitle: String?
        let englishURL: URL
        let turkishURL: URL
        let coverURL: URL
        var id: String { title }
        var titleLine: String { turkishTitle.map { "\(title) (\($0))" } ?? title }
    }

    struct Link: Identifiable {
        let title: String
        let subtitle: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    static let issuesURL = url("https://github.com/ercanatay/cybokron-dock-groups/issues")

    static let donations = [
        Donation(title: "Buy Me a Coffee", symbol: "cup.and.saucer.fill", url: url("https://buymeacoffee.com/ercanatay")),
        Donation(title: "Ko-fi", symbol: "heart.fill", url: url("https://ko-fi.com/ercanatay")),
        Donation(title: "GitHub Sponsors", symbol: "star.circle.fill", url: url("https://github.com/sponsors/ercanatay")),
    ]

    static let books = [
        Book(title: "HOPE", turkishTitle: "UMUT",
             englishURL: url("https://www.ercanatay.com/en/hope/"),
             turkishURL: url("https://www.ercanatay.com/umut/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover1-LQ-scaled.jpeg")),
        Book(title: "YELLOW", turkishTitle: "SARI",
             englishURL: url("https://www.ercanatay.com/en/yellow/"),
             turkishURL: url("https://www.ercanatay.com/sari/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Cover-scaled.jpg")),
        Book(title: "Digital Marketing in Healthcare", turkishTitle: "Sağlıkta Dijital Pazarlama",
             englishURL: url("https://www.ercanatay.com/en/digital-marketing-in-healthcare/"),
             turkishURL: url("https://www.ercanatay.com/saglik"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/English-Book-2.png")),
        Book(title: "International SEO", turkishTitle: "Uluslararası SEO",
             englishURL: url("https://www.ercanatay.com/en/international-seo/"),
             turkishURL: url("https://www.ercanatay.com/uluslararasi-seo/"),
             coverURL: url("https://www.ercanatay.com/wp-content/uploads/Book-2-EN.png")),
    ]

    static let projects = [
        Link(title: "Cybokron Dock Groups", subtitle: "This app · source on GitHub",
             symbol: "square.stack.3d.up.fill", url: url("https://github.com/ercanatay/cybokron-dock-groups")),
        Link(title: "GitHub Profile", subtitle: "github.com/ercanatay · all repositories",
             symbol: "chevron.left.forwardslash.chevron.right", url: url("https://github.com/ercanatay")),
        Link(title: "Backlink Checker", subtitle: "backlink.ercanatay.com",
             symbol: "link", url: url("https://backlink.ercanatay.com")),
    ]

    static let blogs = [
        Link(title: "Medium (Türkçe)", subtitle: "ercanatay.medium.com", symbol: "text.book.closed",
             url: url("https://ercanatay.medium.com")),
        Link(title: "Medium (English)", subtitle: "ercanataycom.medium.com", symbol: "text.book.closed",
             url: url("https://ercanataycom.medium.com")),
    ]

    private static func url(_ string: String) -> URL { URL(string: string)! }
}
