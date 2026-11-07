import Foundation
import Testing
@testable import CybokronDockGroups

@Test func everyBookHasAnHTTPSEditionAndCover() {
    for book in AboutData.books {
        #expect(!book.editions.isEmpty, "\(book.title) has no editions")
        for url in book.editions.map(\.url) + [book.coverURL] {
            #expect(url.scheme == "https" && url.host != nil, "\(book.title): \(url)")
        }
        #expect(Set(book.editions.map(\.label)).count == book.editions.count, "\(book.title) repeats a label")
    }
}

@Test func healthTourismBookHasFourEditions() throws {
    let book = try #require(AboutData.books.first { $0.title == "Marketing in Health Tourism" })
    #expect(book.turkishTitle == "Sağlık Turizminde Pazarlama")
    #expect(book.editions.map(\.label) == ["Türkçe", "English", "Deutsch", "العربية"])
    #expect(book.editions.map(\.url.absoluteString) == [
        "https://www.ercanatay.com/saglik-turizminde-pazarlama/",
        "https://www.ercanatay.com/en/marketing-in-health-tourism/",
        "https://www.ercanatay.com/de/marketing-im-gesundheitstourismus/",
        "https://www.ercanatay.com/ar/marketing-in-health-tourism/",
    ])
    #expect(AboutData.books.last?.title == book.title)
}

@Test func limitGuardProjectIsListedWithLocalizedSubtitle() throws {
    let project = try #require(AboutData.projects.first { $0.title == "cybokron-limit-guard" })
    #expect(project.url.absoluteString == "https://github.com/ercanatay/cybokron-limit-guard")
    #expect(!project.subtitle.isEmpty && project.subtitle != "about.project.limitGuard")
    for link in AboutData.projects { #expect(link.url.scheme == "https") }
}
