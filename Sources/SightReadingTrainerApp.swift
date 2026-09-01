
import SwiftUI
import CoreMIDI
import Combine

@main
struct SightReadingTrainerApp: App {
    @StateObject private var game = GameModel()
    @StateObject private var midi = MIDIManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(game)
                .environmentObject(midi)
                .onAppear {
                    midi.onNoteOn = { note, velocity in
                        game.handleInput(midi: note, velocity: velocity)
                    }
                }
        }
    }
}

// MARK: - Music Model

enum ClefChoice: String, CaseIterable, Identifiable {
    case both = "둘 다"
    case treble = "높은음자리표"
    case bass = "낮은음자리표"
    var id: String { rawValue }
}

enum ClefKind: String {
    case treble, bass
}

enum Accidental: Int {
    case flat = -1
    case natural = 0
    case sharp = 1

    var symbol: String {
        switch self {
        case .flat: return "♭"
        case .natural: return ""
        case .sharp: return "♯"
        }
    }
}

struct QuizNote: Equatable, Identifiable {
    let id = UUID()
    let letter: Int       // C=0 D=1 E=2 F=3 G=4 A=5 B=6
    let octave: Int
    let accidental: Accidental
    let clef: ClefKind

    var naturalMidi: Int {
        let offsets = [0, 2, 4, 5, 7, 9, 11]
        return (octave + 1) * 12 + offsets[letter]
    }

    var targetMidi: Int { naturalMidi + accidental.rawValue }

    var noteName: String {
        let names = ["C","D","E","F","G","A","B"]
        return "\(names[letter])\(accidental.symbol)\(octave)"
    }

    var diatonicIndex: Int {
        octave * 7 + letter
    }
}

enum TrainingMode: String, CaseIterable, Identifiable {
    case single = "단음"
    case sequence = "4음 연속"
    var id: String { rawValue }
}

enum TimingGrade: String {
    case perfect = "PERFECT"
    case great = "GREAT"
    case good = "GOOD"
    case ok = "OK"
    case miss = "MISS"
}

struct AttemptRecord {
    let note: QuizNote
    let time: Double
    let correct: Bool
}

@MainActor
final class GameModel: ObservableObject {
    @Published var mode: TrainingMode = .single
    @Published var clefChoice: ClefChoice = .both
    @Published var current: QuizNote?
    @Published var sequence: [QuizNote] = []
    @Published var sequenceIndex: Int = 0

    @Published var score = 0
    @Published var combo = 0
    @Published var maxCombo = 0
    @Published var correct = 0
    @Published var wrong = 0
    @Published var answered = 0
    @Published var feedback = ""
    @Published var lastReaction: Double?
    @Published var isRunning = false
    @Published var showResult = false
    @Published var showSettings = false
    @Published var showKeyboard = true

    @Published var bestSingle = UserDefaults.standard.integer(forKey: "bestSingle")
    @Published var bestSequence = UserDefaults.standard.integer(forKey: "bestSequence")

    private var shownAt: CFTimeInterval?
    private var transitionToken = UUID()
    private var locked = false
    private(set) var attempts: [AttemptRecord] = []

    var targetCount: Int { mode == .single ? 30 : 40 }
    var accuracy: Double {
        let total = correct + wrong
        return total == 0 ? 100.0 : Double(correct) / Double(total) * 100
    }
    var averageTime: Double {
        let good = attempts.filter(\.correct)
        guard !good.isEmpty else { return 0 }
        return good.map(\.time).reduce(0,+) / Double(good.count)
    }

    func start() {
        transitionToken = UUID()
        score = 0; combo = 0; maxCombo = 0
        correct = 0; wrong = 0; answered = 0
        feedback = ""; lastReaction = nil
        attempts = []
        showResult = false
        isRunning = true
        locked = false
        nextQuestion()
    }

    func toggleSettings(_ showing: Bool) {
        showSettings = showing
        if showing {
            shownAt = nil
        } else if isRunning, current != nil {
            startTimerAfterFrame()
        }
    }

    func changeClef(_ newValue: ClefChoice) {
        clefChoice = newValue
        if isRunning {
            nextQuestion()
        }
    }

    func handleInput(midi: Int, velocity: Int = 100) {
        guard isRunning, !showSettings, !locked, let note = current, let shownAt else { return }

        if midi != note.targetMidi {
            wrong += 1
            combo = 0
            feedback = "MISS"
            attempts.append(AttemptRecord(note: note, time: CACurrentMediaTime() - shownAt, correct: false))
            return
        }

        locked = true
        self.shownAt = nil

        let reaction = CACurrentMediaTime() - shownAt
        lastReaction = reaction
        let (grade, points) = grade(for: reaction)
        feedback = grade.rawValue

        correct += 1
        answered += 1
        combo += 1
        maxCombo = max(maxCombo, combo)
        attempts.append(AttemptRecord(note: note, time: reaction, correct: true))

        let comboBonus = min(50, max(0, combo - 1) * 2)
        score += points + comboBonus

        if answered >= targetCount {
            let token = transitionToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.transitionToken == token else { return }
                self.finish()
            }
            return
        }

        if mode == .sequence, sequenceIndex < 3 {
            sequenceIndex += 1
            current = sequence[sequenceIndex]
            locked = false
            startTimerAfterFrame()
        } else {
            let token = transitionToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
                guard let self, self.transitionToken == token else { return }
                self.nextQuestion()
            }
        }
    }

    private func grade(for time: Double) -> (TimingGrade, Int) {
        if time <= 0.8 { return (.perfect, 100) }
        if time <= 1.5 { return (.great, 80) }
        if time <= 2.5 { return (.good, 60) }
        return (.ok, 40)
    }

    private func nextQuestion() {
        guard isRunning else { return }
        locked = false
        if mode == .single {
            sequence = []
            sequenceIndex = 0
            current = randomNote()
        } else {
            sequence = makeSequence()
            sequenceIndex = 0
            current = sequence.first
        }
        startTimerAfterFrame()
    }

    private func startTimerAfterFrame() {
        shownAt = nil
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, !self.showSettings else { return }
                self.shownAt = CACurrentMediaTime()
            }
        }
    }

    private func finish() {
        isRunning = false
        shownAt = nil
        showResult = true
        if mode == .single {
            if score > bestSingle {
                bestSingle = score
                UserDefaults.standard.set(score, forKey: "bestSingle")
            }
        } else {
            if score > bestSequence {
                bestSequence = score
                UserDefaults.standard.set(score, forKey: "bestSequence")
            }
        }
    }

    func rank() -> String {
        if mode == .single {
            if accuracy >= 97, averageTime <= 1.1, score >= 2900 { return "S" }
        } else {
            if accuracy >= 97, averageTime <= 1.1 { return "S" }
        }
        if accuracy >= 90, averageTime <= 1.8 { return "A" }
        if accuracy >= 80 { return "B" }
        return "C"
    }

    func resetRecords() {
        UserDefaults.standard.removeObject(forKey: "bestSingle")
        UserDefaults.standard.removeObject(forKey: "bestSequence")
        bestSingle = 0
        bestSequence = 0
    }

    private func randomNote() -> QuizNote {
        let pool = makePool()
        return pool.randomElement() ?? QuizNote(letter: 0, octave: 4, accidental: .natural, clef: .treble)
    }

    private func makePool() -> [QuizNote] {
        var result: [QuizNote] = []
        for octave in 2...6 {
            for letter in 0...6 {
                if octave == 6 && letter > 0 { continue } // C6 max
                let natural = QuizNote(letter: letter, octave: octave, accidental: .natural, clef: .treble)
                guard (36...84).contains(natural.naturalMidi) else { continue }

                let clef: ClefKind
                switch clefChoice {
                case .both:
                    clef = natural.naturalMidi <= 59 ? .bass : .treble
                case .treble:
                    clef = .treble
                case .bass:
                    clef = .bass
                }

                var acc: Accidental = .natural
                if Int.random(in: 0..<100) < 28 {
                    let choices: [Accidental] = [.sharp, .flat].filter {
                        let midi = natural.naturalMidi + $0.rawValue
                        return (36...84).contains(midi)
                    }
                    acc = choices.randomElement() ?? .natural
                }

                result.append(QuizNote(letter: letter, octave: octave, accidental: acc, clef: clef))
            }
        }
        return result
    }

    private func makeSequence() -> [QuizNote] {
        let pool = makePool()
        guard let first = pool.randomElement() else { return [] }
        var result = [first]
        var last = first
        while result.count < 4 {
            let candidates = pool.filter { abs($0.targetMidi - last.targetMidi) <= 12 }
            let next = candidates.randomElement() ?? pool.randomElement() ?? first
            result.append(next)
            last = next
        }
        return result
    }
}

// MARK: - Core MIDI

final class MIDIManager: ObservableObject {
    @Published var connectedSources: [String] = []
    @Published var lastNoteName = "—"
    @Published var lastNote = 0
    @Published var lastVelocity = 0

    var onNoteOn: ((Int, Int) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var connectedEndpoints = Set<MIDIEndpointRef>()

    init() {
        setupMIDI()
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func setupMIDI() {
        MIDIClientCreateWithBlock("SightReadingTrainerClient" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshSources()
            }
        }

        MIDIInputPortCreateWithBlock(client, "SightReadingTrainerInput" as CFString, &inputPort) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }

        refreshSources()
    }

    func refreshSources() {
        guard inputPort != 0 else { return }

        var names: [String] = []
        var seen = Set<MIDIEndpointRef>()
        let count = MIDIGetNumberOfSources()

        for index in 0..<count {
            let source = MIDIGetSource(index)
            seen.insert(source)

            if !connectedEndpoints.contains(source) {
                MIDIPortConnectSource(inputPort, source, nil)
                connectedEndpoints.insert(source)
            }

            var unmanagedName: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &unmanagedName) == noErr,
               let cfName = unmanagedName?.takeRetainedValue() {
                names.append(cfName as String)
            } else {
                names.append("MIDI 입력 \(index + 1)")
            }
        }

        for old in connectedEndpoints where !seen.contains(old) {
            MIDIPortDisconnectSource(inputPort, old)
            connectedEndpoints.remove(old)
        }

        DispatchQueue.main.async {
            self.connectedSources = names
        }
    }

    private func handle(packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            withUnsafeBytes(of: packet.data) { raw in
                let bytes = Array(raw.prefix(Int(packet.length)))
                var i = 0
                while i < bytes.count {
                    let status = bytes[i]
                    let high = status & 0xF0

                    if high == 0x90 || high == 0x80 {
                        guard i + 2 < bytes.count else { break }
                        let note = Int(bytes[i + 1])
                        let velocity = Int(bytes[i + 2])

                        if high == 0x90 && velocity > 0 {
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.lastNote = note
                                self.lastVelocity = velocity
                                self.lastNoteName = Self.noteName(note)
                                self.onNoteOn?(note, velocity)
                            }
                        }
                        i += 3
                    } else if high == 0xC0 || high == 0xD0 {
                        i += 2
                    } else if status >= 0xF8 {
                        i += 1
                    } else {
                        i += 3
                    }
                }
            }

            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private static func noteName(_ note: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        guard note >= 0 else { return "—" }
        return "\(names[note % 12])\(note / 12 - 1)"
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var game: GameModel
    @EnvironmentObject var midi: MIDIManager

    var body: some View {
        ZStack {
            Color(red: 0.965, green: 0.968, blue: 0.975).ignoresSafeArea()

            if game.isRunning {
                trainingView
            } else {
                startView
            }

            if game.showResult {
                ResultSheet()
            }

            if game.showSettings {
                SettingsSheet()
            }
        }
    }

    private var startView: some View {
        VStack(spacing: 22) {
            Spacer()

            Text("초견 트레이너")
                .font(.system(size: 48, weight: .bold, design: .rounded))

            Text("악보를 보고 실제 피아노에서 최대한 빠르게 찾아보세요.")
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Circle()
                    .fill(midi.connectedSources.isEmpty ? Color.secondary.opacity(0.45) : Color.green)
                    .frame(width: 10, height: 10)
                Text(midi.connectedSources.isEmpty ? "MIDI 피아노 연결 대기" : "MIDI 연결됨: \(midi.connectedSources.joined(separator: ", "))")
                    .font(.headline)
            }
            .padding(.top, 8)

            Picker("모드", selection: $game.mode) {
                ForEach(TrainingMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 430)

            Button {
                game.start()
            } label: {
                Text("연습 시작")
                    .font(.title2.bold())
                    .frame(width: 300, height: 58)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 24) {
                Button("설정") { game.toggleSettings(true) }
                Text("개인 최고점  \(game.mode == .single ? game.bestSingle : game.bestSequence)")
                    .foregroundStyle(.secondary)
            }
            .font(.headline)

            Spacer()
        }
        .padding(40)
    }

    private var trainingView: some View {
        VStack(spacing: 0) {
            HUDView()
                .padding(.horizontal, 22)
                .padding(.vertical, 10)

            Divider()

            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)

                VStack(spacing: 6) {
                    if game.mode == .sequence, !game.sequence.isEmpty {
                        StaffSequenceView(notes: game.sequence, focusIndex: game.sequenceIndex)
                            .padding(.horizontal, 20)
                    } else if let note = game.current {
                        StaffView(note: note)
                            .padding(.horizontal, 20)
                    }

                    HStack(spacing: 14) {
                        Text(game.feedback)
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .frame(width: 150)

                        if let t = game.lastReaction {
                            Text(String(format: "%.2fs", t))
                                .font(.title2.monospacedDigit().bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 36)
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if game.showKeyboard {
                PianoKeyboardView(range: 36...84) { midi in
                    game.handleInput(midi: midi, velocity: 100)
                }
                .frame(height: 170)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            } else {
                Spacer(minLength: 12)
            }
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var game: GameModel
    @EnvironmentObject var midi: MIDIManager

    var body: some View {
        HStack(spacing: 24) {
            hud("SCORE", "\(game.score)")
            hud("COMBO", "×\(game.combo)")
            hud("진행", "\(game.answered)/\(game.targetCount)")
            hud("정확도", String(format: "%.0f%%", game.accuracy))
            hud("평균", game.averageTime == 0 ? "—" : String(format: "%.2fs", game.averageTime))

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(midi.connectedSources.isEmpty ? Color.secondary.opacity(0.4) : Color.green)
                    .frame(width: 9, height: 9)
                Text(midi.connectedSources.isEmpty ? "MIDI 대기" : "MIDI 연결")
                    .font(.subheadline.weight(.semibold))
            }

            Button {
                game.start()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                game.toggleSettings(true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
        }
    }

    private func hud(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }
}

// MARK: - Staff Rendering

struct StaffView: View {
    let note: QuizNote

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                StaffRenderer.draw(context: &context, size: size, notes: [note], focus: 0)
            }
        }
        .frame(minHeight: 210)
    }
}

struct StaffSequenceView: View {
    let notes: [QuizNote]
    let focusIndex: Int

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                StaffRenderer.draw(context: &context, size: size, notes: notes, focus: focusIndex)
            }
        }
        .frame(minHeight: 210)
    }
}

enum StaffRenderer {
    static func draw(context: inout GraphicsContext, size: CGSize, notes: [QuizNote], focus: Int) {
        guard let first = notes.first else { return }

        let lineSpacing: CGFloat = 24
        let centerY = size.height * 0.52
        let staffLeft: CGFloat = 76
        let staffRight = max(staffLeft + 100, size.width - 36)

        for i in 0..<5 {
            let y = centerY + CGFloat(i - 2) * lineSpacing
            var p = Path()
            p.move(to: CGPoint(x: staffLeft, y: y))
            p.addLine(to: CGPoint(x: staffRight, y: y))
            context.stroke(p, with: .color(.black.opacity(0.88)), lineWidth: 1.6)
        }

        let clefText = first.clef == .treble ? "𝄞" : "𝄢"
        context.draw(
            Text(clefText).font(.system(size: 72)),
            at: CGPoint(x: staffLeft + 30, y: centerY + 3),
            anchor: .center
        )

        let xs: [CGFloat]
        if notes.count == 1 {
            xs = [size.width * 0.62]
        } else {
            let start = size.width * 0.39
            let end = size.width * 0.84
            xs = (0..<notes.count).map { idx in
                start + (end - start) * CGFloat(idx) / CGFloat(max(1, notes.count - 1))
            }
        }

        for (i, note) in notes.enumerated() {
            let active = i == focus
            let color = active ? Color.black : Color.gray.opacity(0.52)
            drawNote(context: &context,
                     note: note,
                     x: xs[i],
                     centerY: centerY,
                     spacing: lineSpacing,
                     color: color)
        }
    }

    private static func drawNote(context: inout GraphicsContext,
                                 note: QuizNote,
                                 x: CGFloat,
                                 centerY: CGFloat,
                                 spacing: CGFloat,
                                 color: Color) {
        let middleLineIndex: Int
        switch note.clef {
        case .treble:
            middleLineIndex = 4 * 7 + 6 // B4
        case .bass:
            middleLineIndex = 3 * 7 + 3 // F3
        }

        let delta = note.diatonicIndex - middleLineIndex
        let y = centerY - CGFloat(delta) * spacing / 2

        drawLedgerLines(context: &context, note: note, x: x, centerY: centerY, spacing: spacing, color: color)

        let rect = CGRect(x: x - 12, y: y - 8, width: 24, height: 16)
        let ellipse = Path(ellipseIn: rect)
        context.fill(ellipse, with: .color(color))

        let middleStaffDelta = 0
        let stemUp = delta < middleStaffDelta
        var stem = Path()
        if stemUp {
            stem.move(to: CGPoint(x: x + 10, y: y))
            stem.addLine(to: CGPoint(x: x + 10, y: y - 52))
        } else {
            stem.move(to: CGPoint(x: x - 10, y: y))
            stem.addLine(to: CGPoint(x: x - 10, y: y + 52))
        }
        context.stroke(stem, with: .color(color), lineWidth: 2.2)

        if note.accidental != .natural {
            context.draw(
                Text(note.accidental.symbol).font(.system(size: 38, weight: .regular)),
                at: CGPoint(x: x - 38, y: y),
                anchor: .center
            )
        }
    }

    private static func drawLedgerLines(context: inout GraphicsContext,
                                        note: QuizNote,
                                        x: CGFloat,
                                        centerY: CGFloat,
                                        spacing: CGFloat,
                                        color: Color) {
        let bottomLineIndex: Int
        let topLineIndex: Int

        switch note.clef {
        case .treble:
            bottomLineIndex = 4 * 7 + 2 // E4
            topLineIndex = 5 * 7 + 3    // F5
        case .bass:
            bottomLineIndex = 2 * 7 + 4 // G2
            topLineIndex = 3 * 7 + 5    // A3
        }

        let idx = note.diatonicIndex

        if idx < bottomLineIndex {
            var ledger = bottomLineIndex - 2
            while ledger >= idx {
                if (ledger - idx) % 2 == 0 || ledger >= idx {
                    let y = yFor(index: ledger, noteClef: note.clef, centerY: centerY, spacing: spacing)
                    var p = Path()
                    p.move(to: CGPoint(x: x - 22, y: y))
                    p.addLine(to: CGPoint(x: x + 22, y: y))
                    context.stroke(p, with: .color(color), lineWidth: 1.6)
                }
                ledger -= 2
            }
        } else if idx > topLineIndex {
            var ledger = topLineIndex + 2
            while ledger <= idx {
                let y = yFor(index: ledger, noteClef: note.clef, centerY: centerY, spacing: spacing)
                var p = Path()
                p.move(to: CGPoint(x: x - 22, y: y))
                p.addLine(to: CGPoint(x: x + 22, y: y))
                context.stroke(p, with: .color(color), lineWidth: 1.6)
                ledger += 2
            }
        }
    }

    private static func yFor(index: Int, noteClef: ClefKind, centerY: CGFloat, spacing: CGFloat) -> CGFloat {
        let middleLineIndex = noteClef == .treble ? (4 * 7 + 6) : (3 * 7 + 3)
        let delta = index - middleLineIndex
        return centerY - CGFloat(delta) * spacing / 2
    }
}

// MARK: - Piano Keyboard

struct PianoKeyboardView: View {
    let range: ClosedRange<Int>
    let onPress: (Int) -> Void

    private let blackClasses = Set([1,3,6,8,10])

    private var whiteNotes: [Int] {
        range.filter { !blackClasses.contains($0 % 12) }
    }

    var body: some View {
        GeometryReader { geo in
            let whites = whiteNotes
            let whiteWidth = geo.size.width / CGFloat(whites.count)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(whites, id: \.self) { midi in
                        Button {
                            onPress(midi)
                        } label: {
                            ZStack(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.white)
                                Rectangle()
                                    .stroke(Color.black.opacity(0.55), lineWidth: 0.8)

                                if midi == 60 {
                                    Text("C4")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 7)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: whiteWidth)
                    }
                }

                ForEach(Array(range), id: \.self) { midi in
                    if blackClasses.contains(midi % 12),
                       let lowerWhiteIndex = whites.lastIndex(where: { $0 < midi }) {
                        let centerX = CGFloat(lowerWhiteIndex + 1) * whiteWidth
                        Button {
                            onPress(midi)
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black)
                        }
                        .buttonStyle(.plain)
                        .frame(width: whiteWidth * 0.64, height: geo.size.height * 0.62)
                        .position(x: centerX, y: geo.size.height * 0.31)
                        .zIndex(2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.45), lineWidth: 1))
        }
    }
}

// MARK: - Sheets

struct ResultSheet: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()

            VStack(spacing: 16) {
                Text(game.rank())
                    .font(.system(size: 72, weight: .black, design: .rounded))

                Text("연습 완료")
                    .font(.title.bold())

                HStack(spacing: 36) {
                    stat("SCORE", "\(game.score)")
                    stat("정확도", String(format: "%.1f%%", game.accuracy))
                    stat("평균", game.averageTime == 0 ? "—" : String(format: "%.2fs", game.averageTime))
                    stat("MAX COMBO", "×\(game.maxCombo)")
                }

                HStack(spacing: 14) {
                    Button("다시 연습") { game.start() }
                        .buttonStyle(.borderedProminent)

                    Button("처음으로") {
                        game.showResult = false
                        game.isRunning = false
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .padding(36)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 20)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("설정")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("완료") { game.toggleSettings(false) }
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("음자리표")
                        .font(.headline)
                    Picker("음자리표", selection: Binding(
                        get: { game.clefChoice },
                        set: { game.changeClef($0) }
                    )) {
                        ForEach(ClefChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("화면 건반 표시", isOn: $game.showKeyboard)

                Divider()

                Button(role: .destructive) {
                    game.resetRecords()
                } label: {
                    Text("연습 기록 전체 초기화")
                }

                Text("실제 MIDI 피아노를 연결하면 건반 입력이 자동으로 정답 판정에 사용됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 560)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 20)
        }
    }
}
