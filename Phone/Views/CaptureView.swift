import BindersKit
import SwiftUI

/// All-day capture: on and off, mute, what it heard today, and how it's doing. Audio stays on this iPhone; the Mac only
/// gets text. The screen stays short however long the history: today's captures that were kept or still need something,
/// one row for those not kept, and a row to the earlier days. Its settings are a page of their own, from the toolbar.
struct CaptureView: View {
    @Environment(MacConnection.self) private var connection
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared
    @State private var moments = MomentCenter.shared
    @State private var explainingMoments = false
    /// Auto chosen in the Mode menu: its sheet, before the mode changes.
    @State private var choosingAuto = false
    /// A moment's page, opened from its row.
    @State private var openedMoment: UUID?
    @State private var processor = ConversationProcessor.shared
    @State private var models = CaptureModels.shared
    @State private var voiceTaught = VoicePrint.isTaught
    @State private var sharing: SharedFile?
    @State private var sharingIDs: [UUID] = []
    @State private var showingSettings = false
    /// Shown once, before All-day capture first listens.
    @AppStorage("captureNoticeAcknowledged") private var noticeAcknowledged = false
    @State private var askingFirst = false
    /// Its Live Activity, the sign on the Lock Screen that capture is on.
    @State private var liveActivity = CaptureActivity.status
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { capture.isOn }, set: { on in
                    if !on {
                        capture.turnOff()
                    } else if noticeAcknowledged {
                        Task { await capture.turnOn() }
                    } else {
                        askingFirst = true
                    }
                })) {
                    Label("All-day capture", systemImage: "waveform.and.mic")
                }
                .accessibilityIdentifier("captureToggle")
                if capture.isOn {
                    HStack {
                        // Its glyph: red only while the microphone is live, moving only while speech is heard. The words stay ink.
                        ListeningGlyph(look: CaptureStatusLook(capture.status), listening: capture.isListening)
                        Text(capture.status.title).foregroundStyle(Palette.ink).accessibilityIdentifier("captureStatus")
                        if case .paused(let reason) = capture.status {
                            Text(reason).foregroundStyle(Palette.muted).lineLimit(2)
                        } else if capture.inConversation, capture.isListening, !capture.hearsVoices {
                            // Loudness can hold a conversation open on noise: worth saying in one most of all.
                            Text("in a conversation, by loudness until the voice detector is ready").font(.footnote).foregroundStyle(Palette.muted).lineLimit(2)
                        } else if capture.inConversation {
                            Text("in a conversation").foregroundStyle(Palette.muted)
                        } else if capture.isListening, !capture.hearsVoices {
                            Text("by loudness until the voice detector is ready").font(.footnote).foregroundStyle(Palette.muted).lineLimit(2)
                        }
                        Spacer()
                        if case .paused = capture.status {
                            Button("Resume") { Task { await capture.resume() } }.buttonStyle(.bordered)
                        }
                    }
                    MuteButton(muted: capture.isMuted) {
                        if capture.isMuted { capture.unmute() } else { capture.mute() }
                    }
                    .accessibilityIdentifier("captureMute")
                    if capture.inConversation, capture.status == .listening {
                        // Over now: written down without waiting for three minutes of quiet.
                        Button { capture.wrapUp() } label: {
                            Label("Wrap Up Now", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(OutlinedButtonStyle())
                        .accessibilityIdentifier("captureWrapUp")
                    }
                    if let note = capture.wrapUpNote {
                        Text(note).font(.footnote).foregroundStyle(Palette.muted).accessibilityIdentifier("captureWrapUpNote")
                    }
                }
                if let error = capture.error {
                    ProblemLabel(error).font(.footnote)
                }
                liveActivityNote
                // Until the speech model is here, getting it is on this screen too; its language is in Settings.
                if !models.isTranscriberDownloaded { SpeechModelDownload() }
                if waitingForNewerMac {
                    // A wait with its reason and what ends it: ink, with its glyph.
                    Label("Update \(MacConnection.onHub ? "your hub" : "Binders on \(MacConnection.brainWords)") to receive captures. They wait here until then.", systemImage: "arrow.down.circle")
                        .font(.footnote).foregroundStyle(Palette.ink)
                }
            } footer: {
                if let name = connection.brainName, connection.hasBrain {
                    Text("Binders listens for conversations, writes them down on this iPhone and sends only the text to \(name). Audio never leaves this iPhone and is deleted once it's written down. Mute turns the microphone off completely.")
                } else {
                    Text("Binders listens for conversations and writes them down on this iPhone; once you pair a Mac or sign in to a hub, only the text goes to it. Audio never leaves this iPhone and is deleted once it's written down. Mute turns the microphone off completely.")
                }
            }
            .surfaceRows()

            Section {
                // Today's counts and times, rounded and heavy with digits that line up.
                TodayCount("Listening", hours(capture.onToday()))
                TodayCount("Speech heard", minutes(capture.speechSeconds))
                TodayCount("Captures", capturesLine)
                ForEach(capture.gaps) { gap in
                    Label("Paused \(time(gap.from))\(gap.to.map { "–" + time($0) } ?? "") · \(gap.reason)", systemImage: "pause.circle")
                        .font(.footnote.monospacedDigit()).foregroundStyle(Palette.muted)
                }
            } header: {
                Text("Today")
            }
            .surfaceRows()

            Section {
                Toggle("Listen for things you say to yourself", isOn: Binding(get: { moments.isOn }, set: { on in
                    // The first time, what it does with what you say, before it does it.
                    if on, !UserDefaults.standard.bool(forKey: "momentsExplained") { explainingMoments = true } else { moments.isOn = on }
                }))
                    .disabled(connection.hasBrain && !connection.takesMoments)
                    .accessibilityIdentifier("momentsToggle")
                if moments.isOn {
                    MomentModeRow(choosingAuto: $choosingAuto)
                        .disabled(connection.hasBrain && !connection.takesMoments)
                }
                if let timings = moments.timingSummary { MomentTimingsRow(summary: timings) }
                // Graduation is Suggest's own: its kinds show only there.
                if moments.isOn, voiceTaught, moments.mode == .suggest { MomentKindsRows() }
                // What you say to yourself that wouldn't be written down in the background now, and what wasn't today.
                if moments.isOn, capture.isOn, let why = processor.whyMomentsWait() {
                    Label(AutoPhoneText.notWrittenDownNow(why), systemImage: "moon.zzz").font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("momentsNotWrittenDownNow")
                }
                if moments.isOn, let unwritten = AutoPhoneText.notWrittenDown(moments.notWrittenDownToday) {
                    Label(unwritten, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Palette.ink)
                }
                // The bench that sets the voice threshold, from phrases, other voices and TV.
                NavigationLink { CalibrationView() } label: { Label("Calibrate", systemImage: "slider.horizontal.3") }
                    .accessibilityIdentifier("momentsCalibrate")
                ForEach(moments.listed()) { moment in MomentRow(moment: moment) { openedMoment = moment.id } }
            } header: {
                Text("Said to yourself")
                    .alert("Listen for things you say to yourself?", isPresented: $explainingMoments) {
                        Button("Turn On") {
                            UserDefaults.standard.set(true, forKey: "momentsExplained")
                            moments.isOn = true
                        }
                        Button("Not Now", role: .cancel) {}
                    } message: {
                        Text(AutoPhoneText.explanation)
                    }
            } footer: {
                Text(momentsFooter)
            }
            .surfaceRows()

            capturesToday
        }
        .listGround()
        .clearsTalkControl()
        .navigationTitle("All-day capture")
        .navigationDestination(item: $openedMoment) { MomentDetailView(id: $0) }
        .navigationDestination(isPresented: $showingSettings) { CaptureSettingsView() }
        // "Give to an Agent" tapped in a moment's notification, before you'd said yes to that agent: asked here, for a
        // moment from any day.
        .confirmationDialog(moments.moments.first { $0.id == moments.consenting }.map { "Give cards to \($0.agent ?? "this agent")?" } ?? "",
                            isPresented: Binding(get: { moments.consenting != nil && moments.moments.contains { $0.id == moments.consenting } },
                                                 set: { if !$0 { moments.consenting = nil } }),
                            titleVisibility: .visible) {
            if let id = moments.consenting, let agent = moments.moments.first(where: { $0.id == id })?.agent {
                Button("Give to \(agent)") {
                    MomentCenter.agree(to: agent)
                    moments.consenting = nil
                    Task {
                        let result = await MomentCenter.shared.act(id, "assign")
                        if !result.ok { MomentCenter.couldNot(id, result.message) }
                    }
                }
            }
            Button("Cancel", role: .cancel) { moments.consenting = nil }
        } message: {
            Text(MomentRow.disclosure(moments.moments.first { $0.id == moments.consenting }?.agent, connection: connection))
        }
        .alert("Binders will write down conversations around you", isPresented: $askingFirst) {
            Button("Turn It On") {
                noticeAcknowledged = true
                Task { await capture.turnOn() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if !connection.hasBrain {
                Text("All-day capture listens with this iPhone's microphone and writes down what's said, on this iPhone; once you pair a Mac, the text goes to it. Many places require everyone's consent before a conversation is recorded. Let the people around you know, and mute it or turn it off when someone objects.")
            } else {
                Text("All-day capture listens with this iPhone's microphone and sends what's said, as text, to \(connection.brainPhrase). Many places require everyone's consent before a conversation is recorded. Let the people around you know, and mute it or turn it off when someone objects.")
            }
        }
        .toolbar {
            // The settings: the speech model, writing down while locked, notifications, the Lock Screen, your voice.
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Capture settings")
                    .accessibilityIdentifier("captureSettings")
            }
        }
        .macToolbar()
        .navigationDestination(for: CapturedConversationLink.self) { ConversationDetailView(id: $0.id) }
        // Auto chosen in the Mode menu, or "Auto can hand things over now" tapped: what it does, before it does it.
        .sheet(isPresented: Binding(get: { choosingAuto || moments.showingAutoSheet }, set: { if !$0 {
            choosingAuto = false
            moments.showingAutoSheet = false
        } })) { AutoSheet() }
        .sheet(item: $sharing) { file in
            ShareSheet(url: file.url) { activity, completed in
                if completed { ConversationSharing.shared(sharingIDs, via: activity, connection: connection) }
                sharing = nil
            }
        }
        .onAppear {
            processor.processWaiting()
            // Taught or forgotten in Settings, and back.
            voiceTaught = VoicePrint.isTaught
        }
        .task { await CaptureActivity.followSettings() }
        // Who the agents are now, so what's said before Give to is what your Mac has set up.
        .task { if connection.isConnected { await AgentConsents.refresh(connection) } }
    }

    /// Today's captures that were kept, or are still on their way or need you, newest first; the ones not kept in one quiet
    /// row; and the days before, a tap away.
    @ViewBuilder
    private var capturesToday: some View {
        let shown = today.filter { !$0.wasNotKept }
        let notKept = today.filter(\.wasNotKept)
        let days = store.earlier()
        if !today.isEmpty || !days.isEmpty {
            Section {
                if today.isEmpty {
                    Text("None yet today").foregroundStyle(Palette.muted)
                }
                ForEach(shown) { CaptureRow(conversation: $0) }
                if !notKept.isEmpty {
                    NavigationLink { CaptureListPage(scope: .notKeptToday) } label: { NotKeptSummaryRow(captures: notKept) }
                        .accessibilityIdentifier("captureNotKeptToday")
                }
                if !days.isEmpty {
                    NavigationLink { EarlierCapturesPage() } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "calendar").foregroundStyle(Palette.muted).captureGlyph()
                            // Side by side, or the count under the words at the largest sizes.
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Earlier captures").foregroundStyle(Palette.ink)
                                    Spacer(minLength: 8)
                                    earlierCount(days.count)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Earlier captures").foregroundStyle(Palette.ink)
                                    earlierCount(days.count).font(.caption)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("captureEarlier")
                }
            } header: {
                Text("Captures today")
            } footer: {
                if !waiting.isEmpty {
                    Button {
                        shareWaiting()
                    } label: {
                        Label(waiting.count == 1 ? "Send the waiting capture by AirDrop…" : "Send \(waiting.count) waiting captures by AirDrop…",
                              systemImage: "square.and.arrow.up")
                    }
                    .font(.footnote)
                    .padding(.top, 4)
                }
            }
            .surfaceRows()
        }
    }

    private func earlierCount(_ days: Int) -> some View {
        Text(days == 1 ? "1 day" : "\(days) days").monospacedDigit().foregroundStyle(Palette.muted)
    }

    /// The Lock Screen's sign that capture is on, when it can't show: Live Activities turned off for Binders, or iOS
    /// refusing one, and what to do.
    @ViewBuilder
    private var liveActivityNote: some View {
        if !liveActivity.enabled {
            // With capture on, the Lock Screen has no sign it's on: a problem. Off, just a note.
            let text = "Live Activities are off for Binders, so iOS's microphone indicator is the only sign that capture is on."
            Group {
                if capture.isOn { ProblemLabel(text) } else { Label(text, systemImage: "info.circle").foregroundStyle(Palette.muted) }
            }
            .font(.footnote)
            .accessibilityIdentifier("captureLiveActivitiesOff")
            Button("Turn On Live Activities in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote)
        } else if capture.isOn, let problem = liveActivity.problem {
            ProblemLabel(problem).font(.footnote)
                .accessibilityIdentifier("captureLiveActivityProblem")
            Button("Try Again") { CaptureActivity.update() }.font(.footnote)
        }
    }

    /// Written down, and not with the Mac yet.
    private var waiting: [CaptureEntry] {
        store.conversations.filter { $0.state == .queued && $0.hasTranscript }
    }

    /// Everything waiting, in one Binders file, for when the Mac isn't reachable over the network. Their transcripts are
    /// in their records, read now.
    private func shareWaiting() {
        let device = UIDevice.current.model
        let conversations = waiting
        sharingIDs = conversations.map(\.id)
        sharing = ConversationSharing.file(for: conversations.compactMap { store.conversation($0.id)?.payload(device: device) })
            .map(SharedFile.init)
    }

    private var today: [CaptureEntry] { store.today() }

    /// How things said to yourself are told apart, and whether this iPhone's model checks them too.
    private var momentsFooter: String {
        if connection.hasBrain && !connection.takesMoments {
            // A hub without a model can't act on what you say to yourself; a Mac from before moments can't either.
            return connection.brain == .hub ? "Needs a model on your hub: set one in its Settings, under Brain." : "Needs a newer Binders on your Mac."
        }
        let checks = OnDeviceModel.isAvailable
            ? "It goes by a cue like “I need to”, your voice and the quiet around it, and Apple Intelligence on this iPhone has to agree what it is."
            : "It goes by a cue like “I need to”, your voice and the quiet around it. Apple Intelligence isn't on this iPhone, so those three decide alone."
        // Lane Y2: with a Mac that reads what you think out loud, the footer says so.
        if connection.macFeatures.contains(ConversationPayload.soloFeature) { return AutoPhoneText.soloFooter(moments.mode, checks: checks) }
        return AutoPhoneText.footer(moments.mode, checks: checks)
    }

    private var waitingForNewerMac: Bool {
        connection.hasBrain && !connection.takesConversations && connection.outbox.contains { $0.tool == PendingSave.conversation }
    }

    /// "5 · 3 filed · 1 not kept": today's captures, and what became of them, on the Mac or, for one with nothing to write
    /// down, on this iPhone.
    private var capturesLine: String {
        let filed = today.filter { $0.outcomeState == CaptureOutcome.States.filed }.count
        let notKept = today.filter(\.wasNotKept).count
        return (["\(today.count)"] + (filed > 0 ? ["\(filed) filed"] : []) + (notKept > 0 ? ["\(notKept) not kept"] : [])).joined(separator: " · ")
    }

    private func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    private func minutes(_ seconds: TimeInterval) -> String { "\(Int((seconds / 60).rounded())) min" }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

struct CapturedConversationLink: Hashable {
    let id: UUID
}

extension CaptureEntry {
    /// Not kept, on this iPhone (too short, nothing to write down) or by the Mac.
    var wasNotKept: Bool { notKept != nil || outcomeState == CaptureOutcome.States.notKept }

    /// Why it wasn't kept, in a few words: "too short", "nothing to write down", or the Mac's reason.
    var notKeptReason: String {
        if let notKept { return notKept }
        let prefix = "Not kept: "
        if let outcome, outcome.hasPrefix(prefix), outcome.count > prefix.count { return String(outcome.dropFirst(prefix.count)) }
        return "not kept by \(MacConnection.brainWords)"
    }
}

extension View {
    /// Room at the end of a list for the tabs' Dictate control, so it never covers the last row.
    func clearsTalkControl() -> some View { modifier(ClearsTalkControl()) }
}

private struct ClearsTalkControl: ViewModifier {
    @Environment(\.talkControlShown) private var shown

    func body(content: Content) -> some View {
        content.contentMargins(.bottom, shown ? 24 : 0, for: .scrollContent)
    }
}

/// The capture settings, a tap from the capture screen: the speech model, writing down while locked, what comes after a
/// capture, the Lock Screen and your voice; in Debug builds, the developer's.
struct CaptureSettingsView: View {
    @Environment(MacConnection.self) private var connection
    @State private var processor = ConversationProcessor.shared
    @State private var teaching = false
    @State private var voiceTaught = VoicePrint.isTaught
    #if DEBUG
    @State private var trial = SpeechTrial.shared
    @State private var timingLaunch = false
    @State private var launchTiming: String?
    #endif

    var body: some View {
        List {
            SpeechModelSection()

            // Where iOS keeps the models from background apps, nothing is written down there either way.
            if CaptureModels.mayInferInBackground {
                Section {
                    Toggle("Write down while the iPhone is locked", isOn: Binding(get: { processor.writesDownWhileLocked },
                                                                                set: { processor.writesDownWhileLocked = $0 }))
                        .accessibilityIdentifier("captureWritesDownWhileLocked")
                } footer: {
                    Text("Uses more battery. Off: captures wait until you open Binders or plug in.")
                }
                .surfaceRows()
            }

            Section {
                Toggle("Notify me", isOn: Binding(get: { SuggestionCenter.shared.notifies }, set: { SuggestionCenter.shared.notifies = $0 }))
            } header: {
                Text("After a capture")
            } footer: {
                if !connection.hasBrain {
                    Text("Tells you when captures are waiting to be written down. Once you pair a Mac, it also offers what you said you'd do for the binder's board, and answers to questions your binders hold.")
                } else {
                    Text("Once \(MacConnection.brainWords) has written a capture up, it offers to put what you said you'd do, and the ideas in it, on the binder's board or give them to an agent, and answers a question you asked if your binders hold the answer. They wait on the capture either way; turn them on or off for good in \(MacConnection.onHub ? "your hub" : "Binders on \(MacConnection.brainWords)"), Settings → All-day capture. This iPhone also tells you when captures are waiting to be written down.")
                }
            }
            .surfaceRows()

            LockScreenWordsSection()

            Section {
                if voiceTaught {
                    Label("Binders knows your voice", systemImage: "checkmark.circle")
                    Button("Forget My Voice", role: .destructive) {
                        VoicePrint.forget()
                        voiceTaught = false
                    }
                } else {
                    Button { teaching = true } label: { Label("Teach Binders Your Voice", systemImage: "person.wave.2") }
                }
            } header: {
                Text("Your voice")
            } footer: {
                Text("Read a short passage for twenty seconds, and your lines in a conversation are marked as you. The voice print stays in this iPhone's keychain; the recording isn't kept." + notMeLine)
            }
            .surfaceRows()

            #if DEBUG
            Section {
                Toggle("Keep audio for 24 hours", isOn: Binding(get: { processor.keepsAudio }, set: { processor.keepsAudio = $0 }))
                Button("Process Sample File") { processor.processSample() }
                Button(trial.running ? "Trying SpeechTranscriber…" : "Try SpeechTranscriber on the last clips") { trial.tryLastClips() }
                    .disabled(trial.running)
                    .accessibilityIdentifier("speechTrialTry")
                Toggle("Also try it while locked", isOn: Binding(get: { trial.whileLocked }, set: { trial.whileLocked = $0 }))
                if let note = trial.note {
                    Text(note).font(.footnote).foregroundStyle(Palette.muted)
                }
                ForEach(trial.clips) { SpeechTrialRow(clip: $0) }
                Button(timingLaunch ? "Timing the launch…" : "Time the launch on 200 test captures") { timeLaunch() }
                    .disabled(timingLaunch)
                if let launchTiming {
                    Text(launchTiming).font(.footnote).foregroundStyle(Palette.muted)
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Debug builds only. Keeps each capture's audio on this iPhone for a day after it's written down, to check how well it was transcribed. The SpeechTranscriber trial writes down the first 15 seconds or less of speech in each of the last three captures with Apple's SpeechTranscriber and with Parakeet, with how long each took to get ready and in all. Also while locked, each capture is tried as it closes, Parakeet too where it may run in the background then. Clips and their text stay on this iPhone for a day. Time the launch reads 200 made-up captures, kept apart from yours and deleted after, every record whole as before and by the index as now, and logs the line.")
            }
            .surfaceRows()
            #endif
        }
        .listGround()
        .clearsTalkControl()
        .navigationTitle("Capture settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $teaching, onDismiss: { voiceTaught = VoicePrint.isTaught }) { VoiceTeachingSheet() }
    }

    #if DEBUG
    /// The launch timed on 200 made-up captures, off the main thread, before the index and with it; logged too.
    private func timeLaunch() {
        timingLaunch = true
        Task {
            let line = await Task.detached(priority: .userInitiated) { CaptureIndex.timeLaunch(records: 200)?.line }.value
                ?? "The test captures couldn't be written."
            CaptureStore.log(line)
            launchTiming = line
            timingLaunch = false
        }
    }
    #endif

    /// What Not Me said about the voice print.
    private var notMeLine: String {
        let count = voiceTaught ? VoicePrint.misses.count : 0
        guard count > 0 else { return "" }
        return count == 1 ? " One thing heard as you was marked Not Me; it's kept, as a number, to set how alike a voice must sound."
            : " \(count) things heard as you were marked Not Me; they're kept, as numbers, to set how alike a voice must sound."
    }
}

/// The speech model, in Settings: its language, and whether it's here, downloading or to download.
private struct SpeechModelSection: View {
    @State private var models = CaptureModels.shared

    var body: some View {
        Section {
            Picker("Language", selection: Binding(get: { models.language }, set: { models.language = $0 })) {
                ForEach(CaptureModels.Language.allCases) { Text($0.title).tag($0) }
            }
            if models.isTranscriberDownloaded {
                LabeledContent("Speech model", value: "On this iPhone")
            } else {
                SpeechModelDownload()
            }
        } header: {
            Text("Speech model")
        } footer: {
            Text("\(models.language.detail). It downloads once, over Wi-Fi only.\(models.isTranscriberDownloaded ? "" : " Until then, Apple's speech recognition on this iPhone writes things down where it can.")")
        }
        .surfaceRows()
    }
}

/// Getting the speech model: Download, or how far it's got, and what went wrong.
private struct SpeechModelDownload: View {
    @State private var processor = ConversationProcessor.shared
    @State private var models = CaptureModels.shared

    var body: some View {
        if models.downloading {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading the speech model…")
                ProgressView(value: models.progress)
            }
        } else {
            Button("Download the speech model (about 500 MB)") { processor.downloadModels() }
                .disabled(!models.onWiFi)
        }
        if let error = models.downloadError {
            ProblemLabel(error).font(.footnote)
        }
    }
}

/// The days before today, one row each with what became of its captures; each opens its list.
private struct EarlierCapturesPage: View {
    @State private var store = CaptureStore.shared

    var body: some View {
        let days = store.earlier()
        List {
            if days.isEmpty {
                Text("No earlier captures").foregroundStyle(Palette.muted).surfaceRows()
            } else {
                Section {
                    ForEach(days, id: \.day) { day in
                        NavigationLink { CaptureListPage(scope: .day(day.day)) } label: { DayRow(day: day.day, captures: day.conversations) }
                    }
                } footer: {
                    Text("Captures leave this iPhone after 30 days, once they're with \(MacConnection.brainWords) or weren't kept.")
                }
                .surfaceRows()
            }
        }
        .listGround()
        .clearsTalkControl()
        .navigationTitle("Earlier captures")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One earlier day: its date, and how many captures it had and what became of them.
private struct DayRow: View {
    let day: Date
    let captures: [CaptureEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day())).foregroundStyle(Palette.ink)
            Text(counts).font(.caption).monospacedDigit().foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var counts: String {
        let filed = captures.filter { $0.outcomeState == CaptureOutcome.States.filed }.count
        let notKept = captures.filter(\.wasNotKept).count
        return ([captures.count == 1 ? "1 capture" : "\(captures.count) captures"] + (filed > 0 ? ["\(filed) filed"] : [])
                + (notKept > 0 ? ["\(notKept) not kept"] : [])).joined(separator: " · ")
    }
}

/// A list of captures, with the same rows, pages and swipe actions as the capture screen's: one earlier day's, what was
/// kept first and what wasn't under it; or today's not kept, with what that means.
private struct CaptureListPage: View {
    enum Scope: Hashable {
        case notKeptToday
        case day(Date)
    }

    let scope: Scope
    @State private var store = CaptureStore.shared

    var body: some View {
        let captures = self.captures
        let kept = captures.filter { !$0.wasNotKept }
        let notKept = captures.filter(\.wasNotKept)
        List {
            if captures.isEmpty {
                Text("None").foregroundStyle(Palette.muted).surfaceRows()
            }
            if !kept.isEmpty {
                Section { ForEach(kept) { CaptureRow(conversation: $0) } }
                    .surfaceRows()
            }
            if !notKept.isEmpty {
                Section {
                    ForEach(notKept) { CaptureRow(conversation: $0) }
                } header: {
                    if case .day = scope { Text("Not kept") }
                } footer: {
                    if let explanation = Self.explanation(notKept) { Text(explanation) }
                }
                .surfaceRows()
            }
        }
        .listGround()
        .clearsTalkControl()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var captures: [CaptureEntry] {
        switch scope {
        case .notKeptToday: store.today().filter(\.wasNotKept)
        case .day(let day): store.earlier().first { $0.day == day }?.conversations ?? []
        }
    }

    private var title: String {
        switch scope {
        case .notKeptToday: "Not kept today"
        case .day(let day): day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    /// What the reasons mean, for the ones listed.
    private static func explanation(_ captures: [CaptureEntry]) -> String? {
        var lines: [String] = []
        if captures.contains(where: { $0.notKept == CapturedConversation.tooShort }) {
            lines.append("Too short: under 20 seconds of speech, so not written down.")
        }
        if captures.contains(where: { $0.notKept == CapturedConversation.nothingToWriteDown }) {
            lines.append("Nothing to write down: the speech model found no words, as with noise, music or another language.")
        }
        guard !lines.isEmpty else { return nil }
        return (lines + ["Their audio is deleted."]).joined(separator: " ")
    }
}

extension View {
    /// A capture row's glyph, in a column of its own that grows with the text size, so the rows' words line up.
    func captureGlyph() -> some View { modifier(CaptureGlyph()) }
}

private struct CaptureGlyph: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 22

    func body(content: Content) -> some View { content.frame(width: width) }
}

/// Today's captures not kept, in one quiet row: how many, and why.
private struct NotKeptSummaryRow: View {
    let captures: [CaptureEntry]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "minus.circle").foregroundStyle(Palette.faint).captureGlyph()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(captures.count) not kept").foregroundStyle(Palette.muted)
                Text(reasons).font(.caption).foregroundStyle(Palette.faint)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(captures.count) not kept today: \(reasons)")
    }

    /// "too short or nothing to write down", in the order they first come.
    private var reasons: String {
        var seen: [String] = []
        for capture in captures {
            let reason = capture.notKept ?? "not kept by \(MacConnection.brainWords)"
            if !seen.contains(reason) { seen.append(reason) }
        }
        guard let last = seen.popLast() else { return "" }
        return seen.isEmpty ? last : seen.joined(separator: ", ") + " or " + last
    }
}

/// A capture's row, wherever it's listed: its page a tap away, and, before it's with the Mac, Delete on a swipe. One not
/// kept is a single quiet line.
private struct CaptureRow: View {
    @Environment(MacConnection.self) private var connection
    @State private var processor = ConversationProcessor.shared
    let conversation: CaptureEntry

    var body: some View {
        NavigationLink(value: CapturedConversationLink(id: conversation.id)) {
            if conversation.wasNotKept {
                NotKeptRow(conversation: conversation)
            } else {
                ConversationCaptureRow(conversation: conversation, activity: processor.working == conversation.id ? processor.activity : nil,
                                       queuedLabel: queuedLabel, queuedNext: queuedNext)
            }
        }
        .accessibilityIdentifier("conversationRow")
        .swipeActions {
            if conversation.isUnsent, conversation.state != .recording {
                Button("Delete", role: .destructive) {
                    processor.forget(conversation.id)
                    connection.forgetConversation(conversation.id)
                    CaptureStore.shared.delete(conversation.id)
                }
            }
        }
    }

    /// Written down, and where it is now.
    private var queuedLabel: String {
        if !connection.hasBrain { return "On this iPhone" }
        if connection.brain == .hub { return connection.takesConversations ? "Waiting for your hub" : "Waiting for a newer hub" }
        return connection.takesConversations ? "Waiting for Mac" : "Waiting for a newer Mac app"
    }

    /// What comes next for one written down and waiting for the Mac, after that word: nil while it's on its way.
    private var queuedNext: String? {
        guard connection.hasBrain else { return "goes to \(MacConnection.brainWords) or hub once you have one" }
        guard connection.takesConversations else { return connection.brain == .hub ? "goes once your hub is updated" : "goes once Binders on your Mac is updated" }
        return connection.isConnected ? nil : "goes when \(connection.brainPhrase) is back"
    }
}

/// One capture not kept: when, how long and why, on one quiet line.
private struct NotKeptRow: View {
    let conversation: CaptureEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "minus.circle").foregroundStyle(Palette.faint).captureGlyph()
            Text([conversation.started.formatted(date: .omitted, time: .shortened), CaptureRowText.duration(conversation),
                  conversation.notKeptReason].joined(separator: " · "))
                .font(.subheadline).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not kept, \(conversation.notKeptReason). \(conversation.started.formatted(date: .omitted, time: .shortened)), \(CaptureRowText.duration(conversation))")
    }
}

enum CaptureRowText {
    /// "12 min", never under one.
    static func duration(_ capture: some CaptureFacts) -> String { "\(max(1, Int((capture.duration / 60).rounded()))) min" }
}

/// One of today's counts or times on the capture screen: the number rounded and heavy, with digits that line up and roll
/// as it changes. What wasn't kept is quieter.
private struct TodayCount: View {
    let label: String
    let value: String
    var quiet = false

    init(_ label: String, _ value: String, quiet: Bool = false) {
        self.label = label
        self.value = value
        self.quiet = quiet
    }

    var body: some View {
        LabeledContent(label) {
            Text(value).font(Typeface.count(.body)).foregroundStyle(quiet ? Palette.muted : Palette.ink).rollingCount(value)
        }
    }
}

/// How long the last moments took, from the last word to your Mac's decision: the middle (p50) and the slow end (p90), in
/// all and in parts. Numbers only, never what was said; in every build, as TestFlight builds are where it's measured.
private struct MomentTimingsRow: View {
    let summary: MomentTimingSummary

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text("p50 \(seconds(summary.inAll.p50)) · p90 \(seconds(summary.inAll.p90))").foregroundStyle(Palette.ink)
                Text("iPhone \(seconds(summary.toTheMac.p50)), \(seconds(summary.toTheMac.p90)) · Mac \(seconds(summary.onTheMac.p50)), \(seconds(summary.onTheMac.p90))")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            .monospacedDigit()
        } label: {
            Text("Timings")
            Text((summary.count == 1 ? "The last moment" : "The last \(summary.count) moments")
                 + (summary.waited > 0 ? ", not counting \(summary.waited) that waited for \(MacConnection.brainWords)" : ""))
        }
        .accessibilityIdentifier("momentTimings")
    }

    /// "4.2 s" under ten seconds, "12 s" from there.
    private func seconds(_ value: TimeInterval) -> String {
        value < 10 ? String(format: "%.1f s", value) : "\(Int(value.rounded())) s"
    }
}

/// One thing you said to yourself: when, the words, and what your Mac made of them or why it waits, with what can be done
/// now; one offered, with Add and Not Now. A tap opens its page. An answer you said wasn't right stays listed, from any
/// day, until you ask it again.
struct MomentRow: View {
    @Environment(MacConnection.self) private var connection
    let moment: CapturedMoment
    /// Opens its page.
    var open: () -> Void = {}
    @State private var message: String?
    @State private var consenting = false
    @State private var askingAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(moment.heard.formatted(date: Calendar.current.isDateInToday(moment.heard) ? .omitted : .abbreviated, time: .shortened))
                    .font(.footnote.monospacedDigit()).foregroundStyle(Palette.muted)
                Spacer()
                // An offer waits for your answer, and so does a card not woken or held back for Give to: amber, with its
                // word. The rest is said quietly.
                let amber = moment.outcomeState == "offered" || moment.isHeldForYou
                Text(state).font(.footnote.weight(amber ? .semibold : .regular))
                    .foregroundStyle(amber ? Palette.needsYou : Palette.muted)
            }
            // Your own words, as Binders quotes them.
            Text("“\(moment.text ?? "")”").font(Typeface.quote()).foregroundStyle(Palette.ink)
            // What your Mac made of it; or, while it waits, what comes next (the word above says why).
            if let next = MomentWait.next(state: moment.state, outcome: moment.outcomeState) {
                Text(next).font(.caption).foregroundStyle(Palette.muted)
            } else if moment.outcomeState != nil, !moment.shownOutcome.isEmpty {
                Text(moment.shownOutcome).font(.caption).foregroundStyle(Palette.muted).lineLimit(3)
            }
            if moment.waitsOnYou { MomentOfferButtons(moment: moment).padding(.top, 2) }
            // Handed to an agent without asking: Stop, right here, while the agent has it.
            if moment.isHandedOver, MomentCenter.shared.keptAction(for: moment.id) == nil {
                Button("Stop") { Task { message = await MomentCenter.shared.act(moment.id, "stop").message } }
                    .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(Palette.ink).controlSize(.small)
                    .accessibilityIdentifier("momentStop")
            }
            if let giving = connection.givingLater(moment: moment.id) {
                Label("Goes to \(giving.agent ?? "the agent") when \(MacConnection.brainWords) is back", systemImage: "clock").font(.caption).foregroundStyle(Palette.muted)
            } else if let message {
                Text(message).font(.caption).foregroundStyle(Palette.muted)
            }
            if moment.isToAskAgain {
                Button("Ask Again") { askAgain() }.font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open", action: open)
            // Not Me is the row's own (below), which keeps the voice print too.
            ForEach((moment.actions ?? []).filter { $0 != "not-me" }, id: \.self) { action in
                Button(Self.title(action, agent: moment.agent)) {
                    if action == "assign", let agent = moment.agent, !MomentCenter.agreed(to: agent) {
                        consenting = true
                    } else {
                        Task { message = await MomentCenter.shared.act(moment.id, action).message }
                    }
                }
            }
            if moment.isAnswer {
                if moment.notRight == nil { Button("Not Right") { MomentCenter.shared.markNotRight(moment.id) } }
                Button("Ask Again") { askAgain() }
            }
            // Heard on its own, but it wasn't you: taken back, and kept against your voice print.
            if moment.mayBeNotMe {
                Button("Not Me") { Task { message = await MomentCenter.shared.notMe(moment.id).message } }
            }
        }
        // Asked again once Ask closes: until then the row stays, as an earlier day's would go with it.
        .sheet(isPresented: $askingAgain, onDismiss: { MomentCenter.shared.askedAgain(moment.id) }) { AskView(question: moment.text ?? "") }
        // The first time something goes to an agent: where it goes, and what goes with it (App Store 5.1.2(i)).
        .confirmationDialog("Give cards to \(moment.agent ?? "this agent")?", isPresented: $consenting, titleVisibility: .visible) {
            if let agent = moment.agent {
                Button("Give to \(agent)") {
                    MomentCenter.agree(to: agent)
                    Task { message = await MomentCenter.shared.act(moment.id, "assign").message }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(MomentRow.disclosure(moment.agent, connection: connection))
        }
    }

    /// What goes to an agent with a card made from something you said, and where.
    static func disclosure(_ agent: String?, connection: MacConnection) -> String {
        AgentConsents.disclosure(named: agent, connection: connection)
    }

    private func askAgain() { askingAgain = true }

    private var state: String {
        if moment.notMe != nil { return "Not you" }
        if moment.notRight != nil { return "Not right" }
        if moment.outcomeState == "acted", moment.handedOver != nil {
            if moment.waiting == CaptureOutcome.Waiting.wake, moment.isHandedOver { return AutoPhoneText.notWokenWord }
            if moment.isHandedOver { return AutoPhoneText.handedOverWord }
            if (moment.actions ?? []).contains("assign") { return AutoPhoneText.stoppedWord }
        }
        if moment.outcomeState == "acted", moment.waiting == CaptureOutcome.Waiting.give, moment.isHeldForYou { return AutoPhoneText.waitsForGiveWord }
        // Lane Y2: said in a capture in Auto, it waits for it.
        if moment.outcomeState == "acted", moment.joins != nil { return AutoPhoneText.withItsCapture }
        return switch moment.outcomeState {
        case "offered": moment.title ?? "Add?"
        case "acted": "Done"
        case "answered": "Answered"
        case "undone": "Taken back"
        case "dismissed": "Not added"
        // Who has it; the line under your words says what comes next.
        case "working": "\(MacConnection.BrainWords) is on it"
        case "nothing": "Nothing to do"
        default: moment.state == "kept" ? "Waiting for \(MacConnection.brainWords)" : moment.state == "refused" ? "\(MacConnection.BrainWords) couldn't read it" : "Sent"
        }
    }

    /// An action's button, as the notification names it.
    static func title(_ action: String, agent: String?) -> String {
        switch action {
        case "add": "Add"
        case "not-now": "Not Now"
        case "undo": "Undo"
        case "stop": "Stop"
        case "not-me": "Not Me"
        case "assign": agent.map { LockScreenText.giveTo($0) } ?? "Give to an Agent"
        default: action
        }
    }
}

/// The Mode menu under Said to yourself: Suggest, Add at Once or Auto, the line that says what the mode does (read by
/// VoiceOver as the menu's hint), and in Auto what it can do now and what it can't hear. Choosing Auto opens its sheet;
/// the mode changes only with its Use Auto.
struct MomentModeRow: View {
    @Environment(MacConnection.self) private var connection
    @State private var center = MomentCenter.shared
    @Binding var choosingAuto: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mode", selection: Binding(get: { center.mode }, set: { chosen in
                if chosen == .auto { choosingAuto = true } else { center.choose(chosen) }
            })) {
                ForEach(MomentMode.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("momentMode")
            .accessibilityHint(summary)
            Text(summary).font(.footnote).foregroundStyle(Palette.muted).accessibilityHidden(true)
            if let state {
                Text(state).font(.footnote).foregroundStyle(Palette.ink).accessibilityIdentifier("momentModeState")
            }
            if let solo = soloState {
                Text(solo).font(.footnote).foregroundStyle(Palette.ink)
            }
            if center.mode == .auto {
                Text(soloMac ? AutoPhoneText.soloHears : AutoPhoneText.cantHear).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        // Who may take what you say, as the Mac says now.
        .task(id: center.mode) { if center.mode == .auto, connection.isConnected { await AgentConsents.refresh(connection) } }
    }

    /// Lane Y2: the Mac reads what you think out loud.
    private var soloMac: Bool { connection.macFeatures.contains(ConversationPayload.soloFeature) }

    /// The line under the menu: Add at Once's says it adds what you think out loud too, with a Mac that reads it.
    private var summary: String { center.mode == .add && soloMac ? AutoPhoneText.addSummarySolo : center.mode.summary }

    /// Lane Y2, in Auto: whether, and when, what you think out loud goes.
    private var soloState: String? {
        guard center.mode == .auto, connection.hasBrain else { return nil }
        let features = connection.macFeatures
        guard features.contains(MomentPayload.autoFeature) else { return nil }
        guard soloMac else { return AutoPhoneText.macAutoNotSolo }
        guard UserDefaults.standard.bool(forKey: MomentCenter.soloAutoListedKey) else { return AutoPhoneText.soloBeforeSheet }
        return ConversationProcessor.shared.writesDownWhileLocked ? AutoPhoneText.soloWhenLockedOn : AutoPhoneText.soloWhenLockedOff
    }

    /// In Auto, what it can do now (DESIGN 6.4); in Add at Once, a Mac that can't add at once.
    private var state: String? {
        let features = connection.macFeatures
        let adds = features.contains(MomentPayload.addsFeature)
        switch center.mode {
        case .suggest: return nil
        case .add: return adds || !connection.hasBrain ? nil : AutoPhoneText.macNoAdds
        case .auto:
            let list = AgentConsents.agents(connection)
            return AutoPhoneText.modeLine(AutoPhoneText.ModeFacts(
                macListsAuto: features.contains(MomentPayload.autoFeature), macListsAdds: adds, listed: center.autoListed,
                macInReach: connection.isConnected, startBarSet: VoicePrint.startThreshold != nil, reach: list?.auto?.reach,
                mayTake: AgentConsents.mayTakeInAuto(list).map(\.name)))
        }
    }
}
/// A capture's row, from its line in the index, leading with what it is: a filed one's title, or the first line said,
/// or, before there are words, where it is. Under it, smaller: the time, how long, and the binder and what was made
/// once it's filed; or the state word and what it waits for. Its glyph says the state: red while it's recorded with the
/// microphone live, a problem in ink, waiting quiet, filed in ink with a check.
private struct ConversationCaptureRow: View {
    @Environment(MacConnection.self) private var connection
    let conversation: CaptureEntry
    let activity: String?
    let queuedLabel: String
    /// What comes next while it waits for the Mac.
    let queuedNext: String?

    var body: some View {
        let look = stateLook
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: look.symbol).foregroundStyle(look.tint).captureGlyph()
            VStack(alignment: .leading, spacing: 3) {
                headline.foregroundStyle(Palette.ink).lineLimit(2)
                detailText.font(.caption).monospacedDigit().foregroundStyle(Palette.muted).lineLimit(3)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var filed: (binder: String, title: String?, rest: [String])? {
        guard conversation.state == .sent, conversation.outcomeState == CaptureOutcome.States.filed, let line = conversation.outcome else { return nil }
        return CaptureOutcome.filedParts(in: line, among: [BinderColors.filed(in: line, connection: connection)].compactMap { $0 })
    }

    /// What it is, in words: a filed one's title, the first line said, or its state.
    private var headlineWords: String {
        if let filed { return filed.title ?? "Filed in \(filed.binder)" }
        if let first = conversation.firstLine { return first }
        return state
    }

    private var headline: Text {
        if filed == nil, let first = conversation.firstLine { return Text("“\(first)”").font(Typeface.quote()) }
        return Text(headlineWords).font(.body)
    }

    /// The state word goes on the line below when the headline isn't it already; a filed one's check says it.
    private var stateBelow: String? {
        filed == nil && conversation.firstLine != nil ? state : nil
    }

    /// The time, how long, then the binder (in its colour) and what was made; or what it waits for.
    private var detailText: Text {
        var text = Text("")
        var first = true
        func add(_ part: Text) {
            text = first ? part : text + Text(" · ") + part
            first = false
        }
        if let stateBelow { add(Text(stateBelow).fontWeight(.medium)) }
        add(Text(conversation.started.formatted(date: .omitted, time: .shortened)))
        add(Text(CaptureRowText.duration(conversation)))
        if let filed {
            let tint = BinderColors.tint(filed.binder, connection: connection)
            add(Text(filed.binder).fontWeight(.semibold).foregroundStyle(tint?.text ?? Palette.muted))
        }
        for part in details { add(Text(part)) }
        return text
    }

    /// What VoiceOver reads: the state, what it is, then the rest.
    private var spoken: String {
        var parts = [filed == nil ? state : "Filed", headlineWords, conversation.started.formatted(date: .omitted, time: .shortened),
                     CaptureRowText.duration(conversation)]
        if let filed { parts.append("in \(filed.binder)") }
        parts += details
        // The headline is the state already when there are no words yet.
        if parts[0] == parts[1] { parts.removeFirst() }
        return parts.joined(separator: ", ")
    }

    /// The details after the time and duration: what was made, or what it waits for and what gets it going. The audio is
    /// gone once it's written down, so its page says that, not its row.
    private var details: [String] {
        var parts: [String] = []
        if let filed {
            parts += filed.rest
        } else if let outcome = conversation.outcome, conversation.state == .sent, outcome != state {
            // The Mac's word on it: being written up, or why it couldn't be.
            parts.append(outcome)
        }
        if let activity {
            parts.append(activity)
        } else if let error = conversation.error {
            parts.append(error)
        } else if [.recorded, .transcribing, .labelling].contains(conversation.state) {
            // Why it waits, when it was told, and what gets it going.
            if let reason = conversation.waitingBecause {
                parts.append("waiting: \(reason)")
            } else {
                parts.append(CaptureModels.mayInferInBackground && conversation.appOnly != true
                             ? "written down while Binders is open, or while the phone charges"
                             : "written down while Binders is open")
            }
        }
        if conversation.state == .queued, let queuedNext { parts.append(queuedNext) }
        if conversation.canRetry { parts.append("tried again when Binders opens") }
        if !conversation.audioDeleted, conversation.state != .sent, conversation.keepAudioUntil != nil { parts.append("audio kept for a day") }
        return parts
    }

    /// The state's glyph and colour: red while it's being recorded with the microphone live, a problem in ink with its
    /// glyph, waiting quiet, filed in ink with a check (sent isn't filed).
    private var stateLook: (symbol: String, tint: Color) {
        switch conversation.state {
        case .recording: ("waveform", CaptureSession.shared.isListening ? Palette.live : Palette.muted)
        case .sent where conversation.outcomeState == CaptureOutcome.States.filed: ("checkmark.circle", Palette.ink)
        case .sent where conversation.outcomeState == CaptureOutcome.States.failed: (Problem.symbol, Palette.ink)
        case .sent where conversation.outcomeState == CaptureOutcome.States.writing: ("hourglass", Palette.muted)
        case .sent: ("paperplane", Palette.muted)
        case .failed: (Problem.symbol, Palette.ink)
        case .queued: ("clock", Palette.muted)
        case .transcribing, .labelling: (activity == nil ? "clock" : "hourglass", Palette.muted)
        case .recorded: ("clock", Palette.muted)
        }
    }

    private var state: String {
        switch conversation.state {
        case .recording: "Recording"
        case .recorded: "Waiting to be written down"
        // Not being worked on, these wait too: after a quit, or stopped in the background.
        case .transcribing: activity == nil ? "Waiting to be written down" : "Transcribing"
        case .labelling: activity == nil ? "Waiting to be written down" : "Labelling speakers"
        case .queued: queuedLabel
        case .sent: sentLabel
        case .failed: conversation.hasTranscript ? "Not sent" : "Not written down"
        }
    }

    /// What the Mac made of it, once it says.
    private var sentLabel: String {
        switch conversation.outcomeState {
        case CaptureOutcome.States.filed: "Filed"
        case CaptureOutcome.States.failed: "Not written up"
        case CaptureOutcome.States.writing: "Being written up"
        default: conversation.sharedVia == "AirDrop" ? "AirDropped" : "Sent"
        }
    }
}

/// Twenty seconds of reading, for your voice print: from capture's settings, and from Calibrate when there's no print yet.
struct VoiceTeachingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var teaching = VoiceTeaching()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Read this out loud, at your normal pace, somewhere quiet.").foregroundStyle(Palette.muted)
                Text(VoiceTeaching.passage).font(.title3).foregroundStyle(Palette.ink).surfaceCard()
                switch teaching.phase {
                case .ready:
                    Button { Task { await teaching.start() } } label: {
                        Label("Start Reading", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .primaryButton()
                case .listening:
                    // The microphone is live: red.
                    ProgressView(value: teaching.progress) { Text("Listening…").foregroundStyle(Palette.live) }
                        .tint(Palette.live)
                case .learning:
                    ProgressView("Learning your voice…").tint(Palette.muted).foregroundStyle(Palette.muted)
                case .done:
                    // Learned, not a to-do done: ink with its check, not green.
                    Label("Done. Your lines will be marked as you.", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ink)
                case .failed(let message):
                    ProblemLabel(message)
                    Button("Try Again") { Task { await teaching.start() } }
                }
                Spacer()
            }
            .padding()
            .screenGround()
            .navigationTitle("Teach Binders your voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(teaching.phase == .done ? "Done" : "Cancel") {
                        teaching.cancel()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The row on the home screen: is it on, and how's it going.
struct CaptureStatusLabel: View {
    @State private var capture = CaptureSession.shared
    @State private var store = CaptureStore.shared

    var body: some View {
        HStack {
            Label("All-day capture", systemImage: "waveform.and.mic")
            Spacer()
            // Red while it listens, as the microphone is live.
            Text(summary).monospacedDigit().foregroundStyle(capture.isListening ? Palette.live : Palette.muted)
        }
    }

    private var summary: String {
        guard capture.isOn else { return "Off" }
        let count = store.today().count
        return capture.status.title + (count > 0 ? " · \(count)" : "")
    }
}

/// Mute and Unmute, the capture screen's main control. Listening, Mute is a calm outlined control in ink: the microphone
/// being live is said by the small red glyph beside "Listening", not by a red block. Muted, Unmute is the call to action,
/// filled with the brand's indigo.
private struct MuteButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(muted ? "Unmute" : "Mute", systemImage: muted ? "mic" : "mic.slash")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(OutlinedButtonStyle(filled: muted))
    }
}

/// A full-width control on a card: ink inside a hairline outline, or, `filled`, white on the accent. Either dims a
/// little while pressed, and the same in the dark and the light.
struct OutlinedButtonStyle: ButtonStyle {
    var filled = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .foregroundStyle(filled ? Color.white : Palette.ink)
            .padding(.horizontal, 12)
            .background {
                if filled {
                    shape.fill(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1))
                } else {
                    shape.fill(Palette.ink.opacity(configuration.isPressed ? 0.08 : 0))
                    shape.strokeBorder(Palette.ink.opacity(0.28), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
