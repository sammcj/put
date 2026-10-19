import Foundation
@testable import PutCore
import Testing

@Suite("Config.urlCommandsEnabled")
struct ConfigURLCommandsTests {
    @Test
    func offByDefault() {
        #expect(!Config.bootstrap().urlCommandsEnabled)
    }

    @Test
    func configWrittenBeforeTheSettingExistedDecodesAsOff() throws {
        let layoutID = UUID()
        let json = """
        {"schemaVersion": \(putSchemaVersion), "layouts": [{"id": "\(layoutID)", "name": "Default", "rules": []}],
         "activeLayoutID": "\(layoutID)"}
        """
        let decoded = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(!decoded.urlCommandsEnabled)
    }

    @Test
    func enabledSurvivesRoundTrip() throws {
        var config = Config.bootstrap()
        config.urlCommandsEnabled = true
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.urlCommandsEnabled)
    }
}
