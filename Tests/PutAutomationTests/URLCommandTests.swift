import Foundation
@testable import PutAutomation
@testable import PutCore
import Testing

@Suite("URLCommand")
struct URLCommandTests {
    private func parse(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init(url:))
    }

    @Test(arguments: [
        ("put://save-active", URLCommand.saveFocusedWindow),
        ("put://save-active-title", .saveFocusedWindowTitleOnly),
        ("put://save-all", .saveAllWindows),
        ("put://restore-active", .restoreActiveWindow),
        ("put://restore-all", .restoreAllWindows),
        ("PUT://Restore-All", .restoreAllWindows)
    ])
    func actionCommands(url: String, expected: URLCommand) {
        #expect(parse(url) == expected)
    }

    @Test
    func layoutByNameDecodesPercentEscapes() {
        #expect(parse("put://layout?name=Docked%20Desk") == .activateLayout(.name("Docked Desk")))
    }

    @Test
    func layoutByID() {
        let id = UUID()
        #expect(parse("put://layout?id=\(id.uuidString)") == .activateLayout(.id(id)))
    }

    @Test(arguments: ["put://layout", "put://layout?name=", "put://layout?id=not-a-uuid"])
    func layoutWithoutUsableReferenceIsRejected(url: String) {
        #expect(parse(url) == nil)
    }

    @Test
    func settingsTabIsOptionalAndLowercased() {
        #expect(parse("put://settings") == .openSettings(tab: nil))
        #expect(parse("put://settings?tab=Rules") == .openSettings(tab: "rules"))
    }

    @Test(arguments: ["put://", "put://delete-everything", "https://restore-all", "put:restore-all"])
    func unknownOrForeignURLsAreRejected(url: String) {
        #expect(parse(url) == nil)
    }

    @Test
    func layoutNamesMatchCaseInsensitivelyAndFirstWins() {
        let first = PutCore.Layout(name: "Docked")
        let second = PutCore.Layout(name: "docked")
        let layouts = [PutCore.Layout(name: "Laptop"), first, second]
        #expect(URLCommand.LayoutReference.name("DOCKED").resolve(in: layouts)?.id == first.id)
        #expect(URLCommand.LayoutReference.id(second.id).resolve(in: layouts)?.id == second.id)
        #expect(URLCommand.LayoutReference.name("Missing").resolve(in: layouts) == nil)
    }
}
