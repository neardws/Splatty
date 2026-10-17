@preconcurrency import ARKit
import SplattyCore
import UIKit

extension DeviceInfo {
    @MainActor
    static func current() -> DeviceInfo {
        var sys = utsname()
        uname(&sys)
        let identifier = withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return DeviceInfo(
            model: UIDevice.current.model,
            identifier: identifier,
            systemVersion: UIDevice.current.systemVersion,
            hasLiDAR: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        )
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
