import AppKit
import BridgeCore
import BridgeMCP
import Foundation
import SwiftUI

@main
enum ASCBridgeMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--smoke-server") {
            await runSmokeServer()
        } else if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
                  CommandLine.arguments.indices.contains(index + 1) {
            renderPreview(to: CommandLine.arguments[index + 1])
        } else {
            ASCBridgeApp.main()
        }
    }

    // Render onboarding without starting the app, accessing Keychain or opening
    // an HTTP listener. Useful for checking the native layout on build machines.
    @MainActor
    private static func renderPreview(to path: String) {
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let content = ConnectionView(model: AppModel())
            .frame(width: 820, height: 740)
            .environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 740)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            try png.write(to: URL(fileURLWithPath: path))
        } catch { exit(1) }
    }

    // A synthetic, explicitly selected test harness. It never constructs a Keychain
    // store or Apple client and cannot perform real App Store Connect requests.
    private static func runSmokeServer() async {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--audit-file"), args.indices.contains(index + 1) else {
            FileHandle.standardError.write(Data("--smoke-server requires --audit-file <temporary path>\n".utf8))
            exit(2)
        }
        do {
            let audit = try AuditStore(fileURL: URL(fileURLWithPath: args[index + 1]))
            let host = MCPHost(service: SmokeASCService(), audit: audit, token: "asc-bridge-smoke-token", port: 43130)
            try await host.run {
                FileHandle.standardOutput.write(Data("SMOKE_READY\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("Synthetic MCP server failed.\n".utf8))
            exit(1)
        }
    }
}

private struct SmokeASCService: ASCServing {
    func call(_ operation: ASCOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await Task.sleep(for: .milliseconds(20))
        return .object(["operation": .string(operation.rawValue), "arguments": .object(arguments), "synthetic": .bool(true)])
    }
}

struct ASCBridgeApp: App {
    @NSApplicationDelegateAdaptor(BridgeAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ASC Bridge", id: "main") {
            MainView(model: model)
                .frame(minWidth: 900, minHeight: 650)
                .task { await model.start() }
        }
        .defaultSize(width: 1040, height: 740)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("O ASC Bridge") { NSApplication.shared.orderFrontStandardAboutPanel() }
            }
        }
    }
}

@MainActor
final class BridgeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
