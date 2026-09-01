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
    private var currentNoteMissed = false
    private var feedbackGeneration = 0
    private var finishing = false
    // 4음 연속 모드에서는 한 세트(4음)가 끝날 때까지 음자리표를 절대 바꾸지 않는다.
    private var sequenceSetClef: StaffClef?

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
        currentNoteMissed = false; feedbackGeneration = 0; finishing = false
        isFinished = false; isPlaying = true
        sequenceSetClef = nil
        makeQuestion()
    }

    func quit() {
        isPlaying = false
        isFinished = false
        finishing = false
        sequenceSetClef = nil
        notes = []
    }

    func input(_ midiNote: Int, playAppSound: Bool) {
        guard isPlaying, !isFinished, !finishing, !notes.isEmpty else { return }
        pressedMidi = midiNote
        if playAppSound { audio.play(midi: midiNote) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.pressedMidi == midiNote { self?.pressedMidi = nil }
        }

        guard notes.indices.contains(activeIndex) else { return }
        let target = notes[activeIndex]

        if midiNote == target.midi {
            if currentNoteMissed {
                // 이미 한 번 틀린 음은 MISS 결과로 확정한다.
                // 정답 건반을 찾으면 다음 음으로 진행하지만 속도 점수/콤보/정답률 보너스는 주지 않는다.
                completedUnits += 1
                advanceAfterResolvedNote()
                return
            }

            attemptCount += 1
            correctCount += 1
            combo += 1
            maxCombo = max(maxCombo, combo)
            let elapsed = Date().timeIntervalSince(questionStart)
            responseTimes.append(elapsed)
            let base: Int
            let rating: String
            if elapsed <= 0.8 { rating = "PERFECT"; base = 100 }
            else if elapsed <= 1.5 { rating = "GREAT"; base = 80 }
            else if elapsed <= 2.5 { rating = "GOOD"; base = 60 }
            else { rating = "OK"; base = 40 }
            showFeedback(rating)
            let bonus = min(50, max(0, combo - 1) * 2)
            score += base + bonus
            completedUnits += 1
            advanceAfterResolvedNote()
        } else {
            if !currentNoteMissed {
                // 오답은 한 음당 한 번만 통계에 반영한다. 이후 정답을 찾을 때까지 같은 음을 유지한다.
                currentNoteMissed = true
                attemptCount += 1
                combo = 0
            }
            showFeedback("MISS")
        }
    }

    private func advanceAfterResolvedNote() {
        if completedUnits >= totalCorrectNeeded {
            // 마지막 판정도 사용자가 확인할 수 있게 잠깐 보여준 뒤 결과 화면으로 이동한다.
            finishing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.finish()
            }
            return
        }

        if mode == .sequence && activeIndex < notes.count - 1 {
            activeIndex += 1
            currentNoteMissed = false
            questionStart = Date()
        } else {
            // 판정은 화면에 조금 더 남겨두되 다음 문제는 빠르게 제시한다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.makeQuestion()
            }
        }
    }

    private func showFeedback(_ text: String) {
        feedbackGeneration += 1
        let generation = feedbackGeneration
        feedback = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, self.feedbackGeneration == generation else { return }
            self.feedback = ""
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
        activeIndex = 0
        currentNoteMissed = false

        if mode == .single {
            currentClef = chooseClef()
            notes = [randomNote(clef: currentClef, avoiding: nil)]
        } else {
            // 세트 시작 시 딱 한 번만 음자리표를 결정한다.
            // 1→2→3→4번째 음으로 넘어갈 때는 이 값을 다시 뽑지 않는다.
            let setClef = chooseClef()
            sequenceSetClef = setClef
            currentClef = setClef

            var built: [QuestionNote] = []
            for _ in 0..<4 {
                let n = randomNote(clef: setClef, avoiding: built.last?.midi)
                built.append(n)
            }
            notes = built

            // 방어 검증: 한 세트의 4음은 반드시 같은 음자리표여야 한다.
            precondition(notes.allSatisfy { $0.clef == setClef },
                         "Sequence set must use one fixed clef")
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
            // 전체 C2~C6 범위는 유지하되 실제 피아노 악보처럼 음자리표에 맞게 배분한다.
            // 극단적인 '높은음자리표+C2' / '낮은음자리표+C6' 조합은 피한다.
            range = clef == .treble ? 55...84 : 36...67
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
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button("종료") { game.quit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                HUDItem(label: "진행", value: game.progressText)
                HUDItem(label: "점수", value: "\(game.score)")
                HUDItem(label: "콤보", value: "\(game.combo)")
                HUDItem(label: "정확도", value: String(format: "%.1f%%", game.accuracy))
                HUDItem(label: "평균", value: game.responseTimes.isEmpty ? "-" : String(format: "%.2fs", game.averageTime))
                Spacer(minLength: 8)
                StatusPill(text: game.midi.sources.isEmpty ? "MIDI 대기" : "MIDI 연결", on: !game.midi.sources.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)

            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white)

                NotationWebView(notes: game.notes, activeIndex: game.activeIndex, isSingle: game.mode == .single)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 판정은 화면 전체가 아니라 악보 카드 자체를 기준으로 배치한다.
                // 오선 위 중앙에 고정되어 iPad 비율이 달라도 우측 상단으로 밀리지 않는다.
                VStack(spacing: 0) {
                    if !game.feedback.isEmpty {
                        Text(game.feedback)
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .foregroundStyle(feedbackColor(game.feedback))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.94), in: Capsule())
                            .shadow(radius: 4, y: 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        if game.mode == .sequence {
                            Text("\(game.activeIndex + 1)/4")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        Spacer()
                        if let target = game.notes.indices.contains(game.activeIndex) ? game.notes[game.activeIndex] : nil {
                            Text(target.clef == .treble ? "높은음자리표" : "낮은음자리표")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 22)

            if game.showKeyboard {
                PianoKeyboardView(range: 36...84, pressedMidi: game.pressedMidi) { midi in
                    game.input(midi, playAppSound: true)
                }
                .frame(height: 180)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
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
        HStack(spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.7), in: Capsule())
    }
}

// MARK: - VexFlow notation web view

struct NotationPayload: Codable {
    struct Item: Codable {
        let key: String
        let clef: String
        let accidental: String?
        let state: String
    }
    let clef: String
    let notes: [Item]
    let single: Bool
}

struct NotationWebView: UIViewRepresentable {
    let notes: [QuestionNote]
    let activeIndex: Int
    let isSingle: Bool

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
            let state: String
            if isSingle { state = "current" }
            else if index < activeIndex { state = "done" }
            else if index == activeIndex { state = "current" }
            else { state = "future" }
            return NotationPayload.Item(key: note.vexKey, clef: note.clef.rawValue, accidental: note.accidental, state: state)
        }
        return NotationPayload(clef: clef, notes: items, single: isSingle)
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
                            .fill(pressedMidi == midi ? Color.gray.opacity(0.35) : .white)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.45), lineWidth: 0.6))
                    }
                }

                ForEach(Array(range).filter { blackPC.contains($0 % 12) }, id: \.self) { midi in
                    if let leftWhiteIndex = whiteIndexBefore(midi, whites: whites) {
                        let x = (CGFloat(leftWhiteIndex + 1) * whiteWidth) - (whiteWidth * 0.31)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pressedMidi == midi ? Color.gray : .black)
                            .frame(width: whiteWidth * 0.62, height: geo.size.height * 0.62)
                            .offset(x: x)
                            .allowsHitTesting(false)
                    }
                }

                ForEach(36...84, id: \.self) { midi in
                    if midi % 12 == 0, isWhite(midi), let idx = whites.firstIndex(of: midi) {
                        Text("C\(midi/12-1)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .position(x: (CGFloat(idx)+0.5)*whiteWidth, y: geo.size.height-11)
                            .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard let midi = midiAt(location: value.location, size: geo.size, whites: whites) else { return }
                        if activeTouchMidi != midi {
                            activeTouchMidi = midi
                            onPress(midi)
                        }
                    }
                    .onEnded { _ in
                        activeTouchMidi = nil
                    }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.35), lineWidth: 1))
        }
    }

    private func midiAt(location: CGPoint, size: CGSize, whites: [Int]) -> Int? {
        guard location.x >= 0, location.y >= 0, location.x < size.width, location.y < size.height, !whites.isEmpty else { return nil }
        let whiteWidth = size.width / CGFloat(whites.count)

        // 검은건반은 흰건반 위에 겹치므로 반드시 먼저 판정한다.
        if location.y <= size.height * 0.62 {
            for midi in range where blackPC.contains(midi % 12) {
                guard let leftWhiteIndex = whiteIndexBefore(midi, whites: whites) else { continue }
                let left = CGFloat(leftWhiteIndex + 1) * whiteWidth - whiteWidth * 0.31
                let right = left + whiteWidth * 0.62
                if location.x >= left && location.x < right { return midi }
            }
        }

        let index = min(whites.count - 1, max(0, Int(location.x / whiteWidth)))
        return whites[index]
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
