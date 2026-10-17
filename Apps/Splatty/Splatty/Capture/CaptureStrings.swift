import SplattyCore

/// Chinese UI strings for the guided capture flow.
enum CaptureStrings {
    static func ringName(_ r: ElevationRing) -> String {
        switch r {
        case .low: "低位"
        case .mid: "中位"
        case .high: "高位"
        }
    }

    /// How to hold the phone for a ring.
    static func ringHowTo(_ r: ElevationRing) -> String {
        switch r {
        case .mid: "手机比物体略高，稍微往下看"
        case .high: "手机举高，从上往下俯拍"
        case .low: "手机放低，几乎和物体平视"
        }
    }

    /// Prompt shown when a ring has just been completed and `next` is the next ring.
    static func nextRingPrompt(_ next: ElevationRing) -> String {
        switch next {
        case .high: "把手机抬高，从上往下再绕一圈"
        case .low: "把手机放低，贴近桌面再绕一圈"
        case .mid: "回到中间高度再绕一圈"
        }
    }

    static func presetName(_ p: CapturePlan.Preset) -> String {
        switch p {
        case .quick: "快速"
        case .standard: "标准"
        case .detailed: "精细"
        }
    }

    static func presetLabel(_ p: CapturePlan.Preset) -> String {
        let plan = CapturePlan.preset(p)
        return "\(presetName(p))（约 \(plan.targetShots()) 张）"
    }

    static func turntablePresetLabel(_ p: CapturePlan.Preset) -> String {
        "\(presetName(p))（约 \(TurntablePlan.preset(p).targetShots()) 张）"
    }

    static func warning(_ w: CaptureWarning) -> String {
        switch w {
        case .trackingLimited(let reason): trackingReason(reason)
        case .tooDark: "太暗了，开灯或补点光"
        case .movingTooFast: "太快了，慢一点"
        case .notAimedAtObject: "把物体放回画面中间"
        case .tooClose: "太近了，往后退一点"
        case .tooFar: "太远了，靠近一点"
        }
    }

    static func trackingReason(_ reason: String) -> String {
        switch reason {
        case "initializing": "正在初始化，左右慢慢晃一下手机"
        case "excessive motion": "移动太快，跟踪丢了，慢一点"
        case "low texture": "画面缺少纹理，换个有花纹的桌面或垫布"
        case "relocalizing": "正在重新定位，回到刚才的位置"
        case "not available": "跟踪不可用"
        default: "跟踪不稳定"
        }
    }
}
