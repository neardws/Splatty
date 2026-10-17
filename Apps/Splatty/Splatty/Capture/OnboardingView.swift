import SwiftUI

/// First-run tips (Chinese), shown over the camera before the first capture.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "square.grid.3x3.fill", title: "放好物体",
             body: "把物体放在有花纹的桌面或垫布上（不要纯白、不要反光），周围留出能绕着走的空间。"),
        Page(symbol: "lightbulb.max", title: "光线柔和",
             body: "室内均匀的灯光最好。避开强烈直射的阳光和明显反光，不要开闪光灯。"),
        Page(symbol: "figure.walk.circle", title: "慢慢绕一圈",
             body: "先轻点物体中心。然后跟着箭头慢慢绕着走，手机会自动拍，每拍一张轻震一下。一共 3 圈、40 多张，大约 2 分钟。"),
    ]

    var body: some View {
        VStack(spacing: 20) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 18) {
                        Image(systemName: pages[i].symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: page)
                        Text(pages[i].title).font(.title.bold())
                        Text(pages[i].body)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 340)

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "下一步" : "开始拍摄")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 32)

            Button("跳过", action: onFinish).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(20)
    }
}
