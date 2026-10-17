import SwiftUI
import AVKit
import AVFoundation

// MARK: - 配置

enum AppConfig {
    static let baseKey = "dzc.serverBase"
    static let fallback = "http://172.29.8.196:6688"

    static var base: String {
        get {
            let v = UserDefaults.standard.string(forKey: baseKey) ?? ""
            return v.isEmpty ? fallback : v
        }
        set {
            var t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasSuffix("/") { t.removeLast() }
            UserDefaults.standard.set(t, forKey: baseKey)
        }
    }
}

enum EndBehavior: Int {
    case loop = 0
    case autoNext = 1
    case stop = 2

    var title: String {
        switch self {
        case .loop: return "循环播放本条"
        case .autoNext: return "自动连播下一条"
        case .stop: return "播完停住"
        }
    }
}

enum AppSettings {
    static let endKey = "dzc.endBehavior"
    static var endBehavior: EndBehavior {
        get { EndBehavior(rawValue: UserDefaults.standard.integer(forKey: endKey)) ?? .loop }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: endKey) }
    }
}

// MARK: - 模型

struct FeedItem: Identifiable, Equatable {
    let id: Int
    let streamURL: URL
    let firstFrameURL: URL
    let posterURL: URL
    let authorName: String
    let authorId: String
    let caption: String
    let likeCount: Int

    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool { lhs.id == rhs.id }
}

struct AuthorInfo {
    let key: String
    let name: String
    let works: Int
    let likes: Int
}

// MARK: - 图片

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        cache.countLimit = 120
    }

    func load(_ url: URL, completion: @escaping (UIImage?) -> Void) {
        if let img = cache.object(forKey: url as NSURL) {
            completion(img)
            return
        }
        session.dataTask(with: url) { [weak self] data, resp, _ in
            guard let self = self,
                  let data = data,
                  (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = UIImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.cache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async { completion(img) }
        }.resume()
    }

    func loadPoster(for item: FeedItem, completion: @escaping (UIImage?) -> Void) {
        load(item.firstFrameURL) { [weak self] img in
            if let img = img { completion(img); return }
            self?.load(item.posterURL, completion: completion)
        }
    }
}

struct RemoteImage: View {
    let item: FeedItem
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
        }
        .onAppear {
            guard image == nil else { return }
            ImageLoader.shared.loadPoster(for: item) { img in
                if let img = img { self.image = img }
            }
        }
    }
}

// MARK: - 数据

struct FeedDTO: Decodable {
    let total: Int
    let items: [FeedDTOItem]
}

struct FeedDTOItem: Decodable {
    let id: Int
    let title: String?
    let caption: String?
    let authorName: String?
    let authorId: String?
    let digg: Int?

    func toItem(base: String) -> FeedItem? {
        guard let stream = URL(string: "\(base)/api/stream/\(id)"),
              let first = URL(string: "\(base)/api/firstframe/\(id)"),
              let poster = URL(string: "\(base)/api/poster/\(id)") else { return nil }
        let author = (authorName?.isEmpty == false ? authorName! : "未知作者")
        let cap = (caption?.isEmpty == false ? caption! : (title ?? ""))
        return FeedItem(id: id, streamURL: stream,
                        firstFrameURL: first, posterURL: poster,
                        authorName: author, authorId: authorId ?? "",
                        caption: cap, likeCount: digg ?? 0)
    }
}

final class FeedStore: ObservableObject {
    @Published var items: [FeedItem] = []
    @Published var isLoading = false
    @Published var errorText: String?

    private var offset = 0
    private var total = Int.max
    private var busy = false
    private let pageSize = 15

    var canLoadMore: Bool { offset < total }

    func reset() {
        items = []
        offset = 0
        total = Int.max
        busy = false
        errorText = nil
    }

    func loadMore() {
        guard !busy, canLoadMore else { return }
        let base = AppConfig.base
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
                guard let data = data, let resp = try? JSONDecoder().decode(FeedDTO.self, from: data) else {
                    self.errorText = "数据解析失败"
                    return
                }
                self.total = resp.total
                self.offset += resp.items.count
                self.items.append(contentsOf: resp.items.compactMap { $0.toItem(base: base) })
                self.errorText = nil
            }
        }.resume()
    }
}

final class ListStore: ObservableObject {
    @Published var items: [FeedItem] = []
    @Published var loading = false
    @Published var message: String?

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { items = []; message = nil; return }
        let base = AppConfig.base
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/videos?q=\(enc)&limit=60&sort=newest") else { return }
        fetch(url, base: base, emptyMessage: "没有匹配「\(q)」的视频")
    }

    func author(_ key: String) {
        let base = AppConfig.base
        guard !key.isEmpty,
              let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/videos?author=\(enc)&limit=60&sort=newest") else {
            message = "没有作者 ID"
            return
        }
        fetch(url, base: base, emptyMessage: "这个作者没有可播放的作品")
    }

    private func fetch(_ url: URL, base: String, emptyMessage: String) {
        loading = true
        message = nil
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.loading = false
                if let err = err { self.message = "请求失败：\(err.localizedDescription)"; return }
                guard let data = data, let resp = try? JSONDecoder().decode(FeedDTO.self, from: data) else {
                    self.message = "数据解析失败"
                    return
                }
                self.items = resp.items.compactMap { $0.toItem(base: base) }
                if self.items.isEmpty { self.message = emptyMessage }
            }
        }.resume()
    }
}

final class AuthorInfoStore: ObservableObject {
    @Published var info: AuthorInfo?

    func load(key: String) {
        guard !key.isEmpty,
              let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(AppConfig.base)/api/author?key=\(enc)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data else { return }
            struct Resp: Decodable { let name: String?; let works: Int?; let likes: Int? }
            guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return }
            DispatchQueue.main.async {
                self?.info = AuthorInfo(key: key, name: r.name ?? "", works: r.works ?? 0, likes: r.likes ?? 0)
            }
        }.resume()
    }
}

// MARK: - 入口

struct ContentView: View {
    var body: some View { Home() }
}

class Host: UIHostingController<ContentView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

// MARK: - 首页

struct Home: View {
    @StateObject private var store = FeedStore()

    @State private var index = 0
    @State private var playing = true
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var authorRef: AuthorRef?
    @State private var pending: FeedItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if store.items.isEmpty {
                emptyState
            } else {
                VerticalFeed(items: store.items,
                             index: $index,
                             playing: playing,
                             onTap: { playing.toggle() },
                             onFinished: handleFinished)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topControls
                Spacer()
                if !store.items.isEmpty { bottomOverlay }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet {
                store.reset()
                index = 0
                load()
            }
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchPage()
        }
        .fullScreenCover(item: $authorRef) { ref in
            AuthorPage(key: ref.key, fallbackName: ref.name)
        }
        .fullScreenCover(item: $pending) { item in
            FullPlayerPage(item: item)
        }
        .onAppear(perform: load)
        .onChange(of: index) { newValue in
            playing = true
            if newValue >= store.items.count - 3 { store.loadMore() }
        }
    }

    private func load() {
        store.loadMore()
    }

    private func handleFinished() {
        switch AppSettings.endBehavior {
        case .loop:
            break                       // 由 VideoPage 自己 seek+play
        case .stop:
            playing = false
        case .autoNext:
            if index + 1 < store.items.count {
                index += 1
            }
        }
    }

    private var current: FeedItem? { store.items[safe: index] }

    /// 顶部：只有「推荐」两个字 + 右侧两个按钮，没有黑条
    private var topControls: some View {
        HStack(spacing: 16) {
            Text("推荐")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

            Spacer()

            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, (UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0) + 4)
        .padding(.bottom, 8)
    }

    private var bottomOverlay: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if let c = current, !c.authorId.isEmpty {
                        authorRef = AuthorRef(key: c.authorId, name: c.authorName)
                    }
                } label: {
                    Text("@" + (current?.authorName ?? ""))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }

                Text(current?.caption ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .padding(.trailing, 70)
            }
            .padding(.leading, 16)
            .padding(.bottom, 30)

            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Button {
                    if let c = current, !c.authorId.isEmpty {
                        authorRef = AuthorRef(key: c.authorId, name: c.authorName)
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.2)).frame(width: 46, height: 46)
                        Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 46, height: 46)
                        Text(String((current?.authorName ?? "?").prefix(1)))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                actionItem("heart.fill",
                           NumberShort.text(current?.likeCount ?? 0),
                           Color(red: 0.996, green: 0.173, blue: 0.333))

                actionItem("bubble.right.fill", "评论", .white)
                actionItem("arrowshape.turn.up.right.fill", "分享", .white)
            }
            .padding(.trailing, 12)
            .padding(.bottom, 40)
        }
    }

    private func actionItem(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(tint)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("正在连接 \(AppConfig.base)")
                    .foregroundColor(.white.opacity(0.6)).font(.footnote)
            } else {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 42)).foregroundColor(.white.opacity(0.7))
                Text(store.errorText ?? "没拿到视频")
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Text(AppConfig.base).foregroundColor(.white.opacity(0.5)).font(.caption)
                HStack(spacing: 12) {
                    Button("重试") { load() }
                    Button("改地址") { showSettings = true }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.white.opacity(0.15)).clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 竖向分页

struct VerticalFeed: UIViewRepresentable {
    let items: [FeedItem]
    @Binding var index: Int
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        scroll.delegate = context.coordinator

        let host = UIHostingController(rootView: PagesView(items: items,
                                                           index: $index,
                                                           pageHeight: pageHeight(),
                                                           playing: playing,
                                                           onTap: onTap,
                                                           onFinished: onFinished))
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)
        context.coordinator.host = host
        context.coordinator.relayout(scroll, animated: false)
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if let host = context.coordinator.host {
            host.rootView = PagesView(items: items, index: $index,
                                      pageHeight: uiView.bounds.height > 1 ? uiView.bounds.height : pageHeight(),
                                      playing: playing, onTap: onTap, onFinished: onFinished)
        }
        context.coordinator.relayout(uiView, animated: true)
    }

    /// 一页的高度：优先用 scrollView 真实高度，取不到时退回屏幕高度
    private func pageHeight() -> CGFloat {
        UIScreen.main.bounds.height
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: VerticalFeed
        var host: UIHostingController<PagesView>?
        var lastIndex = 0

        init(_ parent: VerticalFeed) {
            self.parent = parent
            super.init()
        }

        /// 关键：一页高度 == scrollView 可视高度，否则越滑越偏
        func relayout(_ scroll: UIScrollView, animated: Bool) {
            let h = scroll.bounds.height > 1 ? scroll.bounds.height : UIScreen.main.bounds.height
            let w = scroll.bounds.width > 1 ? scroll.bounds.width : UIScreen.main.bounds.width
            let total = h * CGFloat(max(parent.items.count, 1))
            host?.view.frame = CGRect(x: 0, y: 0, width: w, height: total)
            scroll.contentSize = CGSize(width: w, height: total)

            // 外部（自动连播）改了 index → 同步滚动位置
            if lastIndex != parent.index {
                lastIndex = parent.index
                scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(parent.index) * h), animated: animated)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let h = scrollView.bounds.height
            guard h > 1 else { return }
            let i = Int(round(scrollView.contentOffset.y / h))
            if i != lastIndex, i >= 0, i < parent.items.count {
                lastIndex = i
                DispatchQueue.main.async { self.parent.index = i }
            }
        }
    }
}

struct PagesView: View {
    let items: [FeedItem]
    @Binding var index: Int
    let pageHeight: CGFloat
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                VideoPage(item: item,
                          isActive: i == index,
                          shouldLoad: abs(i - index) <= 1,
                          playing: playing,
                          onTap: onTap,
                          onFinished: onFinished)
                    .frame(width: UIScreen.main.bounds.width, height: pageHeight)
            }
        }
        .frame(width: UIScreen.main.bounds.width,
               height: pageHeight * CGFloat(max(items.count, 1)),
               alignment: .top)
    }
}

// MARK: - 单页

struct VideoPage: View {
    let item: FeedItem
    let isActive: Bool
    let shouldLoad: Bool
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            // 首帧永远铺底：视频没出来时看到的是画面，不是黑的
            RemoteImage(item: item)

            if let player = player {
                PlayerSurface(player: player)
            }

            if !playing && isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 62))
                    .foregroundColor(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onAppear { sync(force: true) }
        .onDisappear { teardown() }
        .onChange(of: shouldLoad) { _ in sync(force: false) }
        .onChange(of: isActive) { _ in sync(force: false) }
        .onChange(of: playing) { _ in sync(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard isActive, let p = player, let finished = note.object as? AVPlayerItem,
                  finished === p.currentItem else { return }
            if AppSettings.endBehavior == .loop {
                p.seek(to: .zero)
                p.play()
            } else {
                onFinished()
            }
        }
    }

    private func sync(force: Bool) {
        if shouldLoad {
            if player == nil {
                let p = AVPlayer(url: item.streamURL)
                p.actionAtItemEnd = .none
                p.automaticallyWaitsToMinimizeStalling = false
                p.isMuted = false
                player = p
            }
            if isActive && playing {
                player?.play()
            } else {
                player?.pause()
            }
        } else {
            // 离得远的页释放播放器，只留首帧图，控制内存
            player?.pause()
            player = nil
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class SurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 设置

struct SettingsSheet: View {
    var onSaved: () -> Void = {}
    @State private var text: String = AppConfig.base
    @State private var status = ""
    @State private var endBehavior: EndBehavior = AppSettings.endBehavior
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("播放")) {
                    Picker("播完之后", selection: $endBehavior) {
                        Text(EndBehavior.loop.title).tag(EndBehavior.loop)
                        Text(EndBehavior.autoNext.title).tag(EndBehavior.autoNext)
                        Text(EndBehavior.stop.title).tag(EndBehavior.stop)
                    }
                }
                Section(header: Text("视频库地址")) {
                    TextField("http://192.168.1.10:6688", text: $text)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("测试连接") { test() }
                    if !status.isEmpty { Text(status).font(.footnote).foregroundColor(.gray) }
                }
                Section(header: Text("常用地址")) {
                    Button("局域网 172.29.8.196:6688") { text = "http://172.29.8.196:6688" }
                    Button("Tailscale 100.78.220.84:6688") { text = "http://100.78.220.84:6688" }
                }
            }
            .navigationBarTitle("设置", displayMode: .inline)
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
                    status = "连不上：\(err?.localizedDescription ?? "HTTP")"
                }
            }
        }.resume()
    }

    private func save() {
        AppConfig.base = normalized()
        AppSettings.endBehavior = endBehavior
        onSaved()
        presentation.wrappedValue.dismiss()
    }
}

// MARK: - 搜索页（仿抖音：顶部搜索条 + 三列网格）

struct SearchPage: View {
    @StateObject private var store = ListStore()
    @State private var text = ""
    @State private var picked: FeedItem?
    @Environment(\.presentationMode) var presentation

    private let columns = [GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.white.opacity(0.6))
                        TextField("搜作者 / 文案 / 合集", text: $text, onCommit: {
                            store.search(text)
                        })
                        .foregroundColor(.white)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        if !text.isEmpty {
                            Button { text = ""; store.search("") } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Capsule())

                    Button("搜索") { store.search(text) }
                        .foregroundColor(.white)

                    Button("取消") { presentation.wrappedValue.dismiss() }
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.top, (UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0) + 6)
                .padding(.bottom, 8)

                if store.loading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).padding()
                }
                if let msg = store.message {
                    Text(msg).font(.footnote).foregroundColor(.white.opacity(0.5)).padding(.top, 20)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(store.items) { item in
                            Button { picked = item } label: {
                                VideoGridCell(item: item)
                            }
                        }
                    }
                }
            }
        }
        .statusBar(hidden: false)
        .sheet(item: $picked) { item in
            FullPlayerPage(item: item)
        }
    }
}

struct VideoGridCell: View {
    let item: FeedItem

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                RemoteImage(item: item)
                    .frame(width: geo.size.width, height: geo.size.width * 16 / 9)
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)
                    .frame(height: 46)

                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 10))
                    Text(NumberShort.text(item.likeCount)).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(6)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipped()
    }
}

// MARK: - 作者主页（仿抖音：头像/统计 + 作品网格）

struct AuthorRef: Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

struct AuthorPage: View {
    let key: String
    let fallbackName: String

    @StateObject private var info = AuthorInfoStore()
    @StateObject private var list = ListStore()
    @State private var picked: FeedItem?
    @Environment(\.presentationMode) var presentation

    private let columns = [GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2),
                           GridItem(.flexible(), spacing: 2)]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { presentation.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text("@" + (info.info?.name ?? fallbackName))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 20, height: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, (UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0) + 6)
                .padding(.bottom, 12)

                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.15)).frame(width: 76, height: 76)
                        Circle().stroke(Color.white, lineWidth: 2).frame(width: 76, height: 76)
                        Text(String((info.info?.name ?? fallbackName).prefix(1)))
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    Text("@" + (info.info?.name ?? fallbackName))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)

                    HStack(spacing: 34) {
                        stat("\(info.info?.works ?? 0)", "作品")
                        stat(NumberShort.text(info.info?.likes ?? 0), "获赞")
                        stat("--", "关注")
                        stat("--", "粉丝")
                    }
                }
                .padding(.bottom, 16)

                if list.loading {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).padding()
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(list.items) { item in
                            Button { picked = item } label: {
                                VideoGridCell(item: item)
                            }
                        }
                    }
                }
            }
        }
        .statusBar(hidden: false)
        .sheet(item: $picked) { item in
            FullPlayerPage(item: item)
        }
        .onAppear {
            info.load(key: key)
            list.author(key)
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold)).foregroundColor(.white)
            Text(title).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
        }
    }
}

// MARK: - 全屏播放

struct FullPlayerPage: View {
    let item: FeedItem
    @State private var player: AVPlayer?
    @State private var playing = true
    @Environment(\.presentationMode) var presentation

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteImage(item: item)
            if let player = player {
                PlayerSurface(player: player)
            }

            if !playing {
                Image(systemName: "play.fill")
                    .font(.system(size: 62))
                    .foregroundColor(.white.opacity(0.75))
            }

            VStack {
                HStack {
                    Button { presentation.wrappedValue.dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, (UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0) + 6)
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("@" + item.authorName)
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        Text(item.caption)
                            .font(.system(size: 14)).foregroundColor(.white).lineLimit(3)
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(Color(red: 0.996, green: 0.173, blue: 0.333))
                        Text(NumberShort.text(item.likeCount))
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playing.toggle()
            if playing { player?.play() } else { player?.pause() }
        }
        .onAppear {
            let p = AVPlayer(url: item.streamURL)
            p.automaticallyWaitsToMinimizeStalling = false
            p.play()
            player = p
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - 工具

enum NumberShort {
    static func text(_ n: Int) -> String {
        switch n {
        case ..<10_000: return "\(n)"
        case 10_000..<100_000_000: return String(format: "%.1fw", Double(n) / 10_000)
        default: return String(format: "%.1f亿", Double(n) / 100_000_000)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
