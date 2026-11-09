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

    public func setAppearance(_ mode: AppearanceMode) {
        var updated = preferences
        updated.appearance = mode
        persist(updated)
        Self.applyAppearance(preferences.appearance)
    }

    /// Forces the app-wide appearance (dark/light) or follows macOS for `.system`.
    @MainActor public static func applyAppearance(_ mode: AppearanceMode) {
        guard let app = NSApp else { return }
        app.appearance = mode.appearanceName.flatMap { NSAppearance(named: NSAppearance.Name($0)) }
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
            fileManager: fileManager,
            lastModels: preferences.lastModelByAgentID
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
    public func rememberNewTerminal(agentID: String, directory: URL, model: String? = nil) -> Bool {
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
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ProviderModels.supportsModel(trimmed), ProviderModels.isAcceptableModel(trimmedModel) {
            updated.lastModelByAgentID[trimmed] = trimmedModel
        } else {
            updated.lastModelByAgentID[trimmed] = nil
        }
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
    private let onOpenUsage: (() -> Void)?
    @State private var customName = ""
    @State private var customPath = ""
    @State private var customArgs = ""
    @State private var profileName = ""
    @State private var profileAgentID = "codex"
    @State private var profileEnvironment = ""

    public init(model: SettingsViewModel, onOpenUsage: (() -> Void)? = nil) {
        self.model = model
        self.onOpenUsage = onOpenUsage
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                section("Generelt") { generalControls }
                section("Leverandører og modeller") { providerControls }
                section("Utseende") { appearanceNote }
                section("Bruk") { usageControls }
                errorLines
            }
            .padding(DS.Space.md)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Sections

    private func section<Content: View>(_ caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(caption).sectionCaptionStyle()
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                content()
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(radius: DS.Radius.card)
        }
    }

    private var generalControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Picker("Utseende", selection: Binding(
                get: { model.preferences.appearance },
                set: { model.setAppearance($0) }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!model.canWritePreferences)
            .accessibilityIdentifier("settings.appearance")
            Toggle("Gjenopprett siste arbeidsområde", isOn: Binding(
                get: { model.preferences.restoreLastWorkspace },
                set: { model.setRestoreLastWorkspace($0) }
            )).disabled(!model.canWritePreferences)
            Toggle("Vis varsler fra agenter", isOn: Binding(
                get: { model.preferences.showNotifications },
                set: { model.setShowNotifications($0) }
            )).disabled(!model.canWritePreferences)
            Toggle("Spør før sending til en terminal", isOn: Binding(
                get: { model.preferences.askBeforeSendingToTerminal },
                set: { model.setAskBeforeSendingToTerminal($0) }
            ))
            .disabled(!model.canWritePreferences)
            .accessibilityIdentifier("settings.askBeforeSending")
            Text("En sending viser mottaker og tekst før noe skrives. Agentenes egne tillatelsesspørsmål besvares aldri automatisk.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryInk)
            Toggle("Les opp «venter på input»", isOn: Binding(
                get: { model.preferences.speakWaitingForInputStatus },
                set: { model.setSpeakWaitingForInputStatus($0) }
            )).disabled(!model.canWritePreferences)
            Text("Bruker kun lokal macOS tale. Av som standard.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryInk)
            directorySetting
        }
        .toggleStyle(TrailingSwitchToggleStyle())
    }

    private var providerControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text("\(model.installedKnownAgentIDs.count) av \(model.knownAgents.count) CLI-er installert")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryInk)
                Spacer(minLength: DS.Space.xs)
                Button("Skann på nytt") { model.refreshInstalledKnownAgents() }
                    .buttonStyle(.lbSecondary)
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(NewTerminalDraft.featuredAgentIDs, id: \.self) { agentID in
                    providerRow(agentID)
                }
            }

            Text("Egendefinerte agenter").sectionCaptionStyle()
            TextField("Navn", text: $customName)
            TextField("Absolutt sti til kjørbar fil", text: $customPath)
            TextField("Argumenter (atskilt med mellomrom)", text: $customArgs)
            HStack(spacing: DS.Space.xs) {
                Button("Legg til egendefinert agent") {
                    let executable = CustomAgentExecutable(
                        displayName: customName,
                        executablePath: customPath,
                        arguments: parseArguments(customArgs))
                    if model.upsertCustomExecutable(executable) {
                        customName = ""
                        customPath = ""
                        customArgs = ""
                    }
                }
                .buttonStyle(.lbSecondary)
                .disabled(!model.canWritePreferences)
                Spacer(minLength: 0)
            }
            ForEach(model.customExecutables, id: \.id) { executable in
                HStack(spacing: DS.Space.xs) {
                    Text(executable.displayName).font(DS.Font.body)
                    Text(executable.executablePath)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.xs)
                    Button("Fjern") { model.removeCustomExecutable(id: executable.id) }
                        .buttonStyle(.lbGhost)
                }
            }

            Text("Kontoer").sectionCaptionStyle()
            TextField("Profilnavn", text: $profileName)
            Picker("Agent", selection: $profileAgentID) {
                ForEach((model.knownAgents.map(\.id) + model.customExecutables.map(\.id)).sorted(), id: \.self) {
                    Text($0).tag($0)
                }
            }
            TextField("Miljø (NØKKEL=VERDI, atskilt med komma)", text: $profileEnvironment)
            HStack(spacing: DS.Space.xs) {
                Button("Legg til profil") {
                    let profile = AgentAccountProfile(
                        name: profileName, agentID: profileAgentID,
                        environment: parseEnvironment(profileEnvironment))
                    if model.upsertAccountProfile(profile) {
                        profileName = ""
                        profileEnvironment = ""
                    }
                }
                .buttonStyle(.lbSecondary)
                .disabled(!model.canWritePreferences)
                Spacer(minLength: 0)
            }
            ForEach(model.accountProfiles, id: \.id) { profile in
                HStack(spacing: DS.Space.xs) {
                    Text(profile.name).font(DS.Font.body)
                    Text(profile.agentID)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryInk)
                    Spacer(minLength: DS.Space.xs)
                    Button("Fjern") { model.removeAccountProfile(id: profile.id) }
                        .buttonStyle(.lbGhost)
                }
            }
        }
    }

    private func providerRow(_ agentID: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            ProviderBadge(agentID: agentID, size: DS.Space.md + DS.Space.xxs)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(providerTitle(agentID))
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text(installedLabel(agentID))
                    .font(DS.Font.caption)
                    .foregroundStyle(model.installedKnownAgentIDs.contains(agentID) ? DS.Color.status(.done) : DS.Color.mutedInk)
            }
            Spacer(minLength: DS.Space.xs)
            if let remembered = model.preferences.lastModelByAgentID[agentID] {
                Text(remembered)
                    .font(DS.Font.mono)
                    .foregroundStyle(DS.Color.secondaryInk)
                    .lineLimit(1)
            } else {
                Text("Standardmodell")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.mutedInk)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.provider.\(agentID)")
    }

    private func providerTitle(_ agentID: String) -> String {
        if agentID == OrchestratorKind.agentID { return OrchestratorKind.title }
        return model.knownAgents.first { $0.id == agentID }?.displayName ?? agentID
    }

    private func installedLabel(_ agentID: String) -> String {
        if agentID == OrchestratorKind.agentID { return "Innebygd" }
        if agentID == "shell" { return "Alltid tilgjengelig" }
        return model.installedKnownAgentIDs.contains(agentID) ? "Installert" : "Ikke installert"
    }

    private var appearanceNote: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text("Følger macOS-utseendet")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text("Lyst og mørkt tema, statusfarger og materialer tilpasser seg systeminnstillingene. Reduser bevegelse slår av pulsing og glidende overganger.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usageControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Bruk og status-tid")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    Text("Prompts, cron-kjøringer og tid per status, kun lagret lokalt.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.xs)
                Button("Åpne Bruk") { onOpenUsage?() }
                    .buttonStyle(.lbSecondary)
                    .disabled(onOpenUsage == nil)
                    .accessibilityIdentifier("settings.openUsage")
            }
            Text("Kun lokalt · ingen telemetri")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
    }

    @ViewBuilder private var errorLines: some View {
        if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(errorMessage)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.status(.error))
                    .textSelection(.enabled)
                if !model.canWritePreferences {
                    Button("Nullstill preferanser") { model.resetPreferences() }
                        .buttonStyle(.lbSecondary)
                }
            }
        }
        if let customError = model.customExecutableError {
            Text(customError).font(DS.Font.caption).foregroundStyle(DS.Color.status(.error))
        }
        if let profileError = model.profileError {
            Text(profileError).font(DS.Font.caption).foregroundStyle(DS.Color.status(.error))
        }
    }

    @ViewBuilder private var directorySetting: some View {
        HStack(spacing: DS.Space.xs) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Standard arbeidsmappe")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text(model.preferences.defaultWorkingDirectory?.path ?? "Hjemmemappe")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.xs)
            Button("Velg …") { chooseDirectory() }
                .buttonStyle(.lbSecondary)
                .disabled(!model.canWritePreferences)
            if model.preferences.defaultWorkingDirectory != nil {
                Button("Nullstill") { model.setDefaultWorkingDirectory(nil) }
                    .buttonStyle(.lbGhost)
                    .disabled(!model.canWritePreferences)
                    .accessibilityLabel("Nullstill standard arbeidsmappe")
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

/// Settings row: label on the left, switch pinned to the trailing edge.
struct TrailingSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.sm) {
            configuration.label
                .foregroundStyle(DS.Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}
