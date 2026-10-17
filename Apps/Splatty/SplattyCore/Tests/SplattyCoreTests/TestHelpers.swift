@testable import SplattyCore

/// Camera on a circle of `radius` at azimuth/elevation (deg) around `center`, looking at it.
func orbitPose(azimuth: Double, elevation: Double, radius: Double = 0.3, center: Vec3 = .zero) -> Mat4 {
    let az = azimuth * .pi / 180, el = elevation * .pi / 180
    // Camera +Z (back) points from the anchor to the camera.
    let r = Mat4.matmul3(Mat4.rotationY(az), Mat4.rotationX(-el))
    let back = Vec3(r[0][2], r[1][2], r[2][2])
    return Mat4.rigid(rotation: r, translation: center + back * radius)
}
