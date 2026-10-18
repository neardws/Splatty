@preconcurrency import AVFoundation
import SplattyCore

/// Spoken Chinese prompts (zh-CN) so the user doesn't need to look at the screen.
@MainActor
final class VoiceCoach {
    private let synth = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "zh-CN")
    var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        // .playback so prompts are audible with the silent switch on; duck music instead of stopping it.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
    }

    func say(_ text: String, interrupt: Bool = false) {
        guard enabled, !text.isEmpty else { return }
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if synth.isSpeaking { return } // never queue up stale prompts
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func text(_ cue: CoachCue) -> String {
        switch cue {
        case .start(.eye): "开始。手机别动，慢慢转物体，转一点停一下"
        case .start(.high): "抬高手机，开始下一圈"
        case .start(.top): "把手机举到物体正上方，往下拍"
        case .keepTurning: "继续慢慢转"
        case .holdStill: "停一下"
        case .tooFast: "太快了，慢一点"
        case .phoneMoving: "手机别动，转物体就行"
        case .raisePhone: "把手机抬高一点"
        case .lowerPhone: "把手机放低一点"
        case .objectOutOfView: "物体跑出画面了，对准物体"
        case .tooDark: "太暗了，开个灯"
        case .ringDone(next: .high): "这一圈拍完了。抬高手机，开始下一圈"
        case .ringDone(next: .top): "这一圈拍完了。把手机举到正上方往下拍，每拍一张，把物体转三分之一圈"
        case .ringDone(next: .eye): "这一圈拍完了"
        case .allDone(let n): "可以了！共 \(n) 张"
        case .switchedToSimpleMode: "看不清转了多少，改成转一点、停一下，自动拍"
        }
    }
}
