import SwiftUI
import CoreMIDI
import AVFoundation
import UIKit

@main struct SightReadingTrainerApp: App {
    @StateObject var game = Game()
    @StateObject var midi = MIDI()
    var body: some Scene {
        WindowGroup {
            Root().environmentObject(game).environmentObject(midi)
                .onAppear { midi.noteOn = { n in game.input(n, playAppSound: false) } }
        }
    }
}

enum Mode:String,CaseIterable,Identifiable { case single="단음 연습", seq="4음 연속"; var id:String{rawValue} }
enum ClefOpt:String,CaseIterable,Identifiable { case treble="높은음자리표", bass="낮은음자리표", both="둘 다"; var id:String{rawValue} }
enum Level:String,CaseIterable,Identifiable { case intro="입문", normal="기본", full="전체"; var id:String{rawValue} }
enum Clef { case treble,bass }
enum Acc:Int { case flat = -1, natural = 0, sharp = 1 }

struct Note:Identifiable,Equatable {
    let id=UUID(); let letter:Int; let octave:Int; let acc:Acc; let clef:Clef
    var natural:Int { (octave+1)*12 + [0,2,4,5,7,9,11][letter] }
    var midi:Int { natural+acc.rawValue }
    var diatonic:Int { octave*7+letter }
}

@MainActor final class Game:ObservableObject {
    @Published var mode:Mode = .single
    @Published var clefOpt:ClefOpt = .both
    @Published var level:Level = .normal
    @Published var keyboard=true
    @Published var sound=true
    @Published var running=false
    @Published var result=false
    @Published var settings=false
    @Published var midiTest=false
    @Published var notes:[Note]=[]
    @Published var index=0
    @Published var score=0
    @Published var combo=0
    @Published var maxCombo=0
    @Published var correct=0
    @Published var misses=0
    @Published var feedback=""
    @Published var lastTime:Double?
    @Published var pressed:Int?
    @Published var correctFlash:Int?
    private var times:[Double]=[]
    private var startTime:CFTimeInterval?
    private var locked=false
    private let audio=PianoAudio()
    var goal:Int { mode == .single ? 30:40 }
    var progress:Int { correct }
    var accuracy:Double { correct+misses == 0 ? 100 : Double(correct)/Double(correct+misses)*100 }
    var avg:Double { times.isEmpty ? 0:times.reduce(0,+)/Double(times.count) }

    func start() {
        score=0;combo=0;maxCombo=0;correct=0;misses=0;times=[];feedback="";lastTime=nil;result=false
        running=true;locked=false; UIApplication.shared.isIdleTimerDisabled=true; next()
    }
    func stop() { running=false;result=false;UIApplication.shared.isIdleTimerDisabled=false }
    func input(_ midi:Int, playAppSound:Bool = true) {
        pressed=midi
        DispatchQueue.main.asyncAfter(deadline:.now()+0.16){ if self.pressed==midi { self.pressed=nil } }
        if sound && playAppSound { audio.play(midi:midi) }
        guard running,!locked,index<notes.count,let st=startTime else { return }
        let target=notes[index]
        if midi != target.midi {
            misses += 1; combo=0; feedback="MISS"; return
        }
        locked=true
        let t=CACurrentMediaTime()-st; times.append(t);lastTime=t;correct += 1;combo += 1;maxCombo=max(maxCombo,combo)
        let base:Int
        if t <= 0.8 { feedback="PERFECT";base=100 }
        else if t <= 1.5 { feedback="GREAT";base=80 }
        else if t <= 2.5 { feedback="GOOD";base=60 }
        else { feedback="OK";base=40 }
        score += base + min(50,max(0,combo-1)*2);correctFlash=midi
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {
            self.correctFlash=nil
            if self.correct >= self.goal { self.running=false;self.result=true;UIApplication.shared.isIdleTimerDisabled=false }
            else if self.mode == .seq && self.index < 3 { self.index += 1;self.locked=false;self.arm() }
            else { self.next() }
        }
    }
    func rank()->String {
        if mode == .single && accuracy>=97 && avg<=1.1 && score>=2900{return"S"}
        if mode == .seq && accuracy>=97 && avg<=1.1{return"S"}
        if accuracy>=90 && avg<=1.8{return"A"}; if accuracy>=80{return"B"};return"C"
    }
    private func arm(){ startTime=nil;DispatchQueue.main.async{DispatchQueue.main.async{self.startTime=CACurrentMediaTime()}}}
    private func next(){
        locked=false;index=0
        if mode == .single { notes=[random()] } else {
            var a:[Note]=[];var last:Note?
            while a.count<4 {
                let n=random()
                if let l=last,abs(n.midi-l.midi)>12 {continue}
                a.append(n);last=n
            };notes=a
        };arm()
    }
    private func random()->Note {
        while true {
            let oct:Int
            switch level { case .intro: oct=Int.random(in:3...5);case .normal:oct=Int.random(in:2...5);case .full:oct=Int.random(in:2...6) }
            let letter=Int.random(in:0...6)
            var temp=Note(letter:letter,octave:oct,acc:.natural,clef:.treble)
            if !(36...84).contains(temp.natural){continue}
            let clef:Clef
            switch clefOpt { case .treble:clef = .treble;case .bass:clef = .bass;case .both:clef=temp.natural<60 ? .bass:.treble }
            if level == .intro {
                let idx=temp.diatonic
                let lo=clef == .treble ? 28:16, hi=clef == .treble ? 38:28
                if idx<lo || idx>hi {continue}
            }
            var acc:Acc = .natural
            if level != .intro && Int.random(in:0..<100)<25 {acc=Bool.random() ? .sharp:.flat}
            temp=Note(letter:letter,octave:oct,acc:acc,clef:clef)
            if (36...84).contains(temp.midi){return temp}
        }
    }
}

final class PianoAudio {
    private struct Anchor {
        let midi:Int
        let file:String
    }

    // Real Yamaha C5 recordings from Salamander Grand Piano V3.
    // Nine anchor samples cover C2...C6; AVAudioPlayer rate-shifts only a few semitones
    // to reach the in-between keys.
    private let anchors:[Anchor] = [
        .init(midi:36,file:"C2v4"),
        .init(midi:45,file:"A2v4"),
        .init(midi:48,file:"C3v4"),
        .init(midi:57,file:"A3v4"),
        .init(midi:60,file:"C4v4"),
        .init(midi:69,file:"A4v4"),
        .init(midi:72,file:"C5v4"),
        .init(midi:81,file:"A5v4"),
        .init(midi:84,file:"C6v4")
    ]

    private var active:[AVAudioPlayer] = []

    init() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode:.default, options:[.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error:", error)
        }
    }

    func play(midi:Int) {
        guard let anchor = anchors.min(by:{ abs($0.midi-midi) < abs($1.midi-midi) }),
              let url = Bundle.main.url(forResource:anchor.file, withExtension:"mp3") else {
            print("Missing bundled piano sample for MIDI", midi)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf:url)
            player.enableRate = true
            player.rate = Float(pow(2.0, Double(midi-anchor.midi)/12.0))
            player.volume = 0.95
            player.prepareToPlay()
            player.play()
            active.append(player)

            // Keep simultaneous/rapid notes alive, then release finished players.
            DispatchQueue.main.asyncAfter(deadline:.now()+1.6) { [weak self, weak player] in
                guard let self else { return }
                self.active.removeAll { p in
                    p === player || !p.isPlaying
                }
            }
        } catch {
            print("Piano sample playback error:", error)
        }
    }
}

final class MIDI:ObservableObject {
    @Published var sources:[String]=[]
    @Published var last:String="아직 입력 없음"
    var noteOn:((Int)->Void)?
    private var client=MIDIClientRef(),port=MIDIPortRef()
    init(){
        MIDIClientCreateWithBlock("Trainer" as CFString,&client){[weak self] _ in self?.refresh()}
        MIDIInputPortCreateWithBlock(client,"Input" as CFString,&port){[weak self] list,_ in self?.read(list)}
        refresh()
    }
    func refresh(){
        var names:[String]=[]
        for i in 0..<MIDIGetNumberOfSources(){
            let s=MIDIGetSource(i);MIDIPortConnectSource(port,s,nil)
            var n:Unmanaged<CFString>?; MIDIObjectGetStringProperty(s,kMIDIPropertyDisplayName,&n)
            names.append((n?.takeRetainedValue() as String?) ?? "MIDI 입력 \(i+1)")
        };DispatchQueue.main.async{self.sources=names}
    }
    private func read(_ list:UnsafePointer<MIDIPacketList>){
        var p=list.pointee.packet
        for _ in 0..<list.pointee.numPackets {
            withUnsafeBytes(of:p.data){raw in
                let b=Array(raw.prefix(Int(p.length)));var i=0
                while i+2<b.count {
                    let st=b[i]
                    if st&0xF0 == 0x90 && b[i+2]>0 {
                        let n=Int(b[i+1]);DispatchQueue.main.async{self.last="MIDI \(n)";self.noteOn?(n)}
                    }
                    i += (st&0xF0 == 0xC0 || st&0xF0 == 0xD0) ? 2:3
                }
            };p=MIDIPacketNext(&p).pointee
        }
    }
}

struct Root:View {
    @EnvironmentObject var g:Game
    var body:some View {
        ZStack {
            Color(red:0.96,green:0.965,blue:0.975).ignoresSafeArea()
            if g.running { Practice() } else { Home() }
            if g.result { ResultView() }
            if g.settings { SettingsView() }
            if g.midiTest { MidiTestView() }
        }.preferredColorScheme(.light)
    }
}

struct Home:View {
    @EnvironmentObject var g:Game;@EnvironmentObject var midi:MIDI
    var body:some View {
        HStack(spacing:42) {
            VStack(alignment:.leading,spacing:14) {
                Text("초견 트레이너").font(.system(size:46,weight:.black,design:.rounded))
                Text("악보를 보는 순간, 정확한 건반으로.")
                    .font(.title3.weight(.medium)).foregroundStyle(.secondary)
                Spacer().frame(height:12)
                Status(text:midi.sources.isEmpty ? "MIDI 피아노 연결 대기":"MIDI 연결됨 · \(midi.sources.first!)",on:!midi.sources.isEmpty)
                Spacer()
                Button("MIDI 테스트"){g.midiTest=true}.buttonStyle(.bordered)
            }.frame(maxWidth:360,alignment:.leading)

            VStack(spacing:18) {
                Card("연습 모드") {
                    Picker("",selection:$g.mode){ForEach(Mode.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                }
                Card("음자리표") {
                    Picker("",selection:$g.clefOpt){ForEach(ClefOpt.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                }
                Card("난이도") {
                    Picker("",selection:$g.level){ForEach(Level.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented)
                }
                Button("연습 시작"){g.start()}
                    .font(.title2.bold()).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth:.infinity)
                Button("설정"){g.settings=true}.font(.headline)
            }.frame(maxWidth:560)
        }.padding(42).foregroundStyle(.black)
    }
}
struct Card<C:View>:View {
    let title:String;let content:C
    init(_ t:String,@ViewBuilder content:()->C){title=t;self.content=content()}
    var body:some View{VStack(alignment:.leading,spacing:10){Text(title).font(.headline);content}.padding(16).background(.white).clipShape(RoundedRectangle(cornerRadius:16))}
}
struct Status:View {let text:String;let on:Bool;var body:some View{HStack{Circle().fill(on ? .green:.gray).frame(width:10,height:10);Text(text).font(.subheadline.bold())}}}

struct Practice:View {
    @EnvironmentObject var g:Game;@EnvironmentObject var midi:MIDI
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:20) {
                Metric("SCORE","\(g.score)");Metric("COMBO","×\(g.combo)");Metric("진행","\(g.progress)/\(g.goal)")
                Metric("정확도",String(format:"%.0f%%",g.accuracy));Metric("평균",g.avg==0 ? "—":String(format:"%.2fs",g.avg))
                Spacer();Status(text:midi.sources.isEmpty ? "MIDI 대기":"MIDI 연결",on:!midi.sources.isEmpty)
                Button("끝내기"){g.stop()}.buttonStyle(.bordered)
            }.padding(.horizontal,18).padding(.vertical,9).background(.white)
            ScoreView(notes:g.notes,focus:g.index).padding(.horizontal,18).padding(.top,12)
            HStack(spacing:14){
                Text(g.feedback).font(.system(size:22,weight:.black,design:.rounded))
                if let t=g.lastTime{Text(String(format:"%.2fs",t)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)}
            }.frame(height:38)
            if g.keyboard {
                Keyboard(pressed:g.pressed,correct:g.correctFlash,onPress:{g.input($0, playAppSound: true)})
                    .frame(height:190).padding(.horizontal,12).padding(.bottom,10)
            } else {Spacer()}
        }.foregroundStyle(.black)
    }
}
struct Metric:View {let a:String,b:String;init(_ a:String,_ b:String){self.a=a;self.b=b};var body:some View{VStack(spacing:1){Text(a).font(.caption.bold()).foregroundStyle(.secondary);Text(b).font(.headline.monospacedDigit())}}}

struct ScoreView:View {
    let notes:[Note];let focus:Int
    var body:some View {
        GeometryReader { geo in
            Canvas { c,s in
                guard !notes.isEmpty else{return}
                let clef=notes[min(focus,notes.count-1)].clef
                let sp:CGFloat=25,cy=s.height*0.53,left:CGFloat=105,right=s.width-45
                for i in -2...2 {var p=Path();let y=cy+CGFloat(i)*sp;p.move(to:.init(x:left,y:y));p.addLine(to:.init(x:right,y:y));c.stroke(p,with:.color(.black),lineWidth:1.4)}
                clefSymbol(&c,clef:clef,x:left+36,cy:cy,sp:sp)
                let xs = notes.count==1 ? [s.width*0.60] : (0..<notes.count).map{s.width*0.42+CGFloat($0)*s.width*0.12}
                for (i,n) in notes.enumerated(){drawNote(&c,n:n,x:xs[i],cy:cy,sp:sp,active:i==focus,done:i<focus)}
            }
        }.background(.white).clipShape(RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).stroke(.black.opacity(0.08))).frame(minHeight:300)
    }
    func clefSymbol(_ c:inout GraphicsContext,clef:Clef,x:CGFloat,cy:CGFloat,sp:CGFloat){
        // Deliberately clean custom marks rather than unsupported Unicode glyphs.
        if clef == .treble {
            var p=Path()
            p.move(to:.init(x:x+2,y:cy+54));p.addCurve(to:.init(x:x+2,y:cy-55),control1:.init(x:x-25,y:cy+18),control2:.init(x:x+25,y:cy-22))
            c.stroke(p,with:.color(.black),lineWidth:4)
            var ring=Path();ring.addEllipse(in:.init(x:x-21,y:cy-20,width:42,height:40));c.stroke(ring,with:.color(.black),lineWidth:4)
            var upper=Path();upper.addEllipse(in:.init(x:x-12,y:cy-60,width:24,height:34));c.stroke(upper,with:.color(.black),lineWidth:4)
        } else {
            c.fill(Path(ellipseIn:.init(x:x-17,y:cy-25,width:28,height:28)),with:.color(.black))
            var arc=Path();arc.addArc(center:.init(x:x-2,y:cy-8),radius:30,startAngle:.degrees(-75),endAngle:.degrees(80),clockwise:false);c.stroke(arc,with:.color(.black),lineWidth:4)
            c.fill(Path(ellipseIn:.init(x:x+28,y:cy-22,width:7,height:7)),with:.color(.black));c.fill(Path(ellipseIn:.init(x:x+28,y:cy+1,width:7,height:7)),with:.color(.black))
        }
    }
    func drawNote(_ c:inout GraphicsContext,n:Note,x:CGFloat,cy:CGFloat,sp:CGFloat,active:Bool,done:Bool){
        let mid=n.clef == .treble ? 34:24 // B4 / D3-ish visual center
        let delta=n.diatonic-mid,y=cy-CGFloat(delta)*sp/2
        let col:Color = done ? .gray.opacity(0.35):.black
        let bottom=n.clef == .treble ? 30:18,top=n.clef == .treble ? 38:26
        if n.diatonic<bottom {var k=bottom-2;while k>=n.diatonic{ledger(&c,k:k,mid:mid,x:x,cy:cy,sp:sp,col:col);k-=2}}
        if n.diatonic>top {var k=top+2;while k<=n.diatonic{ledger(&c,k:k,mid:mid,x:x,cy:cy,sp:sp,col:col);k+=2}}
        c.fill(Path(ellipseIn:.init(x:x-13,y:y-8,width:26,height:16)),with:.color(col))
        var stem=Path();if delta<0{stem.move(to:.init(x:x+11,y:y));stem.addLine(to:.init(x:x+11,y:y-56))}else{stem.move(to:.init(x:x-11,y:y));stem.addLine(to:.init(x:x-11,y:y+56))};c.stroke(stem,with:.color(col),lineWidth:2)
        if n.acc != .natural {
            let sym=n.acc == .sharp ? "♯":"♭"
            c.draw(Text(sym).font(.system(size:38)).foregroundColor(col),at:.init(x:x-38,y:y),anchor:.center)
        }
        if active {c.stroke(Path(ellipseIn:.init(x:x-20,y:y-15,width:40,height:30)),with:.color(.blue.opacity(0.20)),lineWidth:2)}
    }
    func ledger(_ c:inout GraphicsContext,k:Int,mid:Int,x:CGFloat,cy:CGFloat,sp:CGFloat,col:Color){let y=cy-CGFloat(k-mid)*sp/2;var p=Path();p.move(to:.init(x:x-23,y:y));p.addLine(to:.init(x:x+23,y:y));c.stroke(p,with:.color(col),lineWidth:1.5)}
}

struct Keyboard:View {
    let pressed:Int?;let correct:Int?;let onPress:(Int)->Void
    let blacks=Set([1,3,6,8,10])
    var body:some View {
        GeometryReader { geo in
            let whites=Array(36...84).filter{!blacks.contains($0%12)}, w=geo.size.width/CGFloat(whites.count)
            ZStack(alignment:.topLeading) {
                ForEach(Array(whites.enumerated()),id:\.element){i,n in
                    Key(n:n,black:false,pressed:pressed==n,correct:correct==n,onPress:onPress)
                        .frame(width:w,height:geo.size.height).position(x:CGFloat(i)*w+w/2,y:geo.size.height/2)
                }
                ForEach(Array(36...84),id:\.self){n in
                    if blacks.contains(n%12),let i=whites.lastIndex(where:{$0<n}){
                        Key(n:n,black:true,pressed:pressed==n,correct:correct==n,onPress:onPress)
                            .frame(width:w*0.68,height:geo.size.height*0.62).position(x:CGFloat(i+1)*w,y:geo.size.height*0.31).zIndex(5)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(.black.opacity(0.45)))
        }
    }
}
struct Key:View {
    let n:Int,black:Bool,pressed:Bool,correct:Bool,onPress:(Int)->Void
    @State private var down=false
    var body:some View {
        ZStack(alignment:.bottom) {
            RoundedRectangle(cornerRadius:black ? 3:1)
                .fill(correct ? Color.green.opacity(0.75) : (pressed||down ? Color.blue.opacity(0.65) : (black ? Color.black:Color.white)))
            RoundedRectangle(cornerRadius:black ? 3:1).stroke(.black.opacity(0.55),lineWidth:0.7)
            if !black && n==60 {Text("C4").font(.caption2.bold()).foregroundStyle(.gray).padding(.bottom,6)}
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged{_ in if !down{down=true;onPress(n)}}.onEnded{_ in down=false})
    }
}

struct SettingsView:View {
    @EnvironmentObject var g:Game
    var body:some View {Overlay{
        VStack(alignment:.leading,spacing:20){
            HStack{Text("설정").font(.largeTitle.bold());Spacer();Button("완료"){g.settings=false}}
            Toggle("화면 건반 표시",isOn:$g.keyboard)
            Toggle("화면 건반 소리",isOn:$g.sound)
            Text("실제 MIDI 피아노에서는 피아노 자체 소리를 사용하면 됩니다.").font(.footnote).foregroundStyle(.secondary)
        }.frame(width:500)
    }}
}
struct MidiTestView:View {
    @EnvironmentObject var g:Game;@EnvironmentObject var midi:MIDI
    var body:some View {Overlay{
        VStack(spacing:18){
            HStack{Text("MIDI 테스트").font(.largeTitle.bold());Spacer();Button("완료"){g.midiTest=false}}
            Status(text:midi.sources.isEmpty ? "연결된 MIDI 장치 없음":midi.sources.joined(separator:", "),on:!midi.sources.isEmpty)
            Text(midi.last).font(.system(size:34,weight:.bold,design:.monospaced))
            Text("피아노 건반을 누르면 MIDI 번호가 표시됩니다.").foregroundStyle(.secondary)
        }.frame(width:540)
    }}
}
struct ResultView:View {
    @EnvironmentObject var g:Game
    var body:some View {Overlay{
        VStack(spacing:18){
            Text(g.rank()).font(.system(size:76,weight:.black,design:.rounded))
            Text("연습 완료").font(.title.bold())
            HStack(spacing:30){Metric("SCORE","\(g.score)");Metric("정확도",String(format:"%.1f%%",g.accuracy));Metric("평균",String(format:"%.2fs",g.avg));Metric("MAX COMBO","×\(g.maxCombo)")}
            HStack{Button("다시 연습"){g.start()}.buttonStyle(.borderedProminent);Button("처음으로"){g.stop()}.buttonStyle(.bordered)}
        }
    }}
}
struct Overlay<C:View>:View {
    let content:C;init(@ViewBuilder _ c:()->C){content=c()}
    var body:some View{ZStack{Color.black.opacity(0.35).ignoresSafeArea();content.padding(30).background(.white).clipShape(RoundedRectangle(cornerRadius:24)).shadow(radius:18)}.foregroundStyle(.black)}
}
