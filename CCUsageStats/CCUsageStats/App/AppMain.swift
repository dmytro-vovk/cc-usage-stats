import SwiftUI

/// Process entry point. `--mcp-server` turns this launch into the stdio MCP
/// server agents spawn (see `MCPServer`) — it branches before SwiftUI, so no
/// menu-bar item and no app state. Anything else is the menu-bar app.
@main
enum AppMain {
    static func main() {
        if MCPServer.isRequested(arguments: CommandLine.arguments) { MCPServer.runStdio() }
        AppearanceOverride.installIfRequested()
        CCUsageStatsApp.main()
    }
}
