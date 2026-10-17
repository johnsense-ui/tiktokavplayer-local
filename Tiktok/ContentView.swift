import SwiftUI
import AVKit

struct ContentView: View {
    var body: some View {
        Home()
    }
}

// MARK: - 服务器地址

enum FeedConfig {
    static let key = "dzc.serverBase"
    static let fallback = "http://172.29.8.196:6688"

    static var base: String {
        get {
            let v = UserDefaults.standard.string(forKey: key) ?? ""
            return v.isEmpty ? fallback : v
        }
        set {
            var t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasSuffix("/") { t.removeLast() }
            UserDefaults.standard.set(t, forKey: key)
        }
    }
}

// MARK: - 数据

struct FeedEntry: Identifiable {
    let id: Int
    let videoURL: URL
    let author: String
    let caption: String
    let likeCount: Int
}

final class FeedStore: ObservableObject {
    @Published var entries: [FeedEntry] = []
    @Published var errorText: String?
    @Published var isLoading = false

    private var offset = 0
    private var total = Int.max
    private var busy = false
    private let pageSize = 12

    var canLoadMore: Bool { offset < total }

    func reset() {
        entries = []
        offset = 0
        total = Int.max
        busy = false
        errorText = nil
    }

    func loadMore() {
        guard !busy, canLoadMore else { return }
        let base = FeedConfig.base
        guard let url = URL(string: "\(base)/api/videos?limit=\(pageSize)&offset=\(offset)&sort=newest") else {
            errorText = "地址无效：\(base)"
            return
        }
        busy = true
        isLoading = true

        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.busy = false
                self.isLoading = false

                if let err = err {
                    self.errorText = "连不上 \(base)：\(err.localizedDescription)"
                    return
                }
                guard let data = data else {
                    self.errorText = "服务器没返回数据"
                    return
                }

                struct Resp: Decodable { let total: Int; let items: [Item] }
                struct Item: Decodable {
                    let id: Int
                    let title: String?
                    let caption: String?
                    let authorName: String?
                    let digg: Int?
                }
                do {
                    let resp = try JSONDecoder().decode(Resp.self, from: data)
                    self.total = resp.total
                    self.offset += resp.items.count
                    self.entries.append(contentsOf: resp.items.compactMap { item -> FeedEntry? in
                        guard let u = URL(string: "\(base)/api/stream/\(item.id)") else { return nil }
                        let author = (item.authorName?.isEmpty == false ? item.authorName! : "未知作者")
                        let caption = (item.caption?.isEmpty == false ? item.caption! : (item.title ?? ""))
                        return FeedEntry(id: item.id, videoURL: u,
                                         author: author, caption: caption,
                                         likeCount: item.digg ?? 0)
                    })
                    self.errorText = nil
                } catch {
                    self.errorText = "数据格式不对：\(error.localizedDescription)"
                }
            }
        }.resume()
    }
}

// MARK: - 首页

struct Home: View {
    @StateObject private var store = FeedStore()
    @State var index = 0
    @State var top = 0
    @State var data: [Video] = []
    @State var showSettings = false

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            if data.isEmpty {
                emptyState
            } else {
                PlayerScrollView(data: $data)
            }

            VStack {
                // 顶部 Following / For You + 齿轮
                HStack(spacing: 15) {
                    Button(action: { self.top = 0 }) {
                        Text("Following")
                            .foregroundColor(self.top == 0 ? .white : Color.white.opacity(0.45))
                            .fontWeight(self.top == 0 ? .bold : .none)
                            .padding(.vertical)
                    }
                    Button(action: { self.top = 1 }) {
                        Text("For You")
                            .foregroundColor(self.top == 1 ? .white : Color.white.opacity(0.45))
                            .fontWeight(self.top == 1 ? .bold : .none)
                            .padding(.vertical)
                    }
                    Spacer()
                    Button(action: { self.showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 18, weight: .semibold))
                            .padding(.trailing, 4)
                    }
                }
                .padding(.horizontal)

                Spacer()

                // 右侧操作列
                HStack {
                    Spacer()
                    VStack(spacing: 30) {
                        Button(action: {}) {
                            Image("pic")
                                .renderingMode(.original)
                                .resizable()
                                .frame(width: 55, height: 55)
                                .clipShape(Circle())
                        }
                        VStack(spacing: 8) {
                            Image(systemName: "suit.heart.fill")
                                .font(.title)
                                .foregroundColor(Color(red: 0.996, green: 0.173, blue: 0.333))
                            Text(NumberShort.text(currentLikeCount))
                                .foregroundColor(.white)
                                .font(.footnote)
                        }
                        VStack(spacing: 8) {
                            Image(systemName: "message.fill").font(.title).foregroundColor(.white)
                            Text("--").foregroundColor(.white).font(.footnote)
                        }
                        VStack(spacing: 8) {
                            Image(systemName: "arrowshape.turn.up.right.fill").font(.title).foregroundColor(.white)
                            Text("Share").foregroundColor(.white).font(.footnote)
                        }
                    }
                    .padding(.bottom, 55)
                    .padding(.trailing)
                }

                // 文案
                if let entry = currentEntry {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("@" + entry.author)
                                .foregroundColor(.white)
                                .font(.subheadline).bold()
                            Text(entry.caption)
                                .foregroundColor(.white)
                                .font(.footnote)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                bottomBar
            }
            .padding(.top, UIApplication.shared.windows.first?.safeAreaInsets.top)
            .padding(.bottom, (UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0) + 5)
        }
        .edgesIgnoringSafeArea(.all)
        .sheet(isPresented: $showSettings) {
            ServerSettingsView {
                store.reset()
                data = []
                load()
            }
        }
        .onAppear(perform: load)
    }

    private var currentEntry: FeedEntry? {
        guard !store.entries.isEmpty else { return nil }
        return store.entries[min(index, store.entries.count - 1)]
    }

    private var currentLikeCount: Int { currentEntry?.likeCount ?? 0 }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("正在连接 \(FeedConfig.base)")
                    .foregroundColor(.white.opacity(0.6)).font(.footnote)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42)).foregroundColor(.white.opacity(0.7))
                Text(store.errorText ?? "没拿到视频")
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Text(FeedConfig.base)
                    .foregroundColor(.white.opacity(0.5)).font(.caption)
                HStack(spacing: 12) {
                    Button("重试") { load() }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.white.opacity(0.15)).clipShape(Capsule())
                        .foregroundColor(.white)
                    Button("改地址") { showSettings = true }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.white.opacity(0.15)).clipShape(Capsule())
                        .foregroundColor(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button(action: { self.index = 0 }) {
                Image("home").resizable().frame(width: 25, height: 25)
                    .foregroundColor(.white).padding(.horizontal)
            }
            Spacer(minLength: 0)
            Button(action: {}) {
                Image("search").resizable().frame(width: 25, height: 25)
                    .foregroundColor(Color.white.opacity(0.35)).padding(.horizontal)
            }
            Spacer(minLength: 0)
            Button(action: {}) {
                Image("upload").renderingMode(.original).resizable()
                    .frame(width: 50, height: 35).padding(.horizontal)
            }
            Spacer(minLength: 0)
            Button(action: {}) {
                Image("comment").resizable().frame(width: 25, height: 25)
                    .foregroundColor(Color.white.opacity(0.35)).padding(.horizontal)
            }
            Spacer(minLength: 0)
            Button(action: {}) {
                Image("profile").resizable().frame(width: 25, height: 25)
                    .foregroundColor(Color.white.opacity(0.35)).padding(.horizontal)
            }
        }
        .padding(.horizontal)
    }

    private func load() {
        store.loadMore()
        syncPlayers()
    }

    /// store 里的 entry 落成 AVPlayer（已有 id 的不重建）
    private func syncPlayers() {
        let existing = Set(data.map { $0.id })
        var newData = data
        for entry in store.entries where !existing.contains(entry.id) {
            newData.append(Video(id: entry.id,
                                 player: AVPlayer(url: entry.videoURL),
                                 replay: false,
                                 likeCount: entry.likeCount))
        }
        if newData.count != data.count {
            data = newData
        }
    }
}

// MARK: - 服务器设置

struct ServerSettingsView: View {
    var onSaved: () -> Void = {}
    @State private var text: String = FeedConfig.base
    @State private var status = ""
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("视频库地址")) {
                    TextField("http://192.168.1.10:6688", text: $text)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("测试连接") { test() }
                    if !status.isEmpty { Text(status).font(.footnote).foregroundColor(.gray) }
                }
                Section(header: Text("常用")) {
                    Button("局域网 172.29.8.196:6688") { text = "http://172.29.8.196:6688" }
                    Button("Tailscale 100.78.220.84:6688") { text = "http://100.78.220.84:6688" }
                }
            }
            .navigationBarTitle("服务器", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentation.wrappedValue.dismiss() },
                                trailing: Button("保存") { save() })
        }
    }

    private func normalized() -> String {
        var v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.lowercased().hasPrefix("http") { v = "http://" + v }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    private func test() {
        let v = normalized()
        guard let url = URL(string: v + "/api/health") else { status = "地址格式不对"; return }
        status = "正在连 \(v) …"
        URLSession.shared.dataTask(with: url) { _, resp, err in
            DispatchQueue.main.async {
                if err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 {
                    status = "连上了 ✓"
                } else {
                    status = "连不上：\(err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")"
                }
            }
        }.resume()
    }

    private func save() {
        FeedConfig.base = normalized()
        onSaved()
        presentation.wrappedValue.dismiss()
    }
}

// MARK: - 播放列表

struct PlayerView: View {
    @Binding var data: [Video]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<self.data.count, id: \.self) { i in
                ZStack {
                    Player(player: self.data[i].player)
                        .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                        .offset(y: -5)

                    if self.data[i].replay {
                        Button(action: {
                            self.data[i].replay = false
                            self.data[i].player.seek(to: .zero)
                            self.data[i].player.play()
                        }) {
                            Image(systemName: "goforward")
                                .resizable().frame(width: 55, height: 60).foregroundColor(.white)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !self.data.isEmpty else { return }
            self.data[0].player.play()
            self.data[0].player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                   object: self.data[0].player.currentItem,
                                                   queue: .main) { _ in
                self.data[0].replay = true
            }
        }
    }
}

struct Player: UIViewControllerRepresentable {
    var player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = player
        view.showsPlaybackControls = false
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

class Host: UIHostingController<ContentView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

struct Video: Identifiable {
    var id: Int
    var player: AVPlayer
    var replay: Bool
    var likeCount: Int
}

// MARK: - 竖向分页滚动

struct PlayerScrollView: UIViewRepresentable {

    func makeCoordinator() -> Coordinator {
        return PlayerScrollView.Coordinator(parent1: self)
    }

    @Binding var data: [Video]

    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        let childView = UIHostingController(rootView: PlayerView(data: self.$data))
        childView.view.frame = CGRect(x: 0, y: 0,
                                      width: UIScreen.main.bounds.width,
                                      height: UIScreen.main.bounds.height * CGFloat(data.count))
        view.contentSize = CGSize(width: UIScreen.main.bounds.width,
                                  height: UIScreen.main.bounds.height * CGFloat(data.count))
        view.addSubview(childView.view)
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.isPagingEnabled = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        uiView.contentSize = CGSize(width: UIScreen.main.bounds.width,
                                    height: UIScreen.main.bounds.height * CGFloat(data.count))
        for sub in uiView.subviews {
            sub.frame = CGRect(x: 0, y: 0,
                               width: UIScreen.main.bounds.width,
                               height: UIScreen.main.bounds.height * CGFloat(data.count))
        }
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PlayerScrollView
        var index = 0

        init(parent1: PlayerScrollView) {
            parent = parent1
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            let currentIndex = Int(scrollView.contentOffset.y / UIScreen.main.bounds.height)
            guard index != currentIndex, currentIndex >= 0, currentIndex < parent.data.count else { return }
            index = currentIndex

            for i in 0..<parent.data.count {
                parent.data[i].player.seek(to: .zero)
                parent.data[i].player.pause()
            }
            parent.data[index].player.play()
            parent.data[index].player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
                                                   object: parent.data[index].player.currentItem,
                                                   queue: .main) { _ in
                self.parent.data[self.index].replay = true
            }
        }
    }
}

enum NumberShort {
    static func text(_ n: Int) -> String {
        switch n {
        case ..<10_000: return "\(n)"
        case 10_000..<100_000_000: return String(format: "%.1fw", Double(n) / 10_000)
        default: return String(format: "%.1f亿", Double(n) / 100_000_000)
        }
    }
}
