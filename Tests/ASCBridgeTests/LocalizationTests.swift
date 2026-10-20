import Foundation
import XCTest
@testable import ASCBridge

final class LocalizationTests: XCTestCase {
    func testEnglishStringCatalogIsCompiledIntoAppResources() throws {
        let bundle = Bundle.module

        XCTAssertTrue(bundle.localizations.contains("en"))
        let stringsURL = try XCTUnwrap(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stringsURL.path))
        XCTAssertEqual(bundle.localizedString(forKey: "Connection", value: nil, table: nil), "Connection")
    }

    func testServerStatusLabelsUseEnglishSourceStrings() {
        XCTAssertEqual(AppModel.ServerState.starting.label, "Starting")
        XCTAssertEqual(AppModel.ServerState.running.label, "MCP running locally")
        XCTAssertEqual(AppModel.ServerState.failed.label, "MCP unavailable")
    }

    func testInterpolatedDurationUsesEnglishCatalogFormat() {
        let duration = String(localized: "\(42) ms", bundle: Bundle.module, comment: "Test localization of elapsed milliseconds.")
        XCTAssertEqual(duration, "42 ms")
    }
}
