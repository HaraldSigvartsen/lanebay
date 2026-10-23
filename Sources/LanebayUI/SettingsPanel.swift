import AppKit
import LanebayCore
import SwiftUI

@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var preferences: AppPreferences
    public private(set) var errorMessage: String?
    public private(set) var canWritePreferences = true
    public private(set) var customExecutableError: String?
    public private(set) var profileError: String?
    public var executableSearchDirectories: [URL]
    public private(set) var installedKnownAgentIDs: Set<String> = []
    private let store: AppPreferencesStore
    private let fileManager: FileManager

    public init(
        store: AppPreferencesStore = AppPreferencesStore(),
        executableSearchDirectories: [URL] = AgentCatalog.defaultExecutableSearchDirectories,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.executableSearchDirectories = executableSearchDirectories
        self.fileManager = fileManager
        do {
            preferences = try store.load()
        } catch {
            preferences = AppPreferences()
            canWritePreferences = false
            errorMessage = "Could not load preferences: \(error.localizedDescription)"
        }
        refreshInstalledKnownAgents()
    }

    public func setRestoreLastWorkspace(_ value: Bool) {
        var updated = preferences
        updated.restoreLastWorkspace = value
        persist(updated)
    }

    public func setShowNotifications(_ value: Bool) {
        var updated = preferences
        updated.showNotifications = value
        persist(updated)
    }

    public func setSpeakWaitingForInputStatus(_ value: Bool) {
        var updated = preferences
        updated.speakWaitingForInputStatus = value
        persist(updated)
    }

    public func setAskBeforeSendingToTerminal(_ value: Bool) {
        var updated = preferences
        updated.askBeforeSendingToTerminal = value
        persist(updated)
    }

    public func setDefaultWorkingDirectory(_ url: URL?) {
        var updated = preferences
        updated.defaultWorkingDirectory = url
        persist(updated)
    }

    public func resetPreferences() {
        do {
            try store.save(AppPreferences())
            preferences = AppPreferences()
            canWritePreferences = true
            errorMessage = nil
        } catch {
            errorMessage = "Could not reset preferences: \(error.localizedDescription)"
        }
    }

    public func recordActiveWorkspace(_ id: UUID) {
        guard preferences.restoreLastWorkspace else { return }
        var updated = preferences
        updated.lastWorkspaceID = id
        persist(updated)
    }

    public func newTerminalDraft(homeDirectory: URL? = nil) -> NewTerminalDraft {
        NewTerminalDraft.make(
            knownAgents: AgentCatalog.knownCLIs,
            customExecutables: preferences.customExecutables,
            lastUsedAgentID: preferences.lastUsedAgentID,
            recentDirectories: preferences.recentWorkingDirectories,
            defaultDirectory: preferences.defaultWorkingDirectory,
            homeDirectory: homeDirectory ?? fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
    }

    public func offersNewTerminalAgent(_ agentID: String) -> Bool {
        NewTerminalDraft.agents(
            knownAgents: AgentCatalog.knownCLIs,
            customExecutables: preferences.customExecutables
        ).contains { $0.id == agentID }
    }

    public func validatedWorkingDirectory(_ url: URL) -> URL? {
        NewTerminalDraft.validatedDirectory(url, fileManager: fileManager)
    }

    @discardableResult
    public func rememberNewTerminal(agentID: String, directory: URL) -> Bool {
        let trimmed = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NewTerminalDraft.isAcceptableAgentID(trimmed),
            let remembered = NewTerminalDraft.rememberedDirectories(
                existing: preferences.recentWorkingDirectories,
                chosen: directory,
                fileManager: fileManager)
        else { return false }
        var updated = preferences
        updated.lastUsedAgentID = trimmed
        updated.recentWorkingDirectories = remembered
        persist(updated)
        return errorMessage == nil && preferences.lastUsedAgentID == trimmed
    }

    private func persist(_ updated: AppPreferences) {
        guard canWritePreferences else { return }
        do {
            try store.save(updated)
            preferences = updated
            errorMessage = nil
        } catch {
            errorMessage = "Could not save preferences: \(error.localizedDescription)"
        }
    }

    public func refreshInstalledKnownAgents() {
        installedKnownAgentIDs = AgentCatalog.detectInstalledKnownAgents(
            searchDirectories: executableSearchDirectories,
            fileManager: fileManager
        )
    }

    public var knownAgents: [KnownAgentCLI] { AgentCatalog.knownCLIs }

    public var customExecutables: [CustomAgentExecutable] { preferences.customExecutables }
    public var accountProfiles: [AgentAccountProfile] { preferences.accountProfiles }

    public func upsertCustomExecutable(_ executable: CustomAgentExecutable) -> Bool {
        do {
            try AgentCatalog.validate(custom: executable, fileManager: fileManager)
            var updated = preferences
            if let index = updated.customExecutables.firstIndex(where: { $0.id == executable.id }) {
                updated.customExecutables[index] = executable
            } else {
                updated.customExecutables.append(executable)
            }
            persist(updated)
            customExecutableError = nil
            return errorMessage == nil
        } catch {
            customExecutableError = error.localizedDescription
            return false
        }
    }

    public func removeCustomExecutable(id: String) {
        var updated = preferences
        updated.customExecutables.removeAll { $0.id == id }
        persist(updated)
    }

    public func upsertAccountProfile(_ profile: AgentAccountProfile) -> Bool {
        do {
            try AgentCatalog.validate(profile: profile)
            var updated = preferences
            if let index = updated.accountProfiles.firstIndex(where: { $0.id == profile.id }) {
                updated.accountProfiles[index] = profile
            } else {
                updated.accountProfiles.append(profile)
            }
            persist(updated)
            profileError = nil
            return errorMessage == nil
        } catch {
            profileError = error.localizedDescription
            return false
        }
    }

    public func removeAccountProfile(id: String) {
        var updated = preferences
        updated.accountProfiles.removeAll { $0.id == id }
        persist(updated)
    }
}

public struct SettingsPanel: View {
    @Bindable private var model: SettingsViewModel
    @State private var customName = ""
    @State private var customPath = ""
    @State private var customArgs = ""
    @State private var profileName = ""
    @State private var profileAgentID = "codex"
    @State private var profileEnvironment = ""

    public init(model: SettingsViewModel) { self.model = model }

    public var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore last workspace", isOn: Binding(
                    get: { model.preferences.restoreLastWorkspace },
                    set: { model.setRestoreLastWorkspace($0) }
                )).disabled(!model.canWritePreferences)
                directorySetting
            }
            Section("Notifications") {
                Toggle("Show agent notifications", isOn: Binding(
                    get: { model.preferences.showNotifications },
                    set: { model.setShowNotifications($0) }
                )).disabled(!model.canWritePreferences)
            }
            Section("Orchestrator") {
                Toggle("Ask before sending to a terminal", isOn: Binding(
                    get: { model.preferences.askBeforeSendingToTerminal },
                    set: { model.setAskBeforeSendingToTerminal($0) }
                ))
                .disabled(!model.canWritePreferences)
                .accessibilityIdentifier("settings.askBeforeSending")
                Text("A send shows the target and the text before anything is written. Agent permission prompts are never answered automatically.")
                    .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
            }
            Section("Voice") {
                Toggle("Speak waiting-for-input status", isOn: Binding(
                    get: { model.preferences.speakWaitingForInputStatus },
                    set: { model.setSpeakWaitingForInputStatus($0) }
                )).disabled(!model.canWritePreferences)
                Text("Uses local macOS text-to-speech only. Off by default.")
                    .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
            }
            Section("Agent catalog") {
                Text("Known CLIs: \(model.knownAgents.count) · installed: \(model.installedKnownAgentIDs.count)")
                    .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                Button("Rescan installed CLIs") {
                    model.refreshInstalledKnownAgents()
                }
                ForEach(model.knownAgents, id: \.id) { agent in
                    HStack {
                        Text(agent.displayName)
                        Spacer()
                        Text(agent.executableName).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                        if model.installedKnownAgentIDs.contains(agent.id) {
                            Text("Installed").font(Typography.caption).foregroundStyle(Palette.accent)
                        }
                    }
                }
            }
            Section("Custom executable") {
                TextField("Name", text: $customName)
                TextField("Absolute executable path", text: $customPath)
                TextField("Args (space-separated)", text: $customArgs)
                Button("Add custom executable") {
                    let executable = CustomAgentExecutable(
                        displayName: customName,
                        executablePath: customPath,
                        arguments: parseArguments(customArgs))
                    if model.upsertCustomExecutable(executable) {
                        customName = ""
                        customPath = ""
                        customArgs = ""
                    }
                }.disabled(!model.canWritePreferences)
                ForEach(model.customExecutables, id: \.id) { executable in
                    HStack {
                        Text(executable.displayName)
                        Spacer()
                        Text(executable.executablePath).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                        Button("Remove") { model.removeCustomExecutable(id: executable.id) }
                    }
                }
            }
            Section("Account profiles") {
                TextField("Profile name", text: $profileName)
                Picker("Agent", selection: $profileAgentID) {
                    ForEach((model.knownAgents.map(\.id) + model.customExecutables.map(\.id)).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                TextField("Environment (KEY=VALUE, comma-separated)", text: $profileEnvironment)
                Button("Add profile") {
                    let profile = AgentAccountProfile(
                        name: profileName, agentID: profileAgentID,
                        environment: parseEnvironment(profileEnvironment))
                    if model.upsertAccountProfile(profile) {
                        profileName = ""
                        profileEnvironment = ""
                    }
                }.disabled(!model.canWritePreferences)
                ForEach(model.accountProfiles, id: \.id) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        Text(profile.agentID).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                        Button("Remove") { model.removeAccountProfile(id: profile.id) }
                    }
                }
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(Typography.caption).foregroundStyle(Palette.status(.error))
                    .textSelection(.enabled)
                if !model.canWritePreferences {
                    Button("Reset preferences") { model.resetPreferences() }
                }
            }
            if let customError = model.customExecutableError {
                Text(customError).font(Typography.caption).foregroundStyle(Palette.status(.error))
            }
            if let profileError = model.profileError {
                Text(profileError).font(Typography.caption).foregroundStyle(Palette.status(.error))
            }
        }
        .formStyle(.grouped)
        .tint(Palette.accent)
        .padding(Spacing.sm)
    }

    @ViewBuilder private var directorySetting: some View {
        LabeledContent("Default working folder") {
            HStack {
                Text(model.preferences.defaultWorkingDirectory?.path ?? "Home folder")
                    .font(Typography.caption).foregroundStyle(Palette.secondaryInk).lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") { chooseDirectory() }.disabled(!model.canWritePreferences)
                if model.preferences.defaultWorkingDirectory != nil {
                    Button("Reset") { model.setDefaultWorkingDirectory(nil) }.disabled(!model.canWritePreferences)
                        .accessibilityLabel("Reset default working folder")
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK { model.setDefaultWorkingDirectory(panel.url) }
    }

    private func parseArguments(_ value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func parseEnvironment(_ value: String) -> [String: String] {
        var parsed: [String: String] = [:]
        for pair in value.split(separator: ",") {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { parsed[key] = val }
        }
        return parsed
    }
}
