
import SwiftUI
import CoreMIDI

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

enum ClefChoice: String, CaseIterable, Identifiable {
    case both = "둘 다"
    case treble = "높은음자리표"
    case bass = "낮은음자리표"
    var id: String { rawValue }
}
enum ClefKind { case treble, bass }
enum Accidental: Int {
    case flat = -1, natural = 0, sharp = 1
    var symbol: String { self == .flat ? "♭" : self == .sharp ? "♯" : "" }
}
enum TrainingMode: String, CaseIterable, Identifiable {
    case single = "단음"
    case sequence = "4음 연속"
    var id: String { rawValue }
}
struct QuizNote: Equatable, Identifiable {
    let id = UUID()
    let letter: Int
    let octave: Int
    let accidental: Accidental
    let clef: ClefKind
    var naturalMidi: Int {
        let offsets = [0,2,4,5,7,9,11]
        return (octave + 1) * 12 + offsets[letter]
    }
    var targetMidi: Int { naturalMidi + accidental.rawValue }
    var diatonicIndex: Int { octave * 7 + letter }
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
    @Published var sequenceIndex = 0
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

    private var shownAt: CFTimeInterval?
    private var locked = false
    private var token = UUID()
    private var attempts: [AttemptRecord] = []

    var targetCount: Int { mode == .single ? 30 : 40 }
    var accuracy: Double {
        let total = correct + wrong
        return total == 0 ? 100 : Double(correct) / Double(total) * 100
    }
    var averageTime: Double {
        let c = attempts.filter(\.correct)
        return c.isEmpty ? 0 : c.map(\.time).reduce(0,+)/Double(c.count)
    }

    func start() {
        token = UUID()
        score=0; combo=0; maxCombo=0; correct=0; wrong=0; answered=0
        feedback=""; lastReaction=nil; attempts=[]
        showResult=false; isRunning=true; locked=false
        nextQuestion()
    }
    func handleInput(midi: Int, velocity: Int = 100) {
        guard isRunning, !showSettings, !locked, let q=current, let start=shownAt else { return }
        if midi != q.targetMidi {
            wrong += 1
            combo = 0
            feedback = "MISS"
            attempts.append(.init(note:q,time:CACurrentMediaTime()-start,correct:false))
            return
        }
        locked = true
        shownAt = nil
        let t = CACurrentMediaTime()-start
        lastReaction = t
        let p: Int
        if t <= 0.8 { feedback="PERFECT"; p=100 }
        else if t <= 1.5 { feedback="GREAT"; p=80 }
        else if t <= 2.5 { feedback="GOOD"; p=60 }
        else { feedback="OK"; p=40 }

        correct += 1; answered += 1; combo += 1; maxCombo=max(maxCombo,combo)
        score += p + min(50,max(0,combo-1)*2)
        attempts.append(.init(note:q,time:t,correct:true))

        if answered >= targetCount {
            let tkn=token
            DispatchQueue.main.asyncAfter(deadline:.now()+0.18) { [weak self] in
                guard let self, self.token==tkn else { return }
                self.isRunning=false; self.showResult=true
            }
        } else if mode == .sequence && sequenceIndex < 3 {
            sequenceIndex += 1
            current = sequence[sequenceIndex]
            locked=false
            armTimer()
        } else {
            let tkn=token
            DispatchQueue.main.asyncAfter(deadline:.now()+0.13) { [weak self] in
                guard let self, self.token==tkn else { return }
                self.nextQuestion()
            }
        }
    }
    func rank() -> String {
        if mode == .single && accuracy >= 97 && averageTime <= 1.1 && score >= 2900 { return "S" }
        if mode == .sequence && accuracy >= 97 && averageTime <= 1.1 { return "S" }
        if accuracy >= 90 && averageTime <= 1.8 { return "A" }
        if accuracy >= 80 { return "B" }
        return "C"
    }
    func setSettings(_ visible: Bool) {
        showSettings = visible
        shownAt = nil
        if !visible && isRunning { armTimer() }
    }
    private func armTimer() {
        shownAt=nil
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, !self.showSettings else { return }
                self.shownAt=CACurrentMediaTime()
            }
        }
    }
    private func nextQuestion() {
        locked=false
        if mode == .single {
            sequence=[]
            sequenceIndex=0
            current=randomNote()
        } else {
            sequence=makeSequence()
            sequenceIndex=0
            current=sequence.first
        }
        armTimer()
    }
    private func randomNote() -> QuizNote { makePool().randomElement()! }
    private func makePool() -> [QuizNote] {
        var out:[QuizNote]=[]
        for octave in 2...6 {
            for letter in 0...6 {
                if octave == 6 && letter > 0 { continue }
                let temp=QuizNote(letter:letter,octave:octave,accidental:.natural,clef:.treble)
                guard (36...84).contains(temp.naturalMidi) else { continue }
                let clef:ClefKind = clefChoice == .treble ? .treble :
                    clefChoice == .bass ? .bass :
                    (temp.naturalMidi <= 59 ? .bass : .treble)
                var accidental:Accidental = .natural
                if Int.random(in:0..<100) < 28 {
                    let choices:[Accidental] = [.sharp,.flat].filter { (36...84).contains(temp.naturalMidi + $0.rawValue) }
                    accidental = choices.randomElement() ?? .natural
                }
                out.append(.init(letter:letter,octave:octave,accidental:accidental,clef:clef))
            }
        }
        return out
    }
    private func makeSequence() -> [QuizNote] {
        let pool=makePool()
        let first=pool.randomElement()!
        var out=[first], last=first
        while out.count < 4 {
            let nearby=pool.filter { abs($0.targetMidi-last.targetMidi) <= 12 }
            let n=nearby.randomElement() ?? pool.randomElement()!
            out.append(n); last=n
        }
        return out
    }
}

final class MIDIManager: ObservableObject {
    @Published var connectedSources:[String]=[]
    var onNoteOn:((Int,Int)->Void)?
    private var client=MIDIClientRef()
    private var inputPort=MIDIPortRef()
    private var connected=Set<MIDIEndpointRef>()

    init() {
        MIDIClientCreateWithBlock("SightReadingTrainer" as CFString,&client) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        MIDIInputPortCreateWithBlock(client,"Input" as CFString,&inputPort) { [weak self] packetList,_ in
            self?.handle(packetList)
        }
        refresh()
    }
    func refresh() {
        var names:[String]=[]
        let count=MIDIGetNumberOfSources()
        for i in 0..<count {
            let src=MIDIGetSource(i)
            if !connected.contains(src) {
                MIDIPortConnectSource(inputPort,src,nil)
                connected.insert(src)
            }
            var n:Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(src,kMIDIPropertyDisplayName,&n)==noErr,
               let s=n?.takeRetainedValue() { names.append(s as String) }
            else { names.append("MIDI 입력 \(i+1)") }
        }
        DispatchQueue.main.async { self.connectedSources=names }
    }
    private func handle(_ list:UnsafePointer<MIDIPacketList>) {
        var packet=list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            withUnsafeBytes(of: packet.data) { raw in
                let b=Array(raw.prefix(Int(packet.length)))
                var i=0
                while i+2 < b.count {
                    let status=b[i], type=status & 0xF0
                    if type == 0x90 || type == 0x80 {
                        let note=Int(b[i+1]), vel=Int(b[i+2])
                        if type == 0x90 && vel > 0 {
                            DispatchQueue.main.async { [weak self] in self?.onNoteOn?(note,vel) }
                        }
                        i += 3
                    } else if type == 0xC0 || type == 0xD0 { i += 2 }
                    else if status >= 0xF8 { i += 1 }
                    else { i += 3 }
                }
            }
            packet=MIDIPacketNext(&packet).pointee
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var game:GameModel
    @EnvironmentObject var midi:MIDIManager

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            if game.isRunning { training } else { start }
            if game.showResult { ResultOverlay() }
            if game.showSettings { SettingsOverlay() }
        }
        .preferredColorScheme(.light)
    }

    private var start: some View {
        VStack(spacing:24) {
            Spacer()
            Text("초견 트레이너")
                .font(.system(size:46,weight:.black,design:.rounded))
                .foregroundStyle(.black)
            Text("악보를 보고 실제 피아노에서 최대한 빠르게 찾아보세요.")
                .font(.system(size:20,weight:.medium))
                .foregroundStyle(Color.black.opacity(0.70))
            HStack(spacing:8) {
                Circle().fill(midi.connectedSources.isEmpty ? Color.gray : Color.green).frame(width:10,height:10)
                Text(midi.connectedSources.isEmpty ? "MIDI 피아노 연결 대기" : "MIDI 연결됨")
                    .font(.system(size:17,weight:.semibold))
                    .foregroundStyle(.black)
            }
            Picker("모드",selection:$game.mode) {
                ForEach(TrainingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width:460)
            .colorScheme(.light)

            Button("연습 시작") { game.start() }
                .font(.system(size:24,weight:.bold))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(width:320)

            Button("설정") { game.setSettings(true) }
                .font(.system(size:18,weight:.semibold))
            Spacer()
        }
        .padding(40)
    }

    private var training: some View {
        VStack(spacing:0) {
            HStack(spacing:22) {
                hud("SCORE","\(game.score)")
                hud("COMBO","×\(game.combo)")
                hud("진행","\(game.answered)/\(game.targetCount)")
                hud("정확도",String(format:"%.0f%%",game.accuracy))
                hud("평균",game.averageTime == 0 ? "—" : String(format:"%.2fs",game.averageTime))
                Spacer()
                HStack(spacing:7) {
                    Circle().fill(midi.connectedSources.isEmpty ? Color.gray : Color.green).frame(width:9,height:9)
                    Text(midi.connectedSources.isEmpty ? "MIDI 대기" : "MIDI 연결")
                }
                .font(.system(size:15,weight:.bold))
                .foregroundStyle(.black)
                Button { game.start() } label: { Image(systemName:"arrow.clockwise") }
                    .buttonStyle(.bordered)
                Button { game.setSettings(true) } label: { Image(systemName:"gearshape.fill") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal,18)
            .padding(.vertical,10)
            .background(Color.white)

            VStack(spacing:6) {
                if game.mode == .sequence {
                    StaffCanvas(notes:game.sequence,focus:game.sequenceIndex)
                } else if let q=game.current {
                    StaffCanvas(notes:[q],focus:0)
                }

                HStack(spacing:12) {
                    Text(game.feedback)
                        .font(.system(size:30,weight:.black,design:.rounded))
                        .foregroundStyle(.black)
                        .frame(width:170)
                    if let t=game.lastReaction {
                        Text(String(format:"%.2fs",t))
                            .font(.system(size:22,weight:.bold,design:.monospaced))
                            .foregroundStyle(Color.black.opacity(0.72))
                    }
                }
                .frame(height:38)
            }
            .padding(.horizontal,14)
            .padding(.top,10)

            if game.showKeyboard {
                PianoKeyboardView(range:36...84) { game.handleInput(midi:$0) }
                    .frame(height:190)
                    .padding(.horizontal,10)
                    .padding(.top,6)
                    .padding(.bottom,8)
            } else {
                Spacer()
            }
        }
    }

    private func hud(_ t:String,_ v:String) -> some View {
        VStack(spacing:2) {
            Text(t).font(.system(size:12,weight:.bold)).foregroundStyle(Color.black.opacity(0.58))
            Text(v).font(.system(size:19,weight:.bold,design:.monospaced)).foregroundStyle(.black)
        }
    }
}

struct StaffCanvas: View {
    let notes:[QuizNote]
    let focus:Int
    var body: some View {
        Canvas { context,size in
            guard let first=notes.first else { return }
            let spacing:CGFloat=26
            let staffCenter=size.height*0.54
            let left:CGFloat=92
            let right=size.width-40

            for i in -2...2 {
                let y=staffCenter+CGFloat(i)*spacing
                var p=Path()
                p.move(to:CGPoint(x:left,y:y)); p.addLine(to:CGPoint(x:right,y:y))
                context.stroke(p,with:.color(.black),lineWidth:1.6)
            }

            drawClef(context:&context,kind:first.clef,x:left+28,centerY:staffCenter,spacing:spacing)

            let xs:[CGFloat] = notes.count == 1 ? [size.width*0.62] :
                (0..<notes.count).map { size.width*0.40 + CGFloat($0)*(size.width*0.42)/CGFloat(max(1,notes.count-1)) }

            for (idx,n) in notes.enumerated() {
                drawNote(context:&context,note:n,x:xs[idx],centerY:staffCenter,spacing:spacing,
                         color: idx == focus ? .black : .gray.opacity(0.48))
            }
        }
        .frame(minHeight:240)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius:18))
        .overlay(RoundedRectangle(cornerRadius:18).stroke(Color.black.opacity(0.10),lineWidth:1))
    }

    private func drawClef(context:inout GraphicsContext,kind:ClefKind,x:CGFloat,centerY:CGFloat,spacing:CGFloat) {
        // Vector-ish clefs: deliberately avoid unsupported musical-symbol glyphs.
        if kind == .treble {
            var p=Path()
            p.move(to:CGPoint(x:x+3,y:centerY+58))
            p.addCurve(to:CGPoint(x:x-5,y:centerY-52),control1:CGPoint(x:x-30,y:centerY+20),control2:CGPoint(x:x+36,y:centerY-20))
            p.addCurve(to:CGPoint(x:x+2,y:centerY+22),control1:CGPoint(x:x-28,y:centerY-30),control2:CGPoint(x:x-18,y:centerY+16))
            p.addCurve(to:CGPoint(x:x+22,y:centerY+4),control1:CGPoint(x:x+30,y:centerY+35),control2:CGPoint(x:x+35,y:centerY-6))
            context.stroke(p,with:.color(.black),lineWidth:5)
            context.fill(Path(ellipseIn:CGRect(x:x-5,y:centerY+50,width:16,height:16)),with:.color(.black))
        } else {
            context.fill(Path(ellipseIn:CGRect(x:x-10,y:centerY-28,width:28,height:28)),with:.color(.black))
            var arc=Path()
            arc.addArc(center:CGPoint(x:x+1,y:centerY-7),radius:34,startAngle:.degrees(-70),endAngle:.degrees(80),clockwise:false)
            context.stroke(arc,with:.color(.black),lineWidth:5)
            context.fill(Path(ellipseIn:CGRect(x:x+34,y:centerY-25,width:7,height:7)),with:.color(.black))
            context.fill(Path(ellipseIn:CGRect(x:x+34,y:centerY-3,width:7,height:7)),with:.color(.black))
        }
    }

    private func drawNote(context:inout GraphicsContext,note:QuizNote,x:CGFloat,centerY:CGFloat,spacing:CGFloat,color:Color) {
        let middle = note.clef == .treble ? (4*7+6) : (3*7+3) // B4 / F3
        let delta=note.diatonicIndex-middle
        let y=centerY-CGFloat(delta)*spacing/2
        drawLedgers(context:&context,note:note,x:x,centerY:centerY,spacing:spacing,color:color)

        context.fill(Path(ellipseIn:CGRect(x:x-13,y:y-8,width:26,height:16)),with:.color(color))

        var stem=Path()
        if delta < 0 {
            stem.move(to:CGPoint(x:x+11,y:y))
            stem.addLine(to:CGPoint(x:x+11,y:y-58))
        } else {
            stem.move(to:CGPoint(x:x-11,y:y))
            stem.addLine(to:CGPoint(x:x-11,y:y+58))
        }
        context.stroke(stem,with:.color(color),lineWidth:2.2)

        if note.accidental != .natural {
            context.draw(Text(note.accidental.symbol)
                .font(.system(size:40,weight:.regular))
                .foregroundColor(color),
                         at:CGPoint(x:x-40,y:y),anchor:.center)
        }
    }

    private func drawLedgers(context:inout GraphicsContext,note:QuizNote,x:CGFloat,centerY:CGFloat,spacing:CGFloat,color:Color) {
        let bottom = note.clef == .treble ? (4*7+2) : (2*7+4) // E4 / G2
        let top = note.clef == .treble ? (5*7+3) : (3*7+5)    // F5 / A3
        let idx=note.diatonicIndex

        if idx < bottom {
            var line=bottom-2
            while line >= idx {
                drawLedger(context:&context,index:line,note:note,x:x,centerY:centerY,spacing:spacing,color:color)
                line -= 2
            }
        } else if idx > top {
            var line=top+2
            while line <= idx {
                drawLedger(context:&context,index:line,note:note,x:x,centerY:centerY,spacing:spacing,color:color)
                line += 2
            }
        }
    }
    private func drawLedger(context:inout GraphicsContext,index:Int,note:QuizNote,x:CGFloat,centerY:CGFloat,spacing:CGFloat,color:Color) {
        let middle=note.clef == .treble ? (4*7+6) : (3*7+3)
        let y=centerY-CGFloat(index-middle)*spacing/2
        var p=Path(); p.move(to:CGPoint(x:x-24,y:y)); p.addLine(to:CGPoint(x:x+24,y:y))
        context.stroke(p,with:.color(color),lineWidth:1.7)
    }
}

struct PianoKeyboardView: View {
    let range:ClosedRange<Int>
    let onPress:(Int)->Void
    private let blackSet=Set([1,3,6,8,10])

    var body: some View {
        GeometryReader { geo in
            let whiteNotes=Array(range).filter { !blackSet.contains($0 % 12) }
            let w=geo.size.width/CGFloat(whiteNotes.count)

            ZStack(alignment:.topLeading) {
                ForEach(Array(whiteNotes.enumerated()),id:\.element) { idx,midi in
                    KeyPressArea(midi:midi,onPress:onPress) {
                        ZStack(alignment:.bottom) {
                            Rectangle().fill(Color.white)
                            Rectangle().stroke(Color.black.opacity(0.65),lineWidth:0.8)
                            if midi == 60 {
                                Text("C4").font(.system(size:10,weight:.bold)).foregroundStyle(.black.opacity(0.55)).padding(.bottom,7)
                            }
                        }
                    }
                    .frame(width:w,height:geo.size.height)
                    .position(x:CGFloat(idx)*w+w/2,y:geo.size.height/2)
                }

                ForEach(Array(range),id:\.self) { midi in
                    if blackSet.contains(midi % 12),
                       let lower=whiteNotes.lastIndex(where:{ $0 < midi }) {
                        let center=CGFloat(lower+1)*w
                        KeyPressArea(midi:midi,onPress:onPress) {
                            RoundedRectangle(cornerRadius:3).fill(Color.black)
                        }
                        .frame(width:w*0.68,height:geo.size.height*0.62)
                        .position(x:center,y:geo.size.height*0.31)
                        .zIndex(3)
                    }
                }
            }
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.black.opacity(0.5),lineWidth:1))
        }
    }
}

struct KeyPressArea<Content:View>: View {
    let midi:Int
    let onPress:(Int)->Void
    @ViewBuilder let content:Content
    @State private var pressed=false

    init(midi:Int,onPress:@escaping(Int)->Void,@ViewBuilder content:()->Content) {
        self.midi=midi; self.onPress=onPress; self.content=content()
    }

    var body: some View {
        content
            .scaleEffect(pressed ? 0.985 : 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance:0)
                    .onChanged { _ in
                        if !pressed {
                            pressed=true
                            onPress(midi)
                        }
                    }
                    .onEnded { _ in pressed=false }
            )
    }
}

struct ResultOverlay: View {
    @EnvironmentObject var game:GameModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing:16) {
                Text(game.rank()).font(.system(size:74,weight:.black,design:.rounded)).foregroundStyle(.black)
                Text("연습 완료").font(.system(size:28,weight:.bold)).foregroundStyle(.black)
                HStack(spacing:30) {
                    stat("SCORE","\(game.score)")
                    stat("정확도",String(format:"%.1f%%",game.accuracy))
                    stat("평균",game.averageTime == 0 ? "—" : String(format:"%.2fs",game.averageTime))
                    stat("MAX COMBO","×\(game.maxCombo)")
                }
                HStack {
                    Button("다시 연습"){game.start()}.buttonStyle(.borderedProminent)
                    Button("처음으로"){game.showResult=false;game.isRunning=false}.buttonStyle(.bordered)
                }
            }
            .padding(34)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius:24))
            .shadow(radius:20)
        }
    }
    private func stat(_ t:String,_ v:String)->some View {
        VStack { Text(t).font(.caption.bold()).foregroundStyle(.gray); Text(v).font(.title3.bold()).foregroundStyle(.black) }
    }
}

struct SettingsOverlay: View {
    @EnvironmentObject var game:GameModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(alignment:.leading,spacing:22) {
                HStack {
                    Text("설정").font(.largeTitle.bold()).foregroundStyle(.black)
                    Spacer()
                    Button("완료"){game.setSettings(false)}.font(.headline)
                }
                Text("음자리표").font(.headline).foregroundStyle(.black)
                Picker("음자리표",selection:$game.clefChoice) {
                    ForEach(ClefChoice.allCases){Text($0.rawValue).tag($0)}
                }.pickerStyle(.segmented).colorScheme(.light)
                Toggle("화면 건반 표시",isOn:$game.showKeyboard).foregroundStyle(.black)
                Text("MIDI 피아노가 연결되면 실제 건반 입력도 자동으로 정답 판정에 사용됩니다.")
                    .font(.footnote).foregroundStyle(Color.black.opacity(0.65))
            }
            .padding(28).frame(width:570)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius:24))
            .shadow(radius:20)
        }
    }
}
