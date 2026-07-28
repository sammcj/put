import Foundation
import PutCore
import PutTestSupport
@testable import PutUI
import Testing

@Suite("MenuBarModel")
struct MenuBarModelTests {
    @Test
    func layoutItemsMarkTheActiveOne() {
        let coding = PutCore.Layout(name: "Coding")
        let meetings = PutCore.Layout(name: "Meetings")

        let items = MenuBarModel.layoutItems(layouts: [coding, meetings], activeLayoutID: meetings.id)

        #expect(items == [
            MenuBarModel.LayoutItem(id: coding.id, title: "Coding", isActive: false),
            MenuBarModel.LayoutItem(id: meetings.id, title: "Meetings", isActive: true)
        ])
    }

    @Test
    func layoutItemsMarkNoneWhenActiveIDIsStale() {
        let coding = PutCore.Layout(name: "Coding")

        let items = MenuBarModel.layoutItems(layouts: [coding], activeLayoutID: UUID())

        #expect(items.allSatisfy { !$0.isActive })
    }

    @Test
    func jumpTitleUsesDescriptiveLabelWhenSet() {
        let rule = makeRule(descriptiveLabel: "Editor", titlePattern: "Doc")

        #expect(MenuBarModel.jumpTitle(for: rule) == "Editor")
    }

    @Test
    func jumpTitleFallsBackToBundleIDWithTitleSuffix() {
        let rule = makeRule(bundleID: "com.apple.Safari", titlePattern: "GitHub")

        #expect(MenuBarModel.jumpTitle(for: rule) == "com.apple.Safari — GitHub")
    }

    @Test
    func jumpTitleOmitsSuffixWhenApplyingToAllWindows() {
        let rule = makeRule(bundleID: "com.apple.Safari", titlePattern: "GitHub", applyToAllWindows: true)

        #expect(MenuBarModel.jumpTitle(for: rule) == "com.apple.Safari")
    }
}
