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

/// 播放到头之后干什么
enum EndBehavior: Int {
    case loop = 0        // 循环本条
    case autoNext = 1    // 自动连播下一条
    case stop = 2        // 停在最后一帧

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
    let width: Int
    let height: Int

    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool { lhs.id == rhs.id }

    var posterBest: URL { firstFrameURL }
}

struct AuthorInfo {
    let key: String
    let name: String
    let works: Int
    let likes: Int
}

// MARK: - 图片缓存（首帧 / 封面）

final class ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
        cache.countLimit = 80
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

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

    /// 先试 firstframe，失败退 poster
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
        ZStack {
            Color.black
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            }
        }
        .onAppear {
            if image != nil { return }
            ImageLoader.shared.loadPoster(for: item) { img in
                if let img = img { self.image = img }
            }
        }
    }
}

// MARK: - 播放器池

final class PlayerPool {
    static let shared = PlayerPool()

    private var players: [Int: AVPlayer] = [:]
    private var order: [Int] = []
    private let limit = 4

    func player(for item: FeedItem) -> AVPlayer {
        if let p = players[item.id] {
            touch(item.id)
            return p
        }
        let p = AVPlayer(url: item.streamURL)
        p.actionAtItemEnd = .none
        p.automaticallyWaitsToMinimizeStalling = false
        if #available(iOS 15.0, *) {
            p.currentItem?.preferredForwardBufferDuration = 1.0
        }
        players[item.id] = p
        order.append(item.id)
        evictIfNeeded()
        return p
    }

    /// 提前建播放器并开始缓冲，但不播放
    func preheat(_ items: [FeedItem]) {
        for item in items {
            if players[item.id] == nil {
                _ = player(for: item)
            }
        }
    }

    func pauseAll(except id: Int?) {
        for (key, p) in players where key != id {
            p.pause()
        }
    }

    private func touch(_ id: Int) {
        if let idx = order.firstIndex(of: id) {
            order.remove(at: idx)
            order.append(id)
        }
    }

    private func evictIfNeeded() {
        while order.count > limit {
            let victim = order.removeFirst()
            players[victim]?.pause()
            players[victim] = nil
        }
    }
}

// MARK: - 滚动控制（自动连播需要程序化翻页）

final class ScrollController: ObservableObject {
    weak var scrollView: UIScrollView?

    func scroll(to index: Int, animated: Bool = true) {
        guard let sv = scrollView else { return }
        let y = CGFloat(index) * sv.bounds.height
        sv.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
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
    let width: Int?
    let height: Int?

    func toItem(base: String) -> FeedItem? {
        guard let stream = URL(string: "\(base)/api/stream/\(id)"),
              let first = URL(string: "\(base)/api/firstframe/\(id)"),
              let poster = URL(string: "\(base)/api/poster/\(id)") else { return nil }
        let author = (authorName?.isEmpty == false ? authorName! : "未知作者")
        let cap = (caption?.isEmpty == false ? caption! : (title ?? ""))
        return FeedItem(id: id, streamURL: stream,
                        firstFrameURL: first, posterURL: poster,
                        authorName: author,
                        authorId: authorId ?? "",
                        caption: cap,
                        likeCount: digg ?? 0,
                        width: width ?? 1080,
                        height: height ?? 1920)
    }
}

final class FeedStore: ObservableObject {
    @Published var items: [FeedItem] = []
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var sort: String = "newest"

    private var offset = 0
    private var total = Int.max
    private var busy = false
    private let pageSize = 15

    var canLoadMore: Bool { offset < total }

    func reset(sort: String) {
        self.sort = sort
        items = []
        offset = 0
        total = Int.max
        busy = false
        errorText = nil
        PlayerPool.shared.pauseAll(except: nil)
    }

    func loadMore() {
        guard !busy, canLoadMore else { return }
        let base = AppConfig.base
        guard let url = URL(string: "\(base)/api/videos?limit=\(pageSize)&offset=\(offset)&sort=\(sort)") else {
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
                let mapped = resp.items.compactMap { $0.toItem(base: base) }
                self.offset += resp.items.count
                self.items.append(contentsOf: mapped)
                self.errorText = nil
            }
        }.resume()
    }
}

final class SearchStore: ObservableObject {
    @Published var results: [FeedItem] = []
    @Published var loading = false
    @Published var message: String?

    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; message = nil; return }
        let base = AppConfig.base
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/api/videos?q=\(encoded)&limit=40&sort=newest") else { return }
        loading = true
        message = nil
        URLSession.shared.dataTask(with: url) { [weak self] data, _, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.loading = false
                if let err = err { self.message = "搜索失败：\(err.localizedDescription)"; return }
                guard let data = data, let resp = try? JSONDecoder().decode(FeedDTO.self, from: data) else {
                    self.message = "搜索失败"; return
                }
                self.results = resp.items.compactMap { $0.toItem(base: base) }
                if self.results.isEmpty { self.message = "没有匹配「\(q)」的视频" }
            }
        }.resume()
    }
}

final class AuthorStore: ObservableObject {
    @Published var info: AuthorInfo?
    @Published var items: [FeedItem] = []
    @Published var loading = false
    @Published var message: String?

    func load(key: String) {
        guard !key.isEmpty else { message = "没有作者 ID"; return }
        let base = AppConfig.base
        loading = true

        guard let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }

        // 作者统计
        if let url = URL(string: "\(base)/api/author?key=\(enc)") {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data else { return }
                struct Resp: Decodable { let name: String?; let works: Int?; let likes: Int? }
                if let r = try? JSONDecoder().decode(Resp.self, from: data) {
                    DispatchQueue.main.async {
                        self.info = AuthorInfo(key: key,
                                               name: r.name ?? "",
                                               works: r.works ?? 0,
                                               likes: r.likes ?? 0)
                    }
                }
            }.resume()
        }

        // 作品列表
        if let url = URL(string: "\(base)/api/videos?author=\(enc)&limit=40&sort=newest") {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self = self, let data = data,
                      let resp = try? JSONDecoder().decode(FeedDTO.self, from: data) else { return }
                let mapped = resp.items.compactMap { $0.toItem(base: base) }
                DispatchQueue.main.async {
                    self.items = mapped
                    self.loading = false
                    if mapped.isEmpty { self.message = "这个作者没有可播放的作品" }
                }
            }.resume()
        } else {
            loading = false
        }
    }
}

// MARK: - 入口

struct ContentView: View {
    var body: some View { Home() }
}

/// SceneDelegate 用它当根控制器（状态栏浅色）
class Host: UIHostingController<ContentView> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

struct Home: View {
    @StateObject private var store = FeedStore()
    @StateObject private var scroller = ScrollController()

    @State private var index = 0
    @State private var tab = 0
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var authorRef: AuthorRef?
    @State private var playing = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            if store.items.isEmpty {
                emptyState
            } else {
                PlayerScrollView(items: store.items,
                                 index: $index,
                                 playing: playing,
                                 onTap: { playing.toggle(); syncPlayback() },
                                 onFinished: handleFinished)
                    .environmentObject(scroller)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if !store.items.isEmpty { overlayBottom }
            }
            .padding(.top, UIApplication.shared.windows.first?.safeAreaInsets.top)
            .padding(.bottom, (UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0))
        }
        .edgesIgnoringSafeArea(.top)
        .sheet(isPresented: $showSettings) {
            SettingsSheet {
                store.reset(sort: store.sort)
                index = 0
                load()
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet { item in
                showSearch = false
                authorRef = nil
                pendingPlay = item
            }
        }
        .sheet(item: $authorRef) { ref in
            AuthorSheet(key: ref.key, fallbackName: ref.name)
        }
        .sheet(item: $pendingPlay) { item in
            FullPlayerSheet(item: item)
        }
        .onAppear(perform: load)
        .onChange(of: index) { newValue in
            playing = true
            let active = store.items.indices.contains(newValue) ? store.items[newValue].id : nil
            PlayerPool.shared.pauseAll(except: active)
            preheat(around: newValue)
            if newValue >= store.items.count - 3 { store.loadMore() }
        }
    }

    @State private var pendingPlay: FeedItem?

    // MARK: 加载

    private func load() {
        store.loadMore()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            preheat(around: 0)
        }
    }

    private func preheat(around i: Int) {
        guard !store.items.isEmpty else { return }
        var targets: [FeedItem] = []
        for offset in [0, 1, 2] {
            let j = i + offset
            if store.items.indices.contains(j) { targets.append(store.items[j]) }
        }
        PlayerPool.shared.preheat(targets)
        // 顺带把下一屏的首帧图预热到内存
        for item in targets {
            ImageLoader.shared.loadPoster(for: item) { _ in }
        }
    }

    private func syncPlayback() {
        let active = store.items.indices.contains(index) ? store.items[index].id : nil
        PlayerPool.shared.pauseAll(except: active)
        if playing {
            if let item = store.items[safe: index] {
                PlayerPool.shared.player(for: item).play()
            }
        }
    }

    private func handleFinished() {
        switch AppSettings.endBehavior {
        case .loop:
            break
        case .autoNext:
            if index + 1 < store.items.count {
                scroller.scroll(to: index + 1)
                index += 1
            }
        case .stop:
            playing = false
        }
    }

    private var current: FeedItem? { store.items[safe: index] }

    // MARK: 视图

    private var topBar: some View {
        HStack(spacing: 18) {
            Button { switchTab(0) } label: {
                Text("推荐").fontWeight(tab == 0 ? .bold : .regular)
                    .foregroundColor(tab == 0 ? .white : .white.opacity(0.45))
            }
            Button { switchTab(1) } label: {
                Text("热门").fontWeight(tab == 1 ? .bold : .regular)
                    .foregroundColor(tab == 1 ? .white : .white.opacity(0.45))
            }
            Spacer()
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var overlayBottom: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if let c = current, !c.authorId.isEmpty {
                        authorRef = AuthorRef(key: c.authorId, name: c.authorName)
                    }
                } label: {
                    Text("@" + (current?.authorName ?? ""))
                        .font(.headline)
                        .foregroundColor(.white)
                }

                Text(current?.caption ?? "")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .padding(.trailing, 60)
            }
            .padding(.leading, 16)
            .padding(.bottom, 34)

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                Button {
                    if let c = current, !c.authorId.isEmpty {
                        authorRef = AuthorRef(key: c.authorId, name: c.authorName)
                    }
                } label: {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.18)).frame(width: 46, height: 46)
                        Text(String((current?.authorName ?? "?").prefix(1)))
                            .foregroundColor(.white).font(.headline)
                    }
                }

                VStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Color(red: 0.996, green: 0.173, blue: 0.333))
                    Text(NumberShort.text(current?.likeCount ?? 0))
                        .font(.caption2).bold().foregroundColor(.white)
                }

                VStack(spacing: 3) {
                    Image(systemName: "bubble.right.fill")
                        .font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
                    Text("评论").font(.caption2).foregroundColor(.white.opacity(0.7))
                }

                VStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
                    Text("分享").font(.caption2).foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, 44)
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

    private func switchTab(_ t: Int) {
        guard tab != t else { return }
        tab = t
        store.reset(sort: t == 0 ? "newest" : "digg")
        index = 0
        load()
    }
}

// MARK: - 竖向分页（UIScrollView）

struct PlayerScrollView: UIViewRepresentable {
    let items: [FeedItem]
    @Binding var index: Int
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    @EnvironmentObject var scroller: ScrollController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let view = UIScrollView()
        let host = UIHostingController(rootView: PagesHost(items: items,
                                                           index: $index,
                                                           playing: playing,
                                                           onTap: onTap,
                                                           onFinished: onFinished))
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0,
                                 width: UIScreen.main.bounds.width,
                                 height: UIScreen.main.bounds.height * CGFloat(max(items.count, 1)))
        view.addSubview(host.view)
        view.contentSize = host.view.frame.size
        view.isPagingEnabled = true
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .black
        view.delegate = context.coordinator
        context.coordinator.host = host
        scroller.scrollView = view
        return view
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        scroller.scrollView = uiView
        if let host = context.coordinator.host {
            host.rootView = PagesHost(items: items, index: $index,
                                       playing: playing, onTap: onTap, onFinished: onFinished)
            let height = UIScreen.main.bounds.height * CGFloat(max(items.count, 1))
            host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: height)
        }
        uiView.contentSize = CGSize(width: UIScreen.main.bounds.width,
                                    height: UIScreen.main.bounds.height * CGFloat(max(items.count, 1)))
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PlayerScrollView
        var host: UIHostingController<PagesHost>?
        private var lastIndex = 0

        init(_ parent: PlayerScrollView) {
            self.parent = parent
            super.init()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard scrollView.bounds.height > 0 else { return }
            let i = Int(round(scrollView.contentOffset.y / scrollView.bounds.height))
            if i != lastIndex, i >= 0, i < parent.items.count {
                lastIndex = i
                DispatchQueue.main.async { self.parent.index = i }
            }
        }
    }
}

struct PagesHost: View {
    let items: [FeedItem]
    @Binding var index: Int
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                VideoPage(item: item,
                          isActive: i == index,
                          playing: playing,
                          onTap: onTap,
                          onFinished: onFinished)
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            }
        }
    }
}

// MARK: - 单页

struct VideoPage: View {
    let item: FeedItem
    let isActive: Bool
    let playing: Bool
    let onTap: () -> Void
    let onFinished: () -> Void

    @State private var poster: UIImage?
    @State private var ready = false

    var body: some View {
        ZStack {
            // 底图：首帧，一直在，翻页时不会黑
            Color.black
            if let poster = poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            }

            PlayerSurface(player: PlayerPool.shared.player(for: item), ready: $ready)
                .opacity(ready && isActive ? 1 : 0)

            if !playing && isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 58))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onAppear {
            if poster == nil {
                ImageLoader.shared.loadPoster(for: item) { img in
                    if let img = img { poster = img }
                }
            }
            applyPlayback()
        }
        .onChange(of: isActive) { active in
            applyPlayback()
        }
        .onChange(of: playing) { _ in
            applyPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard isActive else { return }
            let player = PlayerPool.shared.player(for: item)
            guard let finished = note.object as? AVPlayerItem, finished === player.currentItem else { return }
            if AppSettings.endBehavior == .loop {
                player.seek(to: .zero)
                player.play()
            } else {
                onFinished()
            }
        }
    }

    private func applyPlayback() {
        let player = PlayerPool.shared.player(for: item)
        if isActive && playing {
            player.play()
        } else {
            player.pause()
            if isActive && AppSettings.endBehavior == .loop {
                player.seek(to: .zero)
            }
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    @Binding var ready: Bool

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.playerLayer.player = player
        context.coordinator.observe(player, ready: $ready)
        return v
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.observe(player, ready: $ready)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observation: NSKeyValueObservation?
        func observe(_ player: AVPlayer, ready: Binding<Bool>) {
            observation = player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                if p.timeControlStatus == .playing {
                    DispatchQueue.main.async { ready.wrappedValue = true }
                }
            }
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

// MARK: - 搜索

struct SearchSheet: View {
    var onPick: (FeedItem) -> Void
    @StateObject private var store = SearchStore()
    @State private var text = ""
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜作者 / 文案 / 合集", text: $text, onCommit: {
                        store.search(text)
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    Button("搜索") { store.search(text) }
                }
                .padding()

                if store.loading {
                    ProgressView().padding()
                }
                if let msg = store.message {
                    Text(msg).font(.footnote).foregroundColor(.gray).padding(.top, 8)
                }

                List(store.results) { item in
                    Button {
                        onPick(item)
                    } label: {
                        HStack(spacing: 10) {
                            RemoteThumb(item: item)
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.caption.isEmpty ? "(无文案)" : item.caption)
                                    .font(.subheadline).lineLimit(2)
                                Text("@" + item.authorName + "  ❤ " + NumberShort.text(item.likeCount))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationBarTitle("搜索", displayMode: .inline)
            .navigationBarItems(trailing: Button("关闭") { presentation.wrappedValue.dismiss() })
        }
    }
}

struct RemoteThumb: View {
    let item: FeedItem
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.black.opacity(0.1)
            if let image = image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).clipped()
            }
        }
        .onAppear {
            ImageLoader.shared.loadPoster(for: item) { img in
                if let img = img { image = img }
            }
        }
    }
}

// MARK: - 作者主页

struct AuthorRef: Identifiable {
    let key: String
    let name: String
    var id: String { key }
}

struct AuthorSheet: View {
    let key: String
    let fallbackName: String
    @StateObject private var store = AuthorStore()
    @State private var playingItem: FeedItem?
    @Environment(\.presentationMode) var presentation

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.25)).frame(width: 64, height: 64)
                        Text(String((store.info?.name ?? fallbackName).prefix(1)))
                            .font(.title).bold()
                    }
                    Text("@" + (store.info?.name ?? fallbackName)).font(.headline)
                    HStack(spacing: 26) {
                        stat("作品", "\(store.info?.works ?? 0)")
                        stat("获赞", NumberShort.text(store.info?.likes ?? 0))
                    }
                }
                .padding(.vertical, 20)

                if let msg = store.message {
                    Text(msg).font(.footnote).foregroundColor(.gray)
                }

                List(store.items) { item in
                    Button { playingItem = item } label: {
                        HStack(spacing: 10) {
                            RemoteThumb(item: item)
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.caption.isEmpty ? "(无文案)" : item.caption)
                                    .font(.subheadline).lineLimit(2)
                                Text("❤ " + NumberShort.text(item.likeCount))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationBarTitle("作者主页", displayMode: .inline)
            .navigationBarItems(trailing: Button("关闭") { presentation.wrappedValue.dismiss() })
        }
        .onAppear { store.load(key: key) }
        .sheet(item: $playingItem) { item in
            FullPlayerSheet(item: item)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - 全屏播放（搜索结果 / 作者作品）

struct FullPlayerSheet: View {
    let item: FeedItem
    @State private var player: AVPlayer?
    @Environment(\.presentationMode) var presentation

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.edgesIgnoringSafeArea(.all)
            if let player = player {
                PlayerSurface(player: player, ready: .constant(true))
                    .edgesIgnoringSafeArea(.all)
            }
            Button { presentation.wrappedValue.dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.85))
                    .padding()
            }
        }
        .onAppear {
            let p = AVPlayer(url: item.streamURL)
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
