import SwiftUI
import Foundation

enum AppState {
    case idle
    case diskDetected
    case selectProduction
    case transferring
    case done
}

enum CreateFolderStep {
    case enterName
    case confirmName
}

struct ProductionFolder: Identifiable, Hashable {
    let id = UUID()
    let fullName: String
    let displayName: String
}

struct ContentView: View {
    private static let defaultVolumesRootPath = "/Volumes"
    private static let defaultFilmRootPath = "/Volumes/FILM"

    @State private var state: AppState = .idle
    @State private var productionFolders: [ProductionFolder] = []

    @State private var showCreateFolderSheet = false
    @State private var createFolderStep: CreateFolderStep = .enterName

    @State private var newFolderName = ""
    @State private var pendingFolderName = ""

    @State private var showFolderExistsAlert = false
    @State private var showCreateFolderErrorAlert = false
    @State private var createFolderErrorMessage = ""

    @State private var showTransferErrorAlert = false
    @State private var transferErrorMessage = "Kontakta i första hand IT i andra hand Teknik"

    @State private var sourceProjectFolderPath: String? = nil
    @State private var destinationFolderName: String? = nil
    @State private var destinationFolderPath: String? = nil

    @State private var detectedSourceDiskPath: String? = nil
    @State private var detectedSourceVolumeName: String? = nil
    @State private var latestProjectFolderPath: String? = nil

    @State private var completedSourceVolumeName: String? = nil
    @State private var completedSourceProjectName: String? = nil
    @State private var completedSavedInProductionName: String? = nil
    @State private var completedFinalProjectFolderName: String? = nil
    @State private var completedFinalProjectFolderPath: String? = nil

    @State private var selectionTimeoutTimer: Timer? = nil
    @State private var diskMonitoringTimer: Timer? = nil
    @State private var inactivityTimer: Timer? = nil

    @State private var needsManualEject = false
    @State private var sourceDiskIsSafeToRemove = false

    @State private var ignoredDiskPathWhileIdle: String? = nil
    @State private var hasLoggedStartup = false
    @State private var isDebugStateLockEnabled = false
    @State private var isSourceInspectionInProgress = false
    @State private var sourceInspectionToken: Int = 0
    @State private var lastSourceInspectionAt: Date? = nil

    private let filmRootPath: String
    private let volumesRootPath: String
    private let inactivityTimeoutSeconds: TimeInterval = 600
    private let sourceInspectionMinIntervalSeconds: TimeInterval = 10

    init() {
#if DEBUG
        volumesRootPath = Self.resolvedPath(
            fromEnvKey: "INGEST_VOLUMES_ROOT_PATH",
            defaultPath: Self.defaultVolumesRootPath
        )
        filmRootPath = URL(fileURLWithPath: volumesRootPath)
            .appendingPathComponent("FILM")
            .path
#else
        volumesRootPath = Self.defaultVolumesRootPath
        filmRootPath = Self.defaultFilmRootPath
#endif
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinueFromKeyboard: Bool {
        !trimmedNewFolderName.isEmpty
    }

    private var shouldShowPathDebugInfo: Bool {
#if DEBUG
        volumesRootPath != Self.defaultVolumesRootPath
#else
        false
#endif
    }

    private var shouldIgnoreCurrentDiskInIdle: Bool {
        volumesRootPath == Self.defaultVolumesRootPath
    }

    private var sourceSearchRoots: [String] {
        if volumesRootPath == Self.defaultVolumesRootPath {
            return [Self.defaultVolumesRootPath]
        }

        var roots: [String] = [volumesRootPath]
        if volumesRootPath != Self.defaultVolumesRootPath {
            roots.append(Self.defaultVolumesRootPath)
        }
        return roots
    }

    private static func resolvedPath(fromEnvKey key: String, defaultPath: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        let normalizedKey = normalizeEnvKey(key)

        let exactOrNormalizedMatch = environment[key] ?? environment.first { entry in
            normalizeEnvKey(entry.key) == normalizedKey
        }?.value

        guard let envValue = exactOrNormalizedMatch?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !envValue.isEmpty else {
            return defaultPath
        }

        guard envValue.count > 1, envValue.hasSuffix("/") else {
            return envValue
        }

        return String(envValue.dropLast())
    }

    private static func normalizeEnvKey(_ key: String) -> String {
        key.uppercased().filter { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    private func logStartupIfNeeded() {
        guard !hasLoggedStartup else { return }
        hasLoggedStartup = true

        let ingestEnvVars = ProcessInfo.processInfo.environment
            .filter { entry in
                entry.key.contains("INGEST") || entry.key.contains("VOLUMES")
            }
            .sorted { $0.key < $1.key }

        print("[INGEST] Startup")
        print("[INGEST] volumesRootPath = \(volumesRootPath)")
        print("[INGEST] filmRootPath = \(filmRootPath)")

        if ingestEnvVars.isEmpty {
            print("[INGEST] No INGEST/VOLUMES env vars found in process")
        } else {
            for (key, value) in ingestEnvVars {
                print("[INGEST] ENV \(key)=\(value)")
            }
        }
    }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            switch state {
            case .idle:
                statusScreen(
                    message: "Koppla in disk\nför överföring",
                    textColor: .white
                )

            case .diskDetected:
                diskDetectedView

            case .selectProduction:
                selectProductionView

            case .transferring:
                transferringView

            case .done:
                doneView
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .overlay(alignment: .bottomLeading) {
            if shouldShowPathDebugInfo {
                debugPanel
            }
        }
        .onAppear {
            logStartupIfNeeded()
            loadProductionFolders()
            startDiskMonitoring()
            startInactivityTimer()
        }
        .sheet(isPresented: $showCreateFolderSheet) {
            createFolderSheet
        }
        .alert("Fel", isPresented: $showTransferErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(transferErrorMessage)
        }
    }

    // MARK: - STATUS SCREENS

    private func statusScreen(message: String, textColor: Color) -> some View {
        VStack(spacing: 40) {
            Spacer()

            Text(message)
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(textColor)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var diskDetectedView: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Disk upptäckt\nFörbereder överföring...")
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundColor(.black)

            if let detectedSourceVolumeName {
                Text("Disk: \(detectedSourceVolumeName)")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)
                    .padding(.horizontal, 40)
            } else {
                Text("Söker efter disk...")
                    .font(.system(size: 18, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)
                    .padding(.horizontal, 40)
            }

            if let latestProjectFolderPath {
                Text("Senaste projektmapp:\n\(URL(fileURLWithPath: latestProjectFolderPath).lastPathComponent)")
                    .font(.system(size: 18, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)
                    .padding(.horizontal, 40)
            } else {
                Text("Läser material från disken...")
                    .font(.system(size: 18, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.black)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
    }

    private var transferringView: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("Överföring pågår")
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)

            Text("Koppla inte ur disken")
                .font(.system(size: 24))
                .foregroundColor(.white)

            if let sourceProjectFolderPath {
                Text("Källa:\n\(sourceProjectFolderPath)")
                    .font(.system(size: 18, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
            }

            if let destinationFolderPath {
                Text("Mål:\n\(destinationFolderPath)")
                    .font(.system(size: 18, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(.horizontal, 40)
            }

            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)

            Spacer()
        }
    }

    private var doneView: some View {
        ZStack {
            VStack(spacing: 28) {
                Spacer()

                Text("Överföring klar")
                    .font(.system(size: 34, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)

                if sourceDiskIsSafeToRemove {
                    Text("Du kan nu koppla ur disken")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(spacing: 14) {
                    if let completedSourceVolumeName {
                        VStack(spacing: 4) {
                            Text("Disk:")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            Text(completedSourceVolumeName)
                                .font(.system(size: 24, weight: .bold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                        }
                    }

                    if let completedSourceProjectName {
                        VStack(spacing: 4) {
                            Text("Material från:")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            Text(completedSourceProjectName)
                                .font(.system(size: 24, weight: .bold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                        }
                    }

                    if let completedSavedInProductionName {
                        VStack(spacing: 4) {
                            Text("Sparat i:")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            Text(completedSavedInProductionName)
                                .font(.system(size: 24, weight: .bold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                        }
                    }

                    if let completedFinalProjectFolderName,
                       completedFinalProjectFolderName != completedSourceProjectName {
                        VStack(spacing: 4) {
                            Text("Kopierad som:")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)

                            Text(completedFinalProjectFolderName)
                                .font(.system(size: 24, weight: .bold))
                                .multilineTextAlignment(.center)
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                        }
                    }
                }

                if needsManualEject {
                    VStack(spacing: 16) {
                        Text("För att kunna koppla ur disken\nmåste du trycka på knappen nedan.")
                            .font(.system(size: 34, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)

                        Button {
                            resetInactivityTimer()
                            manuallyEjectSourceDisk()
                        } label: {
                            Text("Mata ut disk")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.black)
                                .frame(minWidth: 260)
                                .padding(.vertical, 16)
                                .background(Color.white)
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !needsManualEject {
                    Spacer()

                    Text("Klicka på styrplattan för att fortsätta")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.bottom, 24)
                }

                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !needsManualEject else { return }
            resetInactivityTimer()
            resetToIdle(ignoreCurrentDisk: true)
        }
    }

    // MARK: - SELECT PRODUCTION

    private var selectProductionView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 30)

            Text("Välj produktion")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.black)

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(productionFolders) { folder in
                        Button {
                            resetInactivityTimer()
                            cancelSelectionTimeout()
                            prepareTransfer(toDisplayName: folder.displayName)
                            startTransfer()
                        } label: {
                            Text(folder.displayName)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(Color.black.opacity(0.85))
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        resetInactivityTimer()
                        newFolderName = ""
                        pendingFolderName = ""
                        createFolderStep = .enterName
                        showCreateFolderSheet = true
                    } label: {
                        Text("Mapp saknas skapa ny")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }

            Spacer()

            VStack(spacing: 10) {
                Text("VÄLJ PRODUKTION")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)

                Text("⬇️ MED STYRPLATTAN ⬇️")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.black)

                Text("Om inget val görs sparas materialet i \"OSORTERAT\"")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.bottom, 30)
        }
        .onAppear {
            startSelectionTimeout()
        }
        .onDisappear {
            cancelSelectionTimeout()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    resetInactivityTimer()
                }
        )
    }

    // MARK: - CREATE FOLDER FLOW

    private var createFolderSheet: some View {
        VStack {
            if createFolderStep == .enterName {
                enterNameContent
            } else {
                confirmNameContent
            }
        }
        .frame(width: 760, height: 560)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    resetInactivityTimer()
                }
        )
        .alert("Mappen finns redan", isPresented: $showFolderExistsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Det finns redan en produktionsmapp med det namnet, även om den är dold.")
        }
        .alert("Kunde inte skapa mapp", isPresented: $showCreateFolderErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(createFolderErrorMessage)
        }
    }

    private var enterNameContent: some View {
        VStack(spacing: 16) {
            Text("Ny produktionsmapp")
                .font(.title)

            enteredNameBox

            VStack {
                keyboardRow(["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "Å"])
                keyboardRow(["A", "S", "D", "F", "G", "H", "J", "K", "L", "Ö", "Ä"])
                keyboardRow(["Z", "X", "C", "V", "B", "N", "M"])
            }

            HStack {
                Button("Rensa") {
                    resetInactivityTimer()
                    newFolderName = ""
                }
                Button("Mellanslag") {
                    resetInactivityTimer()
                    appendCharacter(" ")
                }
                Button("⌫") {
                    resetInactivityTimer()
                    deleteLastCharacter()
                }
            }

            Spacer()

            HStack {
                Button("Avbryt") {
                    resetInactivityTimer()
                    showCreateFolderSheet = false
                }

                Button("Fortsätt") {
                    resetInactivityTimer()
                    let trimmed = trimmedNewFolderName

                    if folderAlreadyExists(trimmed) {
                        showFolderExistsAlert = true
                    } else {
                        pendingFolderName = trimmed
                        createFolderStep = .confirmName
                    }
                }
                .disabled(!canContinueFromKeyboard)
            }
        }
        .padding()
    }

    private var confirmNameContent: some View {
        VStack(spacing: 20) {
            Text("Bekräfta ny mapp")

            Text(pendingFolderName)
                .font(.title)

            Spacer()

            HStack {
                Button("Avbryt") {
                    resetInactivityTimer()
                    createFolderStep = .enterName
                }

                Button("Skapa") {
                    resetInactivityTimer()
                    do {
                        cancelSelectionTimeout()
                        try createProductionFolder(from: pendingFolderName)
                        loadProductionFolders()
                        prepareTransfer(toDisplayName: pendingFolderName)
                        startTransfer()
                        showCreateFolderSheet = false
                        createFolderStep = .enterName
                        newFolderName = ""
                        pendingFolderName = ""
                    } catch {
                        print("[INGEST] Failed to create folder '\(pendingFolderName)' in root '\(filmRootPath)': \(error.localizedDescription)")
                        createFolderErrorMessage = error.localizedDescription
                        showCreateFolderErrorAlert = true
                    }
                }
            }
        }
        .padding()
    }

    private var enteredNameBox: some View {
        Text(newFolderName.isEmpty ? "Skriv namn" : newFolderName)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.white)
    }

    // MARK: - KEYBOARD

    private func keyboardRow(_ keys: [String]) -> some View {
        HStack {
            ForEach(keys, id: \.self) { key in
                Button(key) {
                    resetInactivityTimer()
                    appendCharacter(key)
                }
            }
        }
    }

    private func appendCharacter(_ char: String) {
        newFolderName += char
    }

    private func deleteLastCharacter() {
        guard !newFolderName.isEmpty else { return }
        newFolderName.removeLast()
    }

    // MARK: - FLOW

    private func prepareTransfer(toDisplayName displayName: String) {
        destinationFolderName = displayName

        let serverFolderName = buildServerFolderName(from: displayName)
        destinationFolderPath = "\(filmRootPath)/\(serverFolderName)"
    }

    private func prepareFallbackTransferToOsorterat() {
        destinationFolderName = "OSORTERAT"
        destinationFolderPath = "\(filmRootPath)/FILM_OSORTERAT"
    }

    private func refreshSourceProjectFolderBeforeTransfer() {
        sourceProjectFolderPath = latestProjectFolderPath
    }

    private func startTransfer() {
        refreshSourceProjectFolderBeforeTransfer()

        guard sourceProjectFolderPath != nil else {
            transferErrorMessage = "Kunde inte hitta aktuell projektmapp på disken."
            showTransferErrorAlert = true
            return
        }

        guard destinationFolderPath != nil else {
            transferErrorMessage = "Källa eller mål saknas."
            showTransferErrorAlert = true
            return
        }

        needsManualEject = false
        sourceDiskIsSafeToRemove = false

        cancelSelectionTimeout()
        cancelInactivityTimer()

        state = .transferring

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try copyProjectFolderToDestination()
                let ejectSucceeded = try attemptAutomaticEject()

                DispatchQueue.main.async {
                    completedSourceVolumeName = extractVolumeName(from: detectedSourceDiskPath)
                    completedSourceProjectName = result.sourceProjectName
                    completedSavedInProductionName = destinationFolderName
                    completedFinalProjectFolderName = result.finalProjectFolderName
                    completedFinalProjectFolderPath = result.finalProjectFolderPath

                    sourceDiskIsSafeToRemove = ejectSucceeded
                    needsManualEject = !ejectSucceeded

                    state = .done
                    startInactivityTimer()
                }
            } catch {
                DispatchQueue.main.async {
                    transferErrorMessage = "Tekniskt fel under test:\n\(error.localizedDescription)"
                    showTransferErrorAlert = true
                    state = .selectProduction
                    startInactivityTimer()
                }
            }
        }
    }

    private func startSelectionTimeout() {
        cancelSelectionTimeout()

        selectionTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            DispatchQueue.main.async {
                guard self.state == .selectProduction else { return }

                self.showCreateFolderSheet = false
                self.createFolderStep = .enterName
                self.newFolderName = ""
                self.pendingFolderName = ""

                self.prepareFallbackTransferToOsorterat()
                self.startTransfer()
            }
        }
    }

    private func cancelSelectionTimeout() {
        selectionTimeoutTimer?.invalidate()
        selectionTimeoutTimer = nil
    }

    // MARK: - INACTIVITY

    private func startInactivityTimer() {
        cancelInactivityTimer()

        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityTimeoutSeconds, repeats: false) { _ in
            DispatchQueue.main.async {
                handleInactivityTimeout()
            }
        }
    }

    private func resetInactivityTimer() {
        startInactivityTimer()

        // While selecting/creating production folder, user activity should
        // also postpone the 60-second auto-fallback to OSORTERAT.
        if state == .selectProduction {
            startSelectionTimeout()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTimer?.invalidate()
        inactivityTimer = nil
    }

    private func handleInactivityTimeout() {
        guard state != .transferring else {
            startInactivityTimer()
            return
        }

        resetToIdle(ignoreCurrentDisk: true)
    }

    // MARK: - DISK MONITOR

    private func startDiskMonitoring() {
        cancelDiskMonitoring()

        diskMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                if isDebugStateLockEnabled {
                    return
                }

                if let ignoredDiskPathWhileIdle,
                   !FileManager.default.fileExists(atPath: ignoredDiskPathWhileIdle) {
                    self.ignoredDiskPathWhileIdle = nil
                }

                guard state == .idle || state == .diskDetected else { return }

                if state == .idle {
                    if let sourceDiskPath = findSourceDiskPath() {
                        detectedSourceDiskPath = sourceDiskPath
                        detectedSourceVolumeName = extractVolumeName(from: sourceDiskPath)
                        latestProjectFolderPath = nil
                        state = .diskDetected
                        requestSourceInspection(force: true)
                        resetInactivityTimer()
                    }
                }

                if state == .diskDetected {
                    if let currentDisk = detectedSourceDiskPath,
                       !FileManager.default.fileExists(atPath: currentDisk) {
                        cancelSourceInspection()
                        detectedSourceDiskPath = nil
                        detectedSourceVolumeName = nil
                        latestProjectFolderPath = nil
                        state = .idle
                        return
                    }

                    requestSourceInspection()
                }
            }
        }
    }

    private var debugPanel: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: 8) {
            Text("DEBUG\nROOT: \(volumesRootPath)\nFILM: \(filmRootPath)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            HStack(spacing: 6) {
                debugButton("Idle") { activateDebugState(.idle) }
                debugButton("Disk") { activateDebugState(.diskDetected) }
                debugButton("Välj") { activateDebugState(.selectProduction) }
            }

            HStack(spacing: 6) {
                debugButton("Överför") { activateDebugState(.transferring) }
                debugButton("Klar") { activateDebugState(.done, manualEject: false) }
                debugButton("Gör disk klar") { activateDebugState(.done, manualEject: true) }
            }

            HStack(spacing: 6) {
                debugButton("Live-läge") {
                    isDebugStateLockEnabled = false
                    resetToIdle(ignoreCurrentDisk: false)
                    startDiskMonitoring()
                }
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .padding(12)
#else
        EmptyView()
#endif
    }

    private func debugButton(_ title: String, action: @escaping () -> Void) -> some View {
#if DEBUG
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
#else
        EmptyView()
#endif
    }

    private func activateDebugState(_ targetState: AppState, manualEject: Bool = false) {
#if DEBUG
        isDebugStateLockEnabled = true
        cancelSelectionTimeout()
        cancelInactivityTimer()

        detectedSourceDiskPath = "\(volumesRootPath)/DEBUG_DISK"
        detectedSourceVolumeName = "DEBUG_DISK"
        latestProjectFolderPath = "\(detectedSourceDiskPath ?? "")/PROJEKT_DEBUG"
        sourceProjectFolderPath = latestProjectFolderPath
        destinationFolderName = "DEBUG_DESTINATION"
        destinationFolderPath = "\(filmRootPath)/FILM_DEBUG_DESTINATION"

        completedSourceVolumeName = "DEBUG_DISK"
        completedSourceProjectName = "PROJEKT_DEBUG"
        completedSavedInProductionName = "DEBUG_DESTINATION"
        completedFinalProjectFolderName = "PROJEKT_DEBUG"
        completedFinalProjectFolderPath = "\(filmRootPath)/FILM_DEBUG_DESTINATION/PROJEKT_DEBUG"

        needsManualEject = manualEject
        sourceDiskIsSafeToRemove = !manualEject

        state = targetState
#endif
    }

    private func cancelDiskMonitoring() {
        diskMonitoringTimer?.invalidate()
        diskMonitoringTimer = nil
    }

    private func resetToIdle(ignoreCurrentDisk: Bool) {
        cancelSourceInspection()

        if ignoreCurrentDisk && shouldIgnoreCurrentDiskInIdle {
            ignoredDiskPathWhileIdle = detectedSourceDiskPath
        } else {
            ignoredDiskPathWhileIdle = nil
        }

        detectedSourceDiskPath = nil
        detectedSourceVolumeName = nil
        latestProjectFolderPath = nil

        sourceProjectFolderPath = nil
        destinationFolderName = nil
        destinationFolderPath = nil

        completedSourceVolumeName = nil
        completedSourceProjectName = nil
        completedSavedInProductionName = nil
        completedFinalProjectFolderName = nil
        completedFinalProjectFolderPath = nil

        needsManualEject = false
        sourceDiskIsSafeToRemove = false

        showCreateFolderSheet = false
        createFolderStep = .enterName
        newFolderName = ""
        pendingFolderName = ""

        cancelSelectionTimeout()
        state = .idle
        startInactivityTimer()
    }

    // MARK: - EJECT

    private func attemptAutomaticEject() throws -> Bool {
        guard let detectedSourceDiskPath else {
            return false
        }

        return runDiskutilUnmountOrEject(for: detectedSourceDiskPath)
    }

    private func manuallyEjectSourceDisk() {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = tryManualDiskClear()

            DispatchQueue.main.async {
                if success {
                    needsManualEject = false
                    sourceDiskIsSafeToRemove = true
                } else {
                    transferErrorMessage = "Tekniskt fel under test:\nDet gick inte att göra disken klar."
                    showTransferErrorAlert = true
                }
            }
        }
    }

    private func tryManualDiskClear() -> Bool {
        guard let diskPath = detectedSourceDiskPath else {
            return true
        }

        if !FileManager.default.fileExists(atPath: diskPath) {
            return true
        }

        if runDiskutilCommand(arguments: ["unmountDisk", diskPath]) {
            return true
        }

        if !FileManager.default.fileExists(atPath: diskPath) {
            return true
        }

        if runDiskutilCommand(arguments: ["eject", diskPath]) {
            return true
        }

        return !FileManager.default.fileExists(atPath: diskPath)
    }

    private func runDiskutilUnmountOrEject(for diskPath: String) -> Bool {
        if runDiskutilCommand(arguments: ["unmountDisk", diskPath]) {
            return true
        }

        if !FileManager.default.fileExists(atPath: diskPath) {
            return true
        }

        if runDiskutilCommand(arguments: ["eject", diskPath]) {
            return true
        }

        return !FileManager.default.fileExists(atPath: diskPath)
    }

    private func runDiskutilCommand(arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - COPY

    private func copyProjectFolderToDestination() throws -> (sourceProjectName: String, finalProjectFolderName: String, finalProjectFolderPath: String) {
        guard let sourceProjectFolderPath,
              let destinationFolderPath else {
            throw NSError(
                domain: "FilmOverforing",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Källa eller mål saknas."]
            )
        }

        let fileManager = FileManager.default

        let sourceFolderURL = URL(fileURLWithPath: sourceProjectFolderPath)
        let sourceFolderName = sourceFolderURL.lastPathComponent

        guard fileManager.fileExists(atPath: sourceFolderURL.path) else {
            throw NSError(
                domain: "FilmOverforing",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Källmappen finns inte längre: \(sourceFolderURL.path)"]
            )
        }

        let destinationBaseURL = URL(fileURLWithPath: destinationFolderPath)

        try fileManager.createDirectory(
            at: destinationBaseURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let initialFinalDestinationURL = uniqueFinalDestinationURL(
            baseURL: destinationBaseURL,
            folderName: sourceFolderName
        )

        let tempDestinationURL = uniqueTempDestinationURL(finalURL: initialFinalDestinationURL)

        try fileManager.copyItem(at: sourceFolderURL, to: tempDestinationURL)

        let finalDestinationURL = uniqueFinalDestinationURL(
            baseURL: destinationBaseURL,
            folderName: sourceFolderName
        )

        try fileManager.moveItem(at: tempDestinationURL, to: finalDestinationURL)

        return (
            sourceProjectName: sourceFolderName,
            finalProjectFolderName: finalDestinationURL.lastPathComponent,
            finalProjectFolderPath: finalDestinationURL.path
        )
    }

    private func uniqueFinalDestinationURL(baseURL: URL, folderName: String) -> URL {
        let fileManager = FileManager.default

        var candidateURL = baseURL.appendingPathComponent(folderName)
        var counter = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = baseURL.appendingPathComponent("\(folderName)_\(counter)")
            counter += 1
        }

        return candidateURL
    }

    private func uniqueTempDestinationURL(finalURL: URL) -> URL {
        let fileManager = FileManager.default

        let parentURL = finalURL.deletingLastPathComponent()
        let finalName = finalURL.lastPathComponent

        var candidateURL = parentURL.appendingPathComponent(finalName + "__INCOMPLETE")
        var counter = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = parentURL.appendingPathComponent(finalName + "__INCOMPLETE_\(counter)")
            counter += 1
        }

        return candidateURL
    }

    // MARK: - DISK + PROJECT DETECTION

    private func requestSourceInspection(force: Bool = false) {
        guard state == .diskDetected else { return }
        guard !isSourceInspectionInProgress else { return }

        if !force,
           let lastSourceInspectionAt,
           Date().timeIntervalSince(lastSourceInspectionAt) < sourceInspectionMinIntervalSeconds {
            return
        }

        isSourceInspectionInProgress = true
        sourceInspectionToken += 1
        let token = sourceInspectionToken

        let currentDetectedDiskPath = detectedSourceDiskPath
        let currentIgnoredPath = ignoredDiskPathWhileIdle
        let currentSearchRoots = sourceSearchRoots
        let currentFilmRootPath = filmRootPath

        DispatchQueue.global(qos: .userInitiated).async {
            let resolvedSourceDiskPath = currentDetectedDiskPath ?? Self.findSourceDiskPath(
                searchRoots: currentSearchRoots,
                filmRootPath: currentFilmRootPath,
                ignoredDiskPathWhileIdle: currentIgnoredPath
            )

            let resolvedVolumeName = self.extractVolumeName(from: resolvedSourceDiskPath)
            let resolvedLatestProjectFolderPath = resolvedSourceDiskPath.flatMap { self.findLatestProjectFolder(in: $0) }

            DispatchQueue.main.async {
                guard token == self.sourceInspectionToken else { return }

                self.isSourceInspectionInProgress = false
                self.lastSourceInspectionAt = Date()

                guard self.state == .diskDetected else { return }

                self.detectedSourceDiskPath = resolvedSourceDiskPath
                self.detectedSourceVolumeName = resolvedVolumeName
                self.latestProjectFolderPath = resolvedLatestProjectFolderPath

                if resolvedLatestProjectFolderPath != nil {
                    self.loadProductionFolders()
                    self.state = .selectProduction
                    self.resetInactivityTimer()
                }
            }
        }
    }

    private func cancelSourceInspection() {
        sourceInspectionToken += 1
        isSourceInspectionInProgress = false
        lastSourceInspectionAt = nil
    }

    private func findSourceDiskPath() -> String? {
        Self.findSourceDiskPath(
            searchRoots: sourceSearchRoots,
            filmRootPath: filmRootPath,
            ignoredDiskPathWhileIdle: ignoredDiskPathWhileIdle
        )
    }

    private static func findSourceDiskPath(
        searchRoots: [String],
        filmRootPath: String,
        ignoredDiskPathWhileIdle: String?
    ) -> String? {
        let fileManager = FileManager.default
        var candidatePaths: [String] = []

        for root in searchRoots {
            let rootURL = URL(fileURLWithPath: root)
            let systemVolumePath = rootURL.appendingPathComponent("Macintosh HD").path

            guard let volumeNames = try? fileManager.contentsOfDirectory(atPath: root) else {
                print("[INGEST] Cannot read source root: \(root)")
                continue
            }

            let rootCandidates = volumeNames
                .map { rootURL.appendingPathComponent($0).path }
                .filter { path in
                    path != filmRootPath &&
                    path != Self.defaultFilmRootPath &&
                    path != systemVolumePath &&
                    path != ignoredDiskPathWhileIdle
                }

            candidatePaths.append(contentsOf: rootCandidates)
        }

        var candidatesWithDate: [(path: String, date: Date)] = []

        for path in candidatePaths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            if let attributes = try? fileManager.attributesOfItem(atPath: path),
               let creationDate = attributes[.creationDate] as? Date {
                candidatesWithDate.append((path: path, date: creationDate))
            }
        }

        let sorted = candidatesWithDate.sorted { $0.date > $1.date }
        print("[INGEST] Source search roots: \(searchRoots)")
        print("[INGEST] Source candidates: \(candidatePaths)")
        print("[INGEST] Selected source disk: \(sorted.first?.path ?? "none")")
        return sorted.first?.path
    }

    private func findLatestProjectFolder(in diskPath: String) -> String? {
        let fileManager = FileManager.default

        guard let itemNames = try? fileManager.contentsOfDirectory(atPath: diskPath) else {
            return nil
        }

        var folderInfos: [(path: String, latestContentDate: Date)] = []

        for itemName in itemNames {
            if shouldIgnoreSourceFolder(named: itemName) {
                continue
            }

            let fullPath = "\(diskPath)/\(itemName)"

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let latestContentDate = latestModificationDateRecursively(in: fullPath)

            folderInfos.append((path: fullPath, latestContentDate: latestContentDate))
        }

        let sortedFolders = folderInfos.sorted { lhs, rhs in
            lhs.latestContentDate > rhs.latestContentDate
        }

        return sortedFolders.first?.path
    }

    private func latestModificationDateRecursively(in folderPath: String) -> Date {
        let fileManager = FileManager.default
        let folderURL = URL(fileURLWithPath: folderPath)

        var latestDate = (
            (try? fileManager.attributesOfItem(atPath: folderPath)[.modificationDate] as? Date) ?? .distantPast
        )

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return latestDate
        }

        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modificationDate = values.contentModificationDate else {
                continue
            }

            if modificationDate > latestDate {
                latestDate = modificationDate
            }
        }

        return latestDate
    }

    private func shouldIgnoreSourceFolder(named folderName: String) -> Bool {
        if folderName.hasPrefix(".") {
            return true
        }

        if folderName.contains("#") {
            return true
        }

        return false
    }

    private func extractVolumeName(from path: String?) -> String? {
        guard let path else { return nil }

        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }

        if components.count >= 2 && components[0] == "Volumes" {
            return components[1]
        }

        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - DATA

    private func loadProductionFolders() {
        let fileManager = FileManager.default

        do {
            let items = try fileManager.contentsOfDirectory(atPath: filmRootPath)

            productionFolders = items.compactMap { name in
                var isDir: ObjCBool = false
                let path = "\(filmRootPath)/\(name)"

                guard fileManager.fileExists(atPath: path, isDirectory: &isDir),
                      isDir.boolValue,
                      name.hasPrefix("FILM_"),
                      !name.contains("#"),
                      name != "FILM_OSORTERAT" else { return nil }

                return ProductionFolder(
                    fullName: name,
                    displayName: String(name.dropFirst(5))
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        } catch {
            productionFolders = []
        }
    }

    private func folderAlreadyExists(_ name: String) -> Bool {
        let fileManager = FileManager.default

        guard let items = try? fileManager.contentsOfDirectory(atPath: filmRootPath) else {
            return false
        }

        let normalizedInput = normalize(name)

        return items.contains {
            normalize($0) == normalizedInput
        }
    }

    private func createProductionFolder(from userInput: String) throws {
        let fileManager = FileManager.default
        let serverFolderName = buildServerFolderName(from: userInput)
        let fullPath = "\(filmRootPath)/\(serverFolderName)"

        print("[INGEST] Create request userInput='\(userInput)' serverFolder='\(serverFolderName)'")
        print("[INGEST] Ensuring film root exists at: \(filmRootPath)")
        print("[INGEST] Creating directory at: \(fullPath)")

        try fileManager.createDirectory(
            atPath: filmRootPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        try fileManager.createDirectory(
            atPath: fullPath,
            withIntermediateDirectories: false,
            attributes: nil
        )
    }

    private func buildServerFolderName(from userInput: String) -> String {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercased = trimmed.uppercased()
        let collapsedSpaces = uppercased.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        return "FILM_\(collapsedSpaces)"
    }

    private func normalize(_ name: String) -> String {
        name.uppercased()
            .replacingOccurrences(of: "FILM_", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - COLORS

    private var backgroundColor: Color {
        switch state {
        case .idle:
            return Color(red: 0.0, green: 0.6, blue: 0.2)
        case .diskDetected:
            return Color(red: 0.85, green: 0.65, blue: 0.0)
        case .selectProduction:
            return Color(red: 0.95, green: 0.95, blue: 0.92)
        case .transferring:
            return Color(red: 0.8, green: 0.0, blue: 0.0)
        case .done:
            return Color(red: 0.0, green: 0.6, blue: 0.2)
        }
    }
}

#Preview {
    ContentView()
}
