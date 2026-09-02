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

enum TrainingFamily: String, CaseIterable, Identifiable {
    case oneHand = "한손"
    case twoHand = "양손"
    case chord = "화음"
    var id: String { rawValue }
}

enum PracticeMode: String, CaseIterable, Identifiable {
    case single = "단음"
    case sequence = "4음"
    var id: String { rawValue }
}

enum ChordSize: Int, CaseIterable, Identifiable {
    case dyad = 2
    case triad = 3
    var id: Int { rawValue }
    var label: String { rawValue == 2 ? "2음" : "3음" }
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
    var onNoteOff: ((Int) -> Void)?

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
                        let kind = runningStatus & 0xF0
                        if kind == 0x90 {
                            let note = Int(data1)
                            if data2 > 0 {
                                let velocity = Int(data2)
                                DispatchQueue.main.async {
                                    self.lastNote = note
                                    self.onNoteOn?(note, velocity)
                                }
                            } else {
                                DispatchQueue.main.async { self.onNoteOff?(note) }
                            }
                        } else if kind == 0x80 {
                            let note = Int(data1)
                            DispatchQueue.main.async { self.onNoteOff?(note) }
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
    @Published var family: TrainingFamily = .oneHand
    @Published var mode: PracticeMode = .single
    @Published var chordSize: ChordSize = .dyad
    @Published var clefChoice: ClefChoice = .both
    @Published var difficulty: Difficulty = .basic
    @Published var showKeyboard = true
    @Published var isPlaying = false
    @Published var isFinished = false

    // 기존 한손 모드 데이터. 단음/4음 로직은 이 배열을 그대로 사용한다.
    @Published var notes: [QuestionNote] = []
    // 양손/화음은 한 번에 눌러야 하는 음들을 한 그룹으로 분리해 보관한다.
    @Published var multiGroups: [[QuestionNote]] = []
    @Published var activeIndex = 0
    @Published var score = 0
    @Published var combo = 0
    @Published var maxCombo = 0
    @Published var correctCount = 0
    @Published var attemptCount = 0
    @Published var responseTimes: [Double] = []
    @Published var feedback = ""
    @Published var pressedMidi: Int?
    @Published var heldMidis: Set<Int> = []
    @Published var result: ResultStats?

    let midi = MIDIManager()
    private let audio = PianoAudio()
    private var questionStart = Date()
    private var completedUnits = 0
    private var currentClef: StaffClef = .treble
    private var currentNoteMissed = false
    private var feedbackGeneration = 0
    private var finishing = false
    // 4음 모드에서는 한 세트가 끝날 때까지 음자리표/큰보표 구성을 유지한다.
    private var sequenceSetClef: StaffClef?

    // 양손/화음 전용 동시입력 수집기. 기존 한손 input()은 이 경로를 타지 않는다.
    private var multiWindowNotes: Set<Int> = []
    private var multiWindowLastInputAt: Date?
    private var multiWindowWorkItem: DispatchWorkItem?
    // 양손/화음 동시입력 허용시간. 입문은 손 모양을 익힐 여유를 주고, 난이도가 오를수록 실제 동시타건에 가깝게 좁힌다.
    private var simultaneousWindow: TimeInterval {
        switch difficulty {
        case .intro: return 0.24
        case .basic: return 0.17
        case .full: return 0.12
        }
    }

    private struct SpelledTone {
        let letter: String
        let accidental: String?
        let pc: Int
    }

    private struct TriadTemplate {
        let tones: [SpelledTone]
        let isMinor: Bool
    }

    init() {
        midi.onNoteOn = { [weak self] note, _ in
            self?.handleMIDINoteOn(note)
        }
        midi.onNoteOff = { [weak self] note in
            self?.heldMidis.remove(note)
        }
    }

    var isSequenceMode: Bool { family != .chord && mode == .sequence }
    var isMultiMode: Bool { family == .twoHand || family == .chord }
    var notationGroups: [[QuestionNote]] {
        family == .oneHand ? notes.map { [$0] } : multiGroups
    }
    var notationLayout: String {
        switch family {
        case .oneHand: return "staff"
        case .twoHand: return "grand"
        case .chord: return "chord"
        }
    }
    var isSinglePresentation: Bool { !isSequenceMode }
    var activeTargetNotes: [QuestionNote] {
        if family == .oneHand {
            guard notes.indices.contains(activeIndex) else { return [] }
            return [notes[activeIndex]]
        }
        guard multiGroups.indices.contains(activeIndex) else { return [] }
        return multiGroups[activeIndex]
    }

    var totalCorrectNeeded: Int {
        if family == .chord { return 30 }
        return mode == .single ? 30 : 40
    }

    var progressText: String {
        if family == .chord || mode == .single {
            return "\(min(completedUnits + 1, 30)) / 30"
        }
        return "\(min(completedUnits / 4 + 1, 10)) / 10 세트"
    }

    var accuracy: Double { attemptCount == 0 ? 100 : Double(correctCount) / Double(attemptCount) * 100 }
    var averageTime: Double { responseTimes.isEmpty ? 0 : responseTimes.reduce(0,+) / Double(responseTimes.count) }

    func start() {
        score = 0; combo = 0; maxCombo = 0
        correctCount = 0; attemptCount = 0; responseTimes = []
        completedUnits = 0; feedback = ""; pressedMidi = nil; heldMidis = []
        currentNoteMissed = false; feedbackGeneration = 0; finishing = false
        isFinished = false; isPlaying = true
        sequenceSetClef = nil
        resetMultiWindow()
        makeQuestion()
    }

    func quit() {
        isPlaying = false
        isFinished = false
        finishing = false
        sequenceSetClef = nil
        notes = []
        multiGroups = []
        heldMidis = []
        resetMultiWindow()
    }

    private func handleMIDINoteOn(_ note: Int) {
        heldMidis.insert(note)
        if isMultiMode {
            multiInput(note, playAppSound: false)
        } else {
            input(note, playAppSound: false)
        }
    }

    // 기존 한손 단음/4음 판정 경로. 동작은 이전 버전과 동일하게 유지한다.
    func input(_ midiNote: Int, playAppSound: Bool) {
        guard family == .oneHand, isPlaying, !isFinished, !finishing, !notes.isEmpty else { return }
        pressedMidi = midiNote
        if playAppSound { audio.play(midi: midiNote) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.pressedMidi == midiNote { self?.pressedMidi = nil }
        }

        guard notes.indices.contains(activeIndex) else { return }
        let target = notes[activeIndex]

        if midiNote == target.midi {
            if currentNoteMissed {
                completedUnits += 1
                advanceAfterResolvedTarget()
                return
            }

            attemptCount += 1
            correctCount += 1
            combo += 1
            maxCombo = max(maxCombo, combo)
            let elapsed = Date().timeIntervalSince(questionStart)
            responseTimes.append(elapsed)
            addSpeedScore(elapsed: elapsed)
            completedUnits += 1
            advanceAfterResolvedTarget()
        } else {
            registerMissIfNeeded()
        }
    }

    // 양손/화음 전용. 첫 Note On부터 난이도별 허용시간 동안 들어온 음을 한 번의 동시입력으로 판정한다.
    func multiInput(_ midiNote: Int, playAppSound: Bool) {
        guard isMultiMode, isPlaying, !isFinished, !finishing, !activeTargetNotes.isEmpty else { return }
        if playAppSound { audio.play(midi: midiNote) }
        multiWindowNotes.insert(midiNote)
        multiWindowLastInputAt = Date()

        if multiWindowWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.evaluateMultiAttempt()
            }
            multiWindowWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + simultaneousWindow, execute: work)
        }
    }

    private func evaluateMultiAttempt() {
        guard isPlaying, !isFinished, !finishing else {
            resetMultiWindow()
            return
        }
        let expected = Set(activeTargetNotes.map(\.midi))
        let entered = multiWindowNotes
        let responseMoment = multiWindowLastInputAt ?? Date()
        resetMultiWindow()

        guard !expected.isEmpty else { return }
        if entered == expected {
            if currentNoteMissed {
                completedUnits += 1
                advanceAfterResolvedTarget()
                return
            }

            attemptCount += 1
            correctCount += 1
            combo += 1
            maxCombo = max(maxCombo, combo)
            let elapsed = responseMoment.timeIntervalSince(questionStart)
            responseTimes.append(elapsed)
            addSpeedScore(elapsed: elapsed)
            completedUnits += 1
            advanceAfterResolvedTarget()
        } else {
            registerMissIfNeeded()
        }
    }

    private func addSpeedScore(elapsed: Double) {
        let base: Int
        let rating: String
        if elapsed <= 0.8 { rating = "PERFECT"; base = 100 }
        else if elapsed <= 1.5 { rating = "GREAT"; base = 80 }
        else if elapsed <= 2.5 { rating = "GOOD"; base = 60 }
        else { rating = "OK"; base = 40 }
        showFeedback(rating)
        let bonus = min(50, max(0, combo - 1) * 2)
        score += base + bonus
    }

    private func registerMissIfNeeded() {
        if !currentNoteMissed {
            currentNoteMissed = true
            attemptCount += 1
            combo = 0
        }
        showFeedback("MISS")
    }

    private func advanceAfterResolvedTarget() {
        if completedUnits >= totalCorrectNeeded {
            finishing = true
            resetMultiWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.finish()
            }
            return
        }

        let count = family == .oneHand ? notes.count : multiGroups.count
        if isSequenceMode && activeIndex < count - 1 {
            activeIndex += 1
            currentNoteMissed = false
            resetMultiWindow()
            questionStart = Date()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.makeQuestion()
            }
        }
    }

    private func resetMultiWindow() {
        multiWindowWorkItem?.cancel()
        multiWindowWorkItem = nil
        multiWindowNotes = []
        multiWindowLastInputAt = nil
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
        if !isSequenceMode && acc >= 97 && avg <= 1.1 && score >= 2900 { rank = "S" }
        else if isSequenceMode && acc >= 97 && avg <= 1.1 { rank = "S" }
        else if acc >= 90 && avg <= 1.8 { rank = "A" }
        else if acc >= 80 { rank = "B" }
        else { rank = "C" }
        result = ResultStats(rank: rank, score: score, accuracy: acc, average: avg, maxCombo: maxCombo)
        isFinished = true
        isPlaying = false
        resetMultiWindow()
    }

    private func makeQuestion() {
        activeIndex = 0
        currentNoteMissed = false
        resetMultiWindow()
        notes = []
        multiGroups = []

        switch family {
        case .oneHand:
            if mode == .single {
                currentClef = chooseClef()
                notes = [randomNote(clef: currentClef, avoiding: nil)]
            } else {
                let setClef = chooseClef()
                sequenceSetClef = setClef
                currentClef = setClef

                var built: [QuestionNote] = []
                for _ in 0..<4 {
                    let n = randomNote(clef: setClef, avoiding: built.last?.midi)
                    built.append(n)
                }
                notes = built
                precondition(notes.allSatisfy { $0.clef == setClef },
                             "Sequence set must use one fixed clef")
            }

        case .twoHand:
            sequenceSetClef = nil
            let count = mode == .single ? 1 : 4
            var groups: [[QuestionNote]] = []
            var previous: [QuestionNote]?
            for _ in 0..<count {
                let pair = randomTwoHandPair(previous: previous)
                groups.append(pair)
                previous = pair
            }
            multiGroups = groups

        case .chord:
            let clef = chooseClef()
            currentClef = clef
            let chord = chordSize == .dyad ? randomInterval(clef: clef) : randomTriad(clef: clef)
            multiGroups = [chord]
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

    private func staffRange(_ clef: StaffClef) -> ClosedRange<Int> {
        switch difficulty {
        case .intro:
            return clef == .treble ? 60...76 : 43...60
        case .basic, .full:
            return clef == .treble ? 55...84 : 36...67
        }
    }

    private func randomNote(clef: StaffClef, avoiding: Int?) -> QuestionNote {
        let range = staffRange(clef)
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

    private func randomTwoHandPair(previous: [QuestionNote]?) -> [QuestionNote] {
        for _ in 0..<80 {
            let left = randomNote(clef: .bass, avoiding: previous?.first(where: { $0.clef == .bass })?.midi)
            let right = randomNote(clef: .treble, avoiding: previous?.first(where: { $0.clef == .treble })?.midi)
            guard right.midi - left.midi >= 7 else { continue }
            if let previous {
                if let oldLeft = previous.first(where: { $0.clef == .bass }), abs(oldLeft.midi - left.midi) > 12 { continue }
                if let oldRight = previous.first(where: { $0.clef == .treble }), abs(oldRight.midi - right.midi) > 12 { continue }
            }
            return [left, right]
        }
        // 안전한 폴백: 양손이 교차하지 않는 중앙 C 주변 자연음.
        return [makeSpelling(midi: 48, clef: .bass), makeSpelling(midi: 64, clef: .treble)]
    }

    private func randomInterval(clef: StaffClef) -> [QuestionNote] {
        let range = staffRange(clef)
        let rootPool: [SpelledTone]
        switch difficulty {
        case .intro:
            rootPool = [
                SpelledTone(letter: "c", accidental: nil, pc: 0), SpelledTone(letter: "d", accidental: nil, pc: 2),
                SpelledTone(letter: "e", accidental: nil, pc: 4), SpelledTone(letter: "f", accidental: nil, pc: 5),
                SpelledTone(letter: "g", accidental: nil, pc: 7), SpelledTone(letter: "a", accidental: nil, pc: 9),
                SpelledTone(letter: "b", accidental: nil, pc: 11)
            ]
        case .basic:
            rootPool = [
                SpelledTone(letter: "c", accidental: nil, pc: 0), SpelledTone(letter: "d", accidental: nil, pc: 2),
                SpelledTone(letter: "e", accidental: "b", pc: 3), SpelledTone(letter: "e", accidental: nil, pc: 4),
                SpelledTone(letter: "f", accidental: nil, pc: 5), SpelledTone(letter: "g", accidental: nil, pc: 7),
                SpelledTone(letter: "a", accidental: nil, pc: 9), SpelledTone(letter: "b", accidental: "b", pc: 10)
            ]
        case .full:
            rootPool = [
                SpelledTone(letter: "c", accidental: nil, pc: 0), SpelledTone(letter: "c", accidental: "#", pc: 1),
                SpelledTone(letter: "d", accidental: nil, pc: 2), SpelledTone(letter: "e", accidental: "b", pc: 3),
                SpelledTone(letter: "e", accidental: nil, pc: 4), SpelledTone(letter: "f", accidental: nil, pc: 5),
                SpelledTone(letter: "f", accidental: "#", pc: 6), SpelledTone(letter: "g", accidental: nil, pc: 7),
                SpelledTone(letter: "a", accidental: "b", pc: 8), SpelledTone(letter: "a", accidental: nil, pc: 9),
                SpelledTone(letter: "b", accidental: "b", pc: 10), SpelledTone(letter: "b", accidental: nil, pc: 11)
            ]
        }

        // (보표상 간격, 반음 간격). 입문은 모양을 익히기 쉬운 2·3·5도에 집중하고, 기본/전체에서 범위를 넓힌다.
        let majorPerfect: [(Int, Int)]
        let minorOptions: [(Int, Int)]
        switch difficulty {
        case .intro:
            majorPerfect = [(1,2), (2,4), (4,7)]
            minorOptions = []
        case .basic, .full:
            majorPerfect = [(1,2), (2,4), (3,5), (4,7), (5,9), (7,12)]
            minorOptions = [(1,1), (2,3), (5,8)]
        }
        let letterPC = [0,2,4,5,7,9,11]
        let letters = ["c","d","e","f","g","a","b"]

        for _ in 0..<120 {
            guard let root = rootPool.randomElement() else { break }
            var interval = majorPerfect.randomElement()!
            if difficulty != .intro && Bool.random(), let minor = minorOptions.randomElement() { interval = minor }
            let candidates = range.filter { $0 % 12 == root.pc && $0 + interval.1 <= range.upperBound }
            guard let rootMidi = candidates.randomElement() else { continue }
            let targetMidi = rootMidi + interval.1
            guard let rootLetterIndex = letters.firstIndex(of: root.letter) else { continue }
            let targetLetterIndex = (rootLetterIndex + interval.0) % 7
            let targetNaturalPC = letterPC[targetLetterIndex]
            let targetPC = targetMidi % 12
            let delta = (targetPC - targetNaturalPC + 12) % 12
            let targetAccidental: String?
            if delta == 0 { targetAccidental = nil }
            else if delta == 1 { targetAccidental = "#" }
            else if delta == 11 { targetAccidental = "b" }
            else { continue }
            if difficulty == .intro && (root.accidental != nil || targetAccidental != nil) { continue }
            let second = SpelledTone(letter: letters[targetLetterIndex], accidental: targetAccidental, pc: targetPC)
            return [makeSpelledNote(midi: rootMidi, tone: root, clef: clef),
                    makeSpelledNote(midi: targetMidi, tone: second, clef: clef)]
        }

        return [makeSpelling(midi: clef == .treble ? 60 : 48, clef: clef),
                makeSpelling(midi: clef == .treble ? 64 : 52, clef: clef)]
    }

    private func randomTriad(clef: StaffClef) -> [QuestionNote] {
        let range = staffRange(clef)
        let templates = allowedTriads()
        for _ in 0..<120 {
            guard let template = templates.randomElement(), template.tones.count == 3 else { break }
            let rootPC = template.tones[0].pc
            let rootCandidates = range.filter { $0 % 12 == rootPC }
            guard let rootMidi = rootCandidates.randomElement() else { continue }

            var built: [(SpelledTone, Int)] = []
            var last = rootMidi - 1
            for (index, tone) in template.tones.enumerated() {
                var midiValue: Int
                if index == 0 {
                    midiValue = rootMidi
                } else {
                    midiValue = (rootMidi / 12) * 12 + tone.pc
                    while midiValue <= last { midiValue += 12 }
                }
                built.append((tone, midiValue))
                last = midiValue
            }

            let inversion: Int
            switch difficulty {
            case .intro: inversion = 0
            case .basic: inversion = Int.random(in: 0...1)
            case .full: inversion = Int.random(in: 0...2)
            }
            if inversion > 0 {
                for i in 0..<inversion { built[i].1 += 12 }
                built.sort { $0.1 < $1.1 }
            }
            guard let low = built.first?.1, let high = built.last?.1,
                  low >= range.lowerBound, high <= range.upperBound, high - low <= 16 else { continue }
            return built.map { makeSpelledNote(midi: $0.1, tone: $0.0, clef: clef) }
        }

        let fallback = clef == .treble ? [60,64,67] : [48,52,55]
        return fallback.map { makeSpelling(midi: $0, clef: clef) }
    }

    private func allowedTriads() -> [TriadTemplate] {
        func t(_ a: SpelledTone, _ b: SpelledTone, _ c: SpelledTone, minor: Bool) -> TriadTemplate {
            TriadTemplate(tones: [a,b,c], isMinor: minor)
        }
        let C = SpelledTone(letter: "c", accidental: nil, pc: 0)
        let Cs = SpelledTone(letter: "c", accidental: "#", pc: 1)
        let Db = SpelledTone(letter: "d", accidental: "b", pc: 1)
        let D = SpelledTone(letter: "d", accidental: nil, pc: 2)
        let Ds = SpelledTone(letter: "d", accidental: "#", pc: 3)
        let Eb = SpelledTone(letter: "e", accidental: "b", pc: 3)
        let E = SpelledTone(letter: "e", accidental: nil, pc: 4)
        let F = SpelledTone(letter: "f", accidental: nil, pc: 5)
        let Fs = SpelledTone(letter: "f", accidental: "#", pc: 6)
        let Gb = SpelledTone(letter: "g", accidental: "b", pc: 6)
        let G = SpelledTone(letter: "g", accidental: nil, pc: 7)
        let Gs = SpelledTone(letter: "g", accidental: "#", pc: 8)
        let Ab = SpelledTone(letter: "a", accidental: "b", pc: 8)
        let A = SpelledTone(letter: "a", accidental: nil, pc: 9)
        let As = SpelledTone(letter: "a", accidental: "#", pc: 10)
        let Bb = SpelledTone(letter: "b", accidental: "b", pc: 10)
        let B = SpelledTone(letter: "b", accidental: nil, pc: 11)

        let natural = [
            t(C,E,G,minor:false), t(F,A,C,minor:false), t(G,B,D,minor:false),
            t(A,C,E,minor:true), t(D,F,A,minor:true), t(E,G,B,minor:true)
        ]
        if difficulty == .intro { return natural }

        let common = natural + [
            t(D,Fs,A,minor:false), t(Eb,G,Bb,minor:false), t(Bb,D,F,minor:false),
            t(C,Eb,G,minor:true), t(F,Ab,C,minor:true), t(G,Bb,D,minor:true),
            t(B,D,Fs,minor:true)
        ]
        if difficulty == .basic { return common }

        return common + [
            t(Db,F,Ab,minor:false), t(E,Gs,B,minor:false), t(Fs,As,Cs,minor:false),
            t(Ab,C,Eb,minor:false), t(A,Cs,E,minor:false), t(B,Ds,Fs,minor:false),
            t(Cs,E,Gs,minor:true), t(Eb,Gb,Bb,minor:true), t(Fs,A,Cs,minor:true),
            t(Gs,B,Ds,minor:true), t(Bb,Db,F,minor:true)
        ]
    }

    private func makeSpelledNote(midi: Int, tone: SpelledTone, clef: StaffClef) -> QuestionNote {
        let octave = midi / 12 - 1
        return QuestionNote(midi: midi, clef: clef, vexKey: "\(tone.letter)/\(octave)", accidental: tone.accidental)
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

enum AppTheme {
    static let background = Color(red: 0.955, green: 0.953, blue: 0.945)
    static let surface = Color.white
    static let ink = Color(red: 0.075, green: 0.085, blue: 0.105)
    static let muted = Color(red: 0.39, green: 0.42, blue: 0.47)
    static let accent = Color(red: 0.16, green: 0.20, blue: 0.30)
    static let accentSoft = Color(red: 0.91, green: 0.92, blue: 0.95)
    static let line = Color.black.opacity(0.07)
}

struct RootView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            if game.isFinished, let result = game.result {
                ResultView(result: result)
            } else if game.isPlaying {
                TrainingView()
            } else {
                StartView()
            }
        }
        .tint(AppTheme.accent)
    }
}

struct StartView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(AppTheme.ink)
                            .frame(width: 54, height: 54)
                        Image(systemName: "pianokeys")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text("초견 트레이너")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)
                }

                Spacer()

                Text("악보를 보는 순간,\n손이 먼저 움직이도록.")
                    .font(.system(size: 39, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .tracking(-0.8)
                    .lineSpacing(4)

                Text("한손부터 양손, 화음까지 실제 피아노로\n빠르고 정확하게 읽는 감각을 훈련합니다.")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppTheme.muted)
                    .lineSpacing(5)
                    .padding(.top, 18)

                Spacer()

                MidiConnectionCard(
                    text: game.midi.sources.isEmpty ? "MIDI 피아노 연결 대기" : "연결됨 · \(game.midi.sources.first!)",
                    connected: !game.midi.sources.isEmpty
                )

                Text("초견 트레이너  ·  v1.0")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.muted.opacity(0.78))
                    .padding(.top, 18)
            }
            .frame(width: 390, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.vertical, 36)

            Rectangle()
                .fill(AppTheme.line)
                .frame(width: 1)
                .padding(.vertical, 28)

            VStack(spacing: 16) {
                Spacer(minLength: 18)

                VStack(alignment: .leading, spacing: 24) {
                    Text("연습 설정")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.ink)

                    ModernSettingSection(title: "훈련") {
                        HStack(spacing: 8) {
                            ForEach(TrainingFamily.allCases) { item in
                                ChoiceButton(title: item.rawValue, selected: game.family == item) {
                                    withAnimation(.easeOut(duration: 0.16)) { game.family = item }
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 18) {
                        ModernSettingSection(title: game.family == .chord ? "구성" : "방식") {
                            HStack(spacing: 8) {
                                if game.family == .chord {
                                    ForEach(ChordSize.allCases) { item in
                                        ChoiceButton(title: item.label, selected: game.chordSize == item) {
                                            game.chordSize = item
                                        }
                                    }
                                } else {
                                    ForEach(PracticeMode.allCases) { item in
                                        ChoiceButton(title: item.rawValue, selected: game.mode == item) {
                                            game.mode = item
                                        }
                                    }
                                }
                            }
                        }

                        ModernSettingSection(title: "난이도") {
                            HStack(spacing: 8) {
                                ForEach(Difficulty.allCases) { item in
                                    ChoiceButton(title: item.rawValue, selected: game.difficulty == item) {
                                        game.difficulty = item
                                    }
                                }
                            }
                        }
                    }

                    ModernSettingSection(title: "악보") {
                        if game.family == .twoHand {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(AppTheme.accent)
                                Text("큰보표 · 높은음자리표 + 낮은음자리표")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Spacer()
                            }
                            .frame(height: 42)
                            .padding(.horizontal, 14)
                            .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            HStack(spacing: 8) {
                                ForEach(ClefChoice.allCases) { item in
                                    ChoiceButton(title: item.rawValue, selected: game.clefChoice == item) {
                                        game.clefChoice = item
                                    }
                                }
                            }
                        }
                    }

                    HStack {
                        HStack(spacing: 11) {
                            Image(systemName: "pianokeys")
                                .foregroundStyle(AppTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("화면 피아노")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.ink)
                                Text("터치 입력용 건반 표시")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: $game.showKeyboard)
                            .labelsHidden()
                    }
                    .padding(15)
                    .background(Color.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Button(action: game.start) {
                        HStack(spacing: 10) {
                            Text("연습 시작")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(28)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.045), radius: 24, y: 10)
                .frame(maxWidth: 720)

                Spacer(minLength: 18)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 34)
        }
    }
}

struct ModernSettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(AppTheme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Color.white : AppTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 42)
                .padding(.horizontal, 10)
                .background(selected ? AppTheme.ink : Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if !selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.line, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct MidiConnectionCard: View {
    let text: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(connected ? Color.green.opacity(0.14) : Color.black.opacity(0.05))
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(connected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("MIDI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
                Text(text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        }
    }
}

struct StatusPill: View {
    let text: String
    let on: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(on ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(AppTheme.ink)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(.white.opacity(0.8), in: Capsule())
        .overlay { Capsule().stroke(AppTheme.line, lineWidth: 1) }
    }
}

// MARK: - Training

struct TrainingView: View {
    @EnvironmentObject var game: GameModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button(action: game.quit) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("설정")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(.white.opacity(0.72), in: Capsule())
                    .overlay { Capsule().stroke(AppTheme.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text("초견 트레이너")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(AppTheme.ink)
                    Text(modeCaption)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer(minLength: 8)

                HUDItem(label: "진행", value: game.progressText)
                HUDItem(label: "점수", value: "\(game.score)")
                HUDItem(label: "콤보", value: "\(game.combo)")
                HUDItem(label: "정확도", value: String(format: "%.1f%%", game.accuracy))
                HUDItem(label: "평균", value: game.responseTimes.isEmpty ? "-" : String(format: "%.2fs", game.averageTime))
                StatusPill(text: game.midi.sources.isEmpty ? "MIDI 대기" : "MIDI 연결", on: !game.midi.sources.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(AppTheme.line, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.035), radius: 14, y: 5)

                NotationWebView(
                    groups: game.notationGroups,
                    activeIndex: game.activeIndex,
                    layout: game.notationLayout,
                    isSingle: game.isSinglePresentation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                // 실제 피아노 연주 시 편했던 기존 판정 위치는 유지한다.
                VStack(spacing: 0) {
                    if !game.feedback.isEmpty {
                        Text(game.feedback)
                            .font(.system(size: 46, weight: .black, design: .rounded))
                            .foregroundStyle(feedbackColor(game.feedback))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.95), in: Capsule())
                            .overlay { Capsule().stroke(AppTheme.line, lineWidth: 1) }
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    Spacer()
                }
                .padding(.top, 10)
                .allowsHitTesting(false)

                VStack {
                    HStack {
                        if game.isSequenceMode {
                            Text("\(game.activeIndex + 1)/4")
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundStyle(AppTheme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppTheme.accentSoft, in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 22)

            if game.showKeyboard {
                Group {
                    if game.isMultiMode {
                        MultiTouchPianoKeyboardView(range: 36...84, externalPressed: game.heldMidis) { midi in
                            game.multiInput(midi, playAppSound: true)
                        }
                    } else {
                        PianoKeyboardView(range: 36...84, pressedMidi: game.pressedMidi) { midi in
                            game.input(midi, playAppSound: true)
                        }
                    }
                }
                .frame(height: 180)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)
            }
        }
    }

    private var modeCaption: String {
        switch game.family {
        case .oneHand:
            guard let target = game.activeTargetNotes.first else { return "한손" }
            return target.clef == .treble ? "한손 · 높은음자리표" : "한손 · 낮은음자리표"
        case .twoHand:
            return "양손 · 큰보표"
        case .chord:
            guard let target = game.activeTargetNotes.first else { return "화음" }
            let clef = target.clef == .treble ? "높은음자리표" : "낮은음자리표"
            return "\(game.chordSize.label) 화음 · \(clef)"
        }
    }

    private func feedbackColor(_ s: String) -> Color {
        switch s {
        case "MISS": return .red
        case "PERFECT": return .purple
        case "GREAT": return .blue
        case "GOOD": return .green
        default: return AppTheme.muted
        }
    }
}

struct HUDItem: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.muted)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.ink)
        }
        .frame(minWidth: 58)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        }
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
    let layout: String
    let clef: String
    let groups: [[Item]]
    let single: Bool
}

struct NotationWebView: UIViewRepresentable {
    let groups: [[QuestionNote]]
    let activeIndex: Int
    let layout: String
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
        let firstClef = groups.first?.first?.clef.rawValue ?? "treble"
        let encodedGroups = groups.enumerated().map { groupIndex, group in
            let state: String
            if isSingle { state = "current" }
            else if groupIndex < activeIndex { state = "done" }
            else if groupIndex == activeIndex { state = "current" }
            else { state = "future" }
            return group.map { note in
                NotationPayload.Item(key: note.vexKey, clef: note.clef.rawValue, accidental: note.accidental, state: state)
            }
        }
        return NotationPayload(layout: layout, clef: firstClef, groups: encodedGroups, single: isSingle)
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

// MARK: - Multi-touch piano keyboard (양손/화음 전용)

struct MultiTouchPianoKeyboardView: UIViewRepresentable {
    let range: ClosedRange<Int>
    let externalPressed: Set<Int>
    let onPress: (Int) -> Void

    func makeUIView(context: Context) -> MultiTouchKeyboardUIView {
        let view = MultiTouchKeyboardUIView()
        view.noteRange = range
        view.onPress = onPress
        return view
    }

    func updateUIView(_ uiView: MultiTouchKeyboardUIView, context: Context) {
        uiView.noteRange = range
        uiView.externalPressed = externalPressed
        uiView.onPress = onPress
        uiView.setNeedsDisplay()
    }
}

final class MultiTouchKeyboardUIView: UIView {
    var noteRange: ClosedRange<Int> = 36...84 { didSet { setNeedsDisplay() } }
    var externalPressed: Set<Int> = [] { didSet { setNeedsDisplay() } }
    var onPress: ((Int) -> Void)?

    private var touchNotes: [ObjectIdentifier: Int] = [:]
    private let blackPC: Set<Int> = [1,3,6,8,10]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        layer.cornerRadius = 8
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        isOpaque = false
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let whites = whiteNotes
        guard !whites.isEmpty else { return }
        let whiteWidth = bounds.width / CGFloat(whites.count)
        let pressed = externalPressed.union(Set(touchNotes.values))

        for (index, midi) in whites.enumerated() {
            let keyRect = CGRect(x: CGFloat(index) * whiteWidth, y: 0, width: whiteWidth, height: bounds.height)
            ctx.setFillColor((pressed.contains(midi) ? UIColor.systemGray5 : UIColor.white).cgColor)
            ctx.fill(keyRect)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(0.6)
            ctx.stroke(keyRect)
        }

        for midi in noteRange where blackPC.contains(midi % 12) {
            guard let leftIndex = whiteIndexBefore(midi, whites: whites) else { continue }
            let x = CGFloat(leftIndex + 1) * whiteWidth - whiteWidth * 0.31
            let keyRect = CGRect(x: x, y: 0, width: whiteWidth * 0.62, height: bounds.height * 0.62)
            ctx.setFillColor((pressed.contains(midi) ? UIColor.systemGray : UIColor.black).cgColor)
            ctx.fill(keyRect)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor.secondaryLabel
        ]
        for midi in noteRange where midi % 12 == 0 && isWhite(midi) {
            guard let idx = whites.firstIndex(of: midi) else { continue }
            let text = "C\(midi / 12 - 1)" as NSString
            let size = text.size(withAttributes: attrs)
            let x = (CGFloat(idx) + 0.5) * whiteWidth - size.width / 2
            text.draw(at: CGPoint(x: x, y: bounds.height - size.height - 5), withAttributes: attrs)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateTouches(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateTouches(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { touchNotes.removeValue(forKey: ObjectIdentifier(touch)) }
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func updateTouches(_ touches: Set<UITouch>) {
        let whites = whiteNotes
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let midi = midiAt(location: touch.location(in: self), whites: whites) else { continue }
            if touchNotes[id] != midi {
                touchNotes[id] = midi
                onPress?(midi)
            }
        }
        setNeedsDisplay()
    }

    private var whiteNotes: [Int] { noteRange.filter { isWhite($0) } }
    private func isWhite(_ midi: Int) -> Bool { !blackPC.contains(midi % 12) }

    private func whiteIndexBefore(_ midi: Int, whites: [Int]) -> Int? {
        whites.lastIndex(where: { $0 < midi })
    }

    private func midiAt(location: CGPoint, whites: [Int]) -> Int? {
        guard location.x >= 0, location.y >= 0, location.x < bounds.width, location.y < bounds.height, !whites.isEmpty else { return nil }
        let whiteWidth = bounds.width / CGFloat(whites.count)
        if location.y <= bounds.height * 0.62 {
            for midi in noteRange where blackPC.contains(midi % 12) {
                guard let leftIndex = whiteIndexBefore(midi, whites: whites) else { continue }
                let left = CGFloat(leftIndex + 1) * whiteWidth - whiteWidth * 0.31
                let right = left + whiteWidth * 0.62
                if location.x >= left && location.x < right { return midi }
            }
        }
        let index = min(whites.count - 1, max(0, Int(location.x / whiteWidth)))
        return whites[index]
    }
}

// MARK: - Result

struct ResultView: View {
    @EnvironmentObject var game: GameModel
    let result: ResultStats

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("연습 완료")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
                Text(result.rank)
                    .font(.system(size: 116, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                Text(rankMessage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("기록을 확인하고 같은 설정으로 다시 연습하거나\n새로운 훈련을 선택할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.muted)
                    .lineSpacing(4)

                Spacer()

                HStack(spacing: 10) {
                    Button(action: game.start) {
                        Text("다시 연습")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: game.quit) {
                        Text("설정으로")
                            .font(.headline)
                            .foregroundStyle(AppTheme.ink)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(AppTheme.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 380)
            .padding(44)

            VStack(alignment: .leading, spacing: 18) {
                Text("이번 연습 기록")
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.ink)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ResultCell(icon: "sum", label: "점수", value: "\(result.score)")
                    ResultCell(icon: "scope", label: "정확도", value: String(format: "%.1f%%", result.accuracy))
                    ResultCell(icon: "timer", label: "평균 반응", value: String(format: "%.2fs", result.average))
                    ResultCell(icon: "flame", label: "최대 콤보", value: "\(result.maxCombo)")
                }
            }
            .padding(28)
            .background(.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.045), radius: 24, y: 10)
            .frame(maxWidth: 620)
            .padding(.trailing, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rankMessage: String {
        switch result.rank {
        case "S": return "아주 안정적인 초견이었어요."
        case "A": return "좋은 흐름을 유지했어요."
        case "B": return "조금만 더 빠르게 읽어보세요."
        default: return "정확도를 먼저 끌어올려보세요."
        }
    }
}

struct ResultCell: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                Spacer()
                Text(label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.muted)
            }
            Text(value)
                .font(.system(size: 29, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppTheme.ink)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(AppTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}
