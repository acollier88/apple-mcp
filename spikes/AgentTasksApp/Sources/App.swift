import SwiftUI

@main
struct AgentTasksApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 40))
                Text("AgentTasks").font(.title2.bold())
                Text("Exposes the agent task queue to Siri, Shortcuts, and Spotlight via App Intents. Nothing to configure here — try \"Check agent tasks\" in Shortcuts or Siri.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 420)
            .task {
                AgentTasksShortcuts.updateAppShortcutParameters()
                if #available(macOS 27.0, *) {
                    await SpotlightDonation.donateOpenTasks()
                }
            }
        }
    }
}
