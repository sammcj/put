import Foundation
import PutCore
import Testing

@Suite("RestoreComponents")
struct RestoreComponentsTests {
    @Test
    func positionForcesDisplayOnAtInit() {
        let components = RestoreComponents(size: true, position: true, display: false)
        #expect(components.display)
    }

    @Test
    func turningPositionOnTurnsDisplayOn() {
        var components = RestoreComponents.sizeOnly
        components.position = true
        #expect(components.display)
    }

    @Test
    func turningDisplayOffTurnsPositionOff() {
        var components = RestoreComponents.sizeAndPosition
        components.display = false
        #expect(!components.position)
        #expect(components.size)
    }

    @Test
    func namedSetsMatchTheirLegacyScopes() {
        #expect(RestoreScope.sizeAndPosition.components == .sizeAndPosition)
        #expect(RestoreScope.sizeOnly.components == .sizeOnly)
        #expect(RestoreScope.displayOnly.components == .displayOnly)
    }

    @Test(arguments: [
        (RestoreComponents.sizeAndPosition, RestoreWrite.frame),
        (RestoreComponents.sizeOnly, RestoreWrite.size),
        (RestoreComponents.displayOnly, RestoreWrite.position),
        (RestoreComponents(size: true, position: false, display: true), RestoreWrite.frame),
        (RestoreComponents(size: false, position: true, display: true), RestoreWrite.position),
        (RestoreComponents(size: false, position: false, display: false), RestoreWrite.nothing),
    ])
    func writeKindFollowsComponents(_ components: RestoreComponents, _ expected: RestoreWrite) {
        #expect(components.write == expected)
    }

    @Test
    func emptySetIsInertAndMovesNothing() {
        let components = RestoreComponents(size: false, position: false, display: false)
        #expect(components.isEmpty)
        #expect(!components.movesWindow)
        #expect(!components.usesSavedFrame)
    }

    @Test
    func closestLegacyScopeNeverWidensAPositionTheUserCleared() {
        // Anything with position off must not map to .sizeAndPosition, which an
        // older build would replay in full.
        for size in [true, false] {
            for display in [true, false] {
                let components = RestoreComponents(size: size, position: false, display: display)
                #expect(RestoreScope.closest(to: components) != .sizeAndPosition)
            }
        }
        #expect(RestoreScope.closest(to: .sizeAndPosition) == .sizeAndPosition)
    }
}
