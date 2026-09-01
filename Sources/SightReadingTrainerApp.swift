import SwiftUI
import CoreMIDI
import AVFoundation
import WebKit

// MARK: - App

@main
struct SightReadingTrainerApp: App {
    @StateObject private var game = GameModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(game)
                .preferredColorScheme(.light)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }
}

// MARK: - Music model

enum PracticeMode: String, CaseIterable, Identifiable {
    case single = "단음 연습"
    case sequence = "4음 연속"
    var id: String { rawValue }
}

enum ClefChoice: String, CaseIterable, Identifiable {
    case treble = "높은음자리표"
    case bass = "낮은음자리표"
    case both = "둘 다"
    var id: String { rawValue }
}

enum Difficulty: String, CaseIterable, Identifiable {
    case intro = "입문"
    case basic = "기본"
    case full = "전체"
    var id: String { rawValue }
}

enum StaffClef: String {
    case treble, bass
}

struct QuestionNote: Identifiable, Equatable {
    let id = UUID()
    let midi: Int
    let clef: StaffClef
    let vexKey: String
    let accidental: String?

    var displayName: String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        let octave = midi / 12 - 1
        return "\(names[midi % 12])\(octave)"
    }
}

struct ResultStats {
    let rank: String
    let score: Int
    let accuracy: Double
    let average: Double
    let maxCombo: Int
}

// MARK: - Audio

final class PianoAudio {
    private var players: [Int: AVAudioPlayer] = [:]

    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }

    func play(midi: Int) {
        guard (36...84).contains(midi) else { return }
        guard let url = Bundle.main.url(forResource: "midi_\(midi)", withExtension: "mp3") else {
            print("Missing piano sample midi_\(midi).mp3")
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 0.9
            players[midi] = player
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self, weak player] in
                guard let self, let player else { return }
                if self.players[midi] === player { self.players[midi] = nil }
            }
        } catch {
            print("Piano playback error: \(error)")
        }
    }
}

// MARK: - MIDI

final class MIDIManager: ObservableObject {
    @Published var sources: [String] = []
    @Published var lastNote: Int?
    var onNoteOn: ((Int, Int) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    init() {
        createClient()
        refreshSources()
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func createClient() {
        MIDIClientCreateWithBlock("SightReadingTrainer" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSources() }
        }

        MIDIInputPortCreateWithBlock(client, "Input" as CFString, &inputPort) { [weak self] packetList, _ in
            guard let self else { return }
            var packet = packetList.pointee.packet
            for _ in 0..<packetList.pointee.numPackets {
                let length = Int(packet.length)
                withUnsafeBytes(of: packet.data) { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var index = 0
                    var runningStatus: UInt8 = 0
                    while index < length {
                        let byte = bytes[index]
                        if byte & 0x80 != 0 {
                            runningStatus = byte
                            index += 1
                        }
                        guard index + 1 < length, runningStatus != 0 else { break }
                        let data1 = bytes[index]
                        let data2 = bytes[index + 1]
                        index += 2
                        if (runningStatus & 0xF0) == 0x90 && data2 > 0 {
                            let note = Int(data1)
                            let velocity = Int(data2)
                            DispatchQueue.main.async {
                                self.lastNote = note
                                self.onNoteOn?(note, velocity)
                            }
                        }
                    }
                }
                packet = MIDIPacketNext(&packet).pointee
            }
        }
    }

    func refreshSources() {
        var names: [String] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let endpoint = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
            let display = name?.takeRetainedValue() as String? ?? "MIDI \(i + 1)"
            names.append(display)
            MIDIPortConnectSource(inputPort, endpoint, nil)
        }
        sources = names
    }
}

// MARK: - Game state

final class GameModel: ObservableObject {
    @Published var mode: PracticeMode = .single
    @Published var clefChoice: ClefChoice = .both
    @Published var difficulty: Difficulty = .basic
    @Published var showKeyboard = true
    @Published var isPlaying = false
    @Published var isFinished = false

    @Published var notes: [QuestionNote] = []
    @Published var activeIndex = 0
    @Published var score = 0
    @Published var combo = 0
    @Published var maxCombo = 0
    @Published var correctCount = 0
    @Published var attemptCount = 0
    @Published var responseTimes: [Double] = []
    @Published var feedback = ""
    @Published var pressedMidi: Int?
    @Published var result: ResultStats?

    let midi = MIDIManager()
    private let audio = PianoAudio()
    private var questionStart = Date()
    private var completedUnits = 0
    private var currentClef: StaffClef = .treble

    init() {
        midi.onNoteOn = { [weak self] note, _ in
            self?.input(note, playAppSound: false)
        }
    }

    var totalCorrectNeeded: Int { mode == .single ? 30 : 40 }
    var progressText: String {
        if mode == .single { return "\(min(completedUnits + 1, 30)) / 30" }
        return "\(min(completedUnits / 4 + 1, 10)) / 10 세트"
    }
    var accuracy: Double { attemptCount == 0 ? 100 : Double(correctCount) / Double(attemptCount) * 100 }
    var averageTime: Double { responseTimes.isEmpty ? 0 : responseTimes.reduce(0,+) / Double(responseTimes.count) }

    func start() {
        score = 0; combo = 0; maxCombo = 0
        correctCount = 0; attemptCount = 0; responseTimes = []
        completedUnits = 0; feedback = ""; pressedMidi = nil
        isFinished = false; isPlaying = true
        makeQuestion()
    }

    func quit() {
        isPlaying = false
        isFinished = false
        notes = []
    }

    func input(_ midiNote: Int, playAppSound: Bool) {
        guard isPlaying, !isFinished, !notes.isEmpty else { return }
        pressedMidi = midiNote
        if playAppSound { audio.play(midi: midiNote) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.pressedMidi == midiNote { self?.pressedMidi = nil }
        }

        guard notes.indices.contains(activeIndex) else { return }
        attemptCount += 1
        let target = notes[activeIndex]
        if midiNote == target.midi {
            correctCount += 1
            combo += 1
            maxCombo = max(maxCombo, combo)
            let elapsed = Date().timeIntervalSince(questionStart)
            responseTimes.append(elapsed)
            let base: Int
            if elapsed <= 0.8 { feedback = "PERFECT"; base = 100 }
            else if elapsed <= 1.5 { feedback = "GREAT"; base = 80 }
            else if elapsed <= 2.5 { feedback = "GOOD"; base = 60 }
            else { feedback = "OK"; base = 40 }
            let bonus = min(50, max(0, combo - 1) * 2)
            score += base + bonus
            completedUnits += 1

            if completedUnits >= totalCorrectNeeded {
                finish()
                return
            }

            if mode == .sequence && activeIndex < notes.count - 1 {
                activeIndex += 1
                questionStart = Date()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    self?.makeQuestion()
                }
            }
        } else {
            combo = 0
            feedback = "MISS"
            // Same note remains until correct.
        }
    }

    private func finish() {
        let acc = accuracy
        let avg = averageTime
        let rank: String
        if mode == .single && acc >= 97 && avg <= 1.1 && score >= 2900 { rank = "S" }
        else if mode == .sequence && acc >= 97 && avg <= 1.1 { rank = "S" }
        else if acc >= 90 && avg <= 1.8 { rank = "A" }
        else if acc >= 80 { rank = "B" }
        else { rank = "C" }
        result = ResultStats(rank: rank, score: score, accuracy: acc, average: avg, maxCombo: maxCombo)
        isFinished = true
        isPlaying = false
    }

    private func makeQuestion() {
        feedback = ""
        activeIndex = 0
        currentClef = chooseClef()
        if mode == .single {
            notes = [randomNote(clef: currentClef, avoiding: nil)]
        } else {
            var built: [QuestionNote] = []
            for _ in 0..<4 {
                let n = randomNote(clef: currentClef, avoiding: built.last?.midi)
                built.append(n)
            }
            notes = built
        }
        questionStart = Date()
    }

    private func chooseClef() -> StaffClef {
        switch clefChoice {
        case .treble: return .treble
        case .bass: return .bass
        case .both: return Bool.random() ? .treble : .bass
        }
    }

    private func randomNote(clef: StaffClef, avoiding: Int?) -> QuestionNote {
        let range: ClosedRange<Int>
        switch difficulty {
        case .intro:
            range = clef == .treble ? 60...76 : 43...60
        case .basic:
            range = clef == .treble ? 55...84 : 36...67
        case .full:
            range = 36...84
        }

        let naturalPC: Set<Int> = [0,2,4,5,7,9,11]
        var midiValue = Int.random(in: range)
        if difficulty == .intro {
            var tries = 0
            while !naturalPC.contains(midiValue % 12) && tries < 30 {
                midiValue = Int.random(in: range); tries += 1
            }
        } else if difficulty == .basic && Int.random(in: 0..<100) < 68 {
            var tries = 0
            while !naturalPC.contains(midiValue % 12) && tries < 30 {
                midiValue = Int.random(in: range); tries += 1
            }
        }
        if midiValue == avoiding {
            midiValue = midiValue < range.upperBound ? midiValue + 1 : midiValue - 1
        }
        return makeSpelling(midi: midiValue, clef: clef)
    }

    private func makeSpelling(midi: Int, clef: StaffClef) -> QuestionNote {
        let pc = midi % 12
        let octave = midi / 12 - 1
        let useFlat = Bool.random()
        let name: String
        let accidental: String?
        switch pc {
        case 0: name = "c"; accidental = nil
        case 1: if useFlat { name = "d"; accidental = "b" } else { name = "c"; accidental = "#" }
        case 2: name = "d"; accidental = nil
        case 3: if useFlat { name = "e"; accidental = "b" } else { name = "d"; accidental = "#" }
        case 4: name = "e"; accidental = nil
        case 5: name = "f"; accidental = nil
        case 6: if useFlat { name = "g"; accidental = "b" } else { name = "f"; accidental = "#" }
        case 7: name = "g"; accidental = nil
        case 8: if useFlat { name = "a"; accidental = "b" } else { name = "g"; accidental = "#" }
        case 9: name = "a"; accidental = nil
        case 10: if useFlat { name = "b"; accidental = "b" } else { name = "a"; accidental = "#" }
        default: name = "b"; accidental = nil
        }
        return QuestionNote(midi: midi, clef: clef, vexKey: "\(name)/\(octave)", accidental: accidental)
    }
}

// MARK: - Root & start

struct RootView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        ZStack {
            Color(red: 0.965, green: 0.97, blue: 0.98).ignoresSafeArea()
            if game.isFinished, let result = game.result {
                ResultView(result: result)
            } else if game.isPlaying {
                TrainingView()
            } else {
                StartView()
            }
        }
    }
}

struct StartView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("초견 트레이너")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("악보를 보고 정확한 건반을 빠르게 찾는 연습")
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                SettingCard(title: "연습 모드") {
                    Picker("연습 모드", selection: $game.mode) {
                        ForEach(PracticeMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                SettingCard(title: "음자리표") {
                    Picker("음자리표", selection: $game.clefChoice) {
                        ForEach(ClefChoice.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                SettingCard(title: "난이도") {
                    Picker("난이도", selection: $game.difficulty) {
                        ForEach(Difficulty.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 36)

            Toggle("화면 피아노 표시", isOn: $game.showKeyboard)
                .frame(width: 260)

            StatusPill(text: game.midi.sources.isEmpty ? "MIDI 피아노 연결 대기" : "MIDI 연결됨 · \(game.midi.sources.first!)", on: !game.midi.sources.isEmpty)

            Button(action: game.start) {
                Text("연습 시작")
                    .font(.title3.bold())
                    .frame(width: 250, height: 54)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
            Text("v1.0")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
    }
}

struct SettingCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusPill: View {
    let text: String
    let on: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(on ? Color.green : Color.gray).frame(width: 9, height: 9)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white, in: Capsule())
    }
}

// MARK: - Training

struct TrainingView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Button("종료") { game.quit() }
                    .buttonStyle(.bordered)
                HUDItem(label: "진행", value: game.progressText)
                HUDItem(label: "점수", value: "\(game.score)")
                HUDItem(label: "콤보", value: "\(game.combo)")
                HUDItem(label: "정확도", value: String(format: "%.1f%%", game.accuracy))
                HUDItem(label: "평균", value: game.responseTimes.isEmpty ? "-" : String(format: "%.2fs", game.averageTime))
                Spacer()
                StatusPill(text: game.midi.sources.isEmpty ? "MIDI 대기" : "MIDI 연결", on: !game.midi.sources.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)

            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white)
                VStack(spacing: 0) {
                    NotationWebView(notes: game.notes, activeIndex: game.activeIndex)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(game.feedback)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .frame(height: 30)
                        .foregroundStyle(feedbackColor(game.feedback))
                }
                if let target = game.notes.indices.contains(game.activeIndex) ? game.notes[game.activeIndex] : nil {
                    Text(target.clef == .treble ? "높은음자리표" : "낮은음자리표")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(10)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 22)

            if game.showKeyboard {
                PianoKeyboardView(range: 36...84, pressedMidi: game.pressedMidi) { midi in
                    game.input(midi, playAppSound: true)
                }
                .frame(height: 180)
                .padding(.horizontal, 22)
                .padding(.bottom, 12)
            }
        }
    }

    private func feedbackColor(_ s: String) -> Color {
        switch s {
        case "MISS": return .red
        case "PERFECT": return .purple
        case "GREAT": return .blue
        case "GOOD": return .green
        default: return .secondary
        }
    }
}

struct HUDItem: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
        }
        .frame(minWidth: 75)
    }
}

// MARK: - VexFlow notation web view

struct NotationPayload: Codable {
    struct Item: Codable {
        let key: String
        let clef: String
        let accidental: String?
        let dimmed: Bool
    }
    let clef: String
    let notes: [Item]
}

struct NotationWebView: UIViewRepresentable {
    let notes: [QuestionNote]
    let activeIndex: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "notation", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pending = payload()
        context.coordinator.renderIfReady()
    }

    private func payload() -> NotationPayload {
        let clef = notes.first?.clef.rawValue ?? "treble"
        let items = notes.enumerated().map { index, note in
            NotationPayload.Item(key: note.vexKey, clef: note.clef.rawValue, accidental: note.accidental, dimmed: index < activeIndex)
        }
        return NotationPayload(clef: clef, notes: items)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var ready = false
        var pending: NotationPayload?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            renderIfReady()
        }

        func renderIfReady() {
            guard ready, let webView, let pending else { return }
            guard let data = try? JSONEncoder().encode(pending),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.renderSightNotes(\(json));") { _, error in
                if let error { print("Notation JS error: \(error)") }
            }
        }
    }
}

// MARK: - Piano keyboard

struct PianoKeyboardView: View {
    let range: ClosedRange<Int>
    let pressedMidi: Int?
    let onPress: (Int) -> Void

    @State private var activeTouchMidi: Int?
    private var whiteNotes: [Int] { range.filter { isWhite($0) } }
    private let blackPC: Set<Int> = [1,3,6,8,10]

    var body: some View {
        GeometryReader { geo in
            let whites = whiteNotes
            let whiteWidth = geo.size.width / CGFloat(whites.count)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whites, id: \.self) { midi in
                        Rectangle()
                            .fill(pressedMidi == midi ? Color(red: 0.73, green: 0.84, blue: 1.0) : .white)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.6))
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        if activeTouchMidi != midi {
                                            activeTouchMidi = midi
                                            onPress(midi)
                                        }
                                    }
                                    .onEnded { _ in
                                        if activeTouchMidi == midi { activeTouchMidi = nil }
                                    }
                            )
                    }
                }
                ForEach(Array(range).filter { blackPC.contains($0 % 12) }, id: \.self) { midi in
                    if let leftWhiteIndex = whiteIndexBefore(midi, whites: whites) {
                        let x = (CGFloat(leftWhiteIndex + 1) * whiteWidth) - (whiteWidth * 0.31)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pressedMidi == midi ? Color(red: 0.32, green: 0.48, blue: 0.78) : .black)
                            .frame(width: whiteWidth * 0.62, height: geo.size.height * 0.62)
                            .offset(x: x)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        if activeTouchMidi != midi {
                                            activeTouchMidi = midi
                                            onPress(midi)
                                        }
                                    }
                                    .onEnded { _ in
                                        if activeTouchMidi == midi { activeTouchMidi = nil }
                                    }
                            )
                    }
                }
                ForEach(36...84, id: \.self) { midi in
                    if midi % 12 == 0, isWhite(midi), let idx = whites.firstIndex(of: midi) {
                        Text("C\(midi/12-1)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .position(x: (CGFloat(idx)+0.5)*whiteWidth, y: geo.size.height-11)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.35), lineWidth: 1))
        }
    }

    private func isWhite(_ midi: Int) -> Bool { !blackPC.contains(midi % 12) }
    private func whiteIndexBefore(_ midi: Int, whites: [Int]) -> Int? {
        whites.lastIndex(where: { $0 < midi })
    }
}

// MARK: - Result

struct ResultView: View {
    @EnvironmentObject var game: GameModel
    let result: ResultStats

    var body: some View {
        VStack(spacing: 22) {
            Text("연습 완료").font(.largeTitle.bold())
            Text(result.rank)
                .font(.system(size: 96, weight: .black, design: .rounded))
            HStack(spacing: 28) {
                ResultCell(label: "점수", value: "\(result.score)")
                ResultCell(label: "정확도", value: String(format: "%.1f%%", result.accuracy))
                ResultCell(label: "평균 반응", value: String(format: "%.2fs", result.average))
                ResultCell(label: "최대 콤보", value: "\(result.maxCombo)")
            }
            HStack(spacing: 14) {
                Button("다시 연습") { game.start() }.buttonStyle(.borderedProminent)
                Button("설정으로") { game.quit() }.buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }
}

struct ResultCell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 7) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }
        .frame(width: 150, height: 90)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
    }
}
