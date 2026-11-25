#if os(iOS)
import QuartzCore
import SceneKit
import SwiftUI
import UIKit

/// 原生 3D 唱片架：透视相机、立体封面盒、侧面书脊与接触阴影。
/// 平时是一排紧密的书脊，可左右滑动浏览；点中某张才转到正面展开。
@MainActor
struct RecordShelfView: UIViewRepresentable {
    let tracks: [Track]
    let currentIndex: Int
    let currentArtwork: PlatformImage?
    var onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 0
        view.rendersContinuously = true
        view.isPlaying = true
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.sync(tracks: tracks, currentIndex: currentIndex, artwork: currentArtwork)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSelect: (Int) -> Void

        let scene = SCNScene()
        let cameraNode = SCNNode()

        private let albumRoot = SCNNode()
        private var albums: [ShelfAlbum] = []
        private var trackIDs: [Int] = []
        private var coverCache: [Int: UIImage] = [:]
        private var spineCache: [Int: UIImage] = [:]
        private var pendingCovers: Set<Int> = []

        private var scroll: CGFloat = 0
        private var targetScroll: CGFloat = 0
        private var scrollVelocity: CGFloat = 0
        private var layoutMix: CGFloat = 0
        private var layoutVelocity: CGFloat = 0
        private var expandedIndex: Int?
        /// 直接点另一首歌时先收旧唱片，等收回动画结束再展开这一张。
        private var pendingExpand: Int?
        /// 收回动画期间继续用这个下标计算展开布局，避免瞬间跳回书脊位置。
        private var layoutIndex: Int?
        private var lastCurrent = -1
        private var windowCenter = -1
        /// 列表较短时一次性铺满全部唱片，滑动不必重建节点。
        private var windowIsComplete = false
        private var didPosition = false
        /// 上次请求封面的锚点，滑到新位置时补拉附近封面。
        private var coverAnchor = -1000
        private var dragStart: CGFloat = 0
        private var displayLink: CADisplayLink?
        private var lastTickTime: CFTimeInterval = 0
        private var syncedTracks: [Track] = []

        /// 与预览页一致的几何参数。
        private let albumSize: CGFloat = 0.62
        private let albumThickness: CGFloat = 0.62 / 22
        private let pitch: CGFloat = 0.25
        private let rightGap: CGFloat = 0.84
        private let leftGap: CGFloat = 0.86
        private let stackPitch: CGFloat = 0.19
        private let bodyZ: CGFloat = 0.32
        private let depthZ: CGFloat = 0.035
        private let albumScale: Float = 1.60
        private let spineAngle = Float(87.5 * Double.pi / 180)
        private let frontAngle = Float(16 * Double.pi / 180)
        private let frontTiltX = Float(-15 * Double.pi / 180)
        private let frontTiltZ = Float(6 * Double.pi / 180)
        private let windowRadius = 10
        /// 拖动多少点换一张。
        private let dragStep: CGFloat = 70

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
            super.init()
            buildScene()
            start()
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 90)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            // 用真实帧间隔推进弹簧：掉帧时动画不会忽快忽慢。
            let now = link.timestamp
            let dt = lastTickTime == 0
                ? CGFloat(1.0 / 60.0)
                : CGFloat(min(max(now - lastTickTime, 1.0 / 120.0), 1.0 / 30.0))
            lastTickTime = now

            // 展开时记住展开的下标；收回时继续用它算布局，直到动画结束，
            // 这样收回和展开一样是连续插值，而不是瞬间弹回书脊。
            if let expandedIndex { layoutIndex = expandedIndex }

            let scrollStep = springStep(scroll, scrollVelocity, target: targetScroll, dt: dt,
                                        stiffness: 200, damping: 26)
            scroll = scrollStep.value
            scrollVelocity = scrollStep.velocity

            let layoutStep = springStep(layoutMix, layoutVelocity,
                                        target: expandedIndex == nil ? 0 : 1, dt: dt,
                                        stiffness: 170, damping: 26)
            layoutMix = layoutStep.value
            layoutVelocity = layoutStep.velocity
            if expandedIndex == nil, layoutMix <= 0.0005 {
                layoutMix = 0
                layoutVelocity = 0
                layoutIndex = nil
                // 旧唱片已经缩回去，这时再展开新选中的那张。
                if let pending = pendingExpand {
                    pendingExpand = nil
                    expandedIndex = pending
                    layoutIndex = pending
                }
            }

            for album in albums {
                let want: CGFloat = album.index == expandedIndex ? 1 : 0
                let step = springStep(album.mix, album.velocity, target: want, dt: dt,
                                      stiffness: 190, damping: 24)
                album.mix = step.value
                album.velocity = step.velocity
                apply(album)
            }

            // 滑动浏览时按可见位置平移节点窗口：整张列表都能翻到，
            // 同时只保留有限个 3D 节点。
            let anchor = expandedIndex ?? Int(scroll.rounded())
            if !windowIsComplete, !syncedTracks.isEmpty, abs(anchor - windowCenter) > 5 {
                windowCenter = anchor
                rebuild(around: anchor, tracks: syncedTracks)
            }
            // 滑动或切歌后补拉新进入视野的封面，避免后面的唱片一直是空白的。
            if abs(anchor - coverAnchor) >= 2 {
                coverAnchor = anchor
                loadVisibleCovers(around: anchor, in: syncedTracks)
            }
        }

        /// 轻阻尼弹簧：展开、收起和滑动都带一点回弹，不会生硬停住。
        private func springStep(_ value: CGFloat, _ velocity: CGFloat,
                                target: CGFloat, dt: CGFloat,
                                stiffness: CGFloat = 180,
                                damping: CGFloat = 22) -> (value: CGFloat, velocity: CGFloat) {
            var nextVelocity = velocity + ((target - value) * stiffness - velocity * damping) * dt
            var nextValue = value + nextVelocity * dt
            if abs(target - nextValue) < 0.0008, abs(nextVelocity) < 0.01 {
                nextValue = target
                nextVelocity = 0
            }
            return (nextValue, nextVelocity)
        }

        // MARK: - 场景

        private func buildScene() {
            scene.background.contents = UIColor.clear
            scene.rootNode.addChildNode(albumRoot)

            let camera = SCNCamera()
            camera.fieldOfView = 30
            camera.zNear = 0.01
            camera.zFar = 200
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.07, 2.75)

            let target = SCNNode()
            target.position = SCNVector3(0, 0.02, 0)
            scene.rootNode.addChildNode(target)
            let look = SCNLookAtConstraint(target: target)
            look.isGimbalLockEnabled = true
            cameraNode.constraints = [look]
            scene.rootNode.addChildNode(cameraNode)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = UIColor(white: 1, alpha: 1)
            ambient.light?.intensity = 620
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 760
            key.position = SCNVector3(0.5, 1.3, 3.6)
            key.eulerAngles = SCNVector3(-0.32, 0.14, 0)
            scene.rootNode.addChildNode(key)

            let warm = SCNNode()
            warm.light = SCNLight()
            warm.light?.type = .omni
            warm.light?.intensity = 220
            warm.light?.color = UIColor(red: 1, green: 0.96, blue: 0.90, alpha: 1)
            warm.position = SCNVector3(0.46, 0.87, 3.2)
            scene.rootNode.addChildNode(warm)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .directional
            rim.light?.intensity = 180
            rim.light?.color = UIColor(red: 0.68, green: 0.80, blue: 1, alpha: 1)
            rim.position = SCNVector3(-1.6, 0.9, 1.4)
            rim.eulerAngles = SCNVector3(-0.2, -0.7, 0)
            scene.rootNode.addChildNode(rim)
        }

        // MARK: - 手势

        func installGestures(on view: SCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            view.addGestureRecognizer(tap)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            view.addGestureRecognizer(pan)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            for hit in view.hitTest(point, options: [:]) {
                var node: SCNNode? = hit.node
                while let found = node {
                    if let name = found.name, name.hasPrefix("album:"),
                       let index = Int(name.dropFirst(6)) {
                        select(index)
                        return
                    }
                    node = found.parent
                }
            }
            // 点空白处收起展开的封面，回到书脊浏览状态。
            expandedIndex = nil
            pendingExpand = nil
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                expandedIndex = nil
                pendingExpand = nil
                dragStart = targetScroll
            case .changed:
                let delta = gesture.translation(in: view).x
                targetScroll = dragStart - delta / dragStep
                clampScroll()
            case .ended, .cancelled:
                let translation = gesture.translation(in: view).x
                let velocity = gesture.velocity(in: view).x
                // 甩动最多再带 2.5 张，避免一下滑太远。
                let fling = min(max(velocity / 700, -2.5), 2.5)
                targetScroll = dragStart - translation / dragStep - fling
                targetScroll = targetScroll.rounded()
                clampScroll()
            default:
                break
            }
        }

        private func select(_ index: Int) {
            if expandedIndex == index {
                expandedIndex = nil
                return
            }
            targetScroll = CGFloat(index)
            clampScroll()
            if expandedIndex != nil {
                // 先收回当前展开的唱片，动画结束后再展开新的一张。
                pendingExpand = index
                expandedIndex = nil
            } else {
                expandedIndex = index
            }
            onSelect(index)
        }

        private func clampScroll() {
            guard !trackIDs.isEmpty else { return }
            targetScroll = min(max(targetScroll, 0), CGFloat(trackIDs.count - 1))
        }

        // MARK: - 数据

        func sync(tracks: [Track], currentIndex: Int, artwork: PlatformImage?) {
            guard !tracks.isEmpty else {
                if !albums.isEmpty {
                    albumRoot.childNodes.forEach { $0.removeFromParentNode() }
                    albums = []
                    trackIDs = []
                    windowCenter = -1
                }
                return
            }
            let center = min(max(currentIndex, 0), tracks.count - 1)
            let ids = tracks.map(\.id)
            // 保存整张列表：滑动时按可见位置平移节点窗口，不会只停在最初的几首。
            syncedTracks = tracks

            if !didPosition {
                didPosition = true
                scroll = CGFloat(center)
                targetScroll = CGFloat(center)
                lastCurrent = center
                windowCenter = -1
                // 打开唱片架时，当前播放的那张先展开。
                expandedIndex = center
            }
            if ids != trackIDs {
                trackIDs = ids
                windowCenter = -1
                windowIsComplete = false
            }
            if center != lastCurrent {
                lastCurrent = center
                targetScroll = CGFloat(center)
                // 自动切歌或直接点另一首：旧的先缩回，再展开新的那一张。
                if pendingExpand != center {
                    if let expanded = expandedIndex, expanded != center {
                        pendingExpand = center
                        expandedIndex = nil
                    } else if expandedIndex == nil {
                        pendingExpand = center
                    } else {
                        expandedIndex = center
                    }
                }
            }
            ensureWindow(around: Int(scroll.rounded()), tracks: tracks)

            if let artwork {
                applyCover(artwork, for: tracks[center].id)
            }
            loadVisibleCovers(around: center, in: tracks)
        }

        private func ensureWindow(around center: Int, tracks: [Track]) {
            guard !tracks.isEmpty, !windowIsComplete else { return }
            if windowCenter >= 0, abs(center - windowCenter) <= windowRadius / 2 { return }
            windowCenter = center
            rebuild(around: center, tracks: tracks)
        }

        private func rebuild(around center: Int, tracks: [Track]) {
            albumRoot.childNodes.forEach { $0.removeFromParentNode() }
            // 列表不长时直接铺满全部歌曲；很长的列表用滑动窗口控制节点数量。
            let complete = tracks.count <= 80
            windowIsComplete = complete
            let lower = complete ? 0 : max(0, center - windowRadius)
            let upper = complete ? tracks.count - 1 : min(tracks.count - 1, center + windowRadius)
            guard lower <= upper else {
                albums = []
                return
            }
            albums = (lower...upper).map { queueIndex in
                let track = tracks[queueIndex]
                let album = ShelfAlbum(index: queueIndex, trackId: track.id,
                                       size: albumSize, thickness: albumThickness)
                album.spine.diffuse.contents = spineTexture(for: track)
                album.node.name = "album:\(queueIndex)"
                if let cached = coverCache[track.id] {
                    album.front.diffuse.contents = cached
                    album.back.diffuse.contents = cached
                }
                albumRoot.addChildNode(album.node)
                apply(album)
                return album
            }
            coverAnchor = center
            loadVisibleCovers(around: center, in: tracks)
        }

        private func apply(_ album: ShelfAlbum) {
            let offset = CGFloat(album.index) - scroll
            let spineX = offset * pitch
            let spineZ = bodyZ - depthZ * min(abs(offset), 4)

            var expandedX = spineX
            var expandedZ = spineZ
            // 用 layoutIndex 而不是 expandedIndex：收回动画期间仍按展开布局插值。
            if let expanded = layoutIndex {
                let distance = album.index - expanded
                let depth = CGFloat(min(abs(distance), 4))
                if distance == 0 {
                    expandedX = -0.02
                    expandedZ = 0.48
                } else if distance > 0 {
                    expandedX = -0.02 + rightGap + CGFloat(distance - 1) * stackPitch
                    expandedZ = bodyZ - depthZ * depth
                } else {
                    expandedX = -0.02 - leftGap + CGFloat(distance + 1) * stackPitch
                    expandedZ = bodyZ - depthZ * depth
                }
            }

            let x = spineX + (expandedX - spineX) * layoutMix
            let z = spineZ + (expandedZ - spineZ) * layoutMix
            let y: CGFloat = album.index == layoutIndex ? -0.01 * album.mix : 0
            let ry = spineAngle + (frontAngle - spineAngle) * Float(album.mix)

            album.node.position = SCNVector3(Float(x), Float(y), Float(z))
            album.node.eulerAngles = SCNVector3(frontTiltX * Float(album.mix),
                                                ry,
                                                frontTiltZ * Float(album.mix))
            // 展开时略微缩小，横屏里封面不会顶满画面。
            let shrink = albumScale * (1 - 0.05 * Float(album.mix))
            album.node.scale = SCNVector3(shrink, shrink, shrink * 1.1)
            album.node.opacity = CGFloat(abs(offset) > CGFloat(windowRadius) ? 0.15 : 1)
        }

        private func loadVisibleCovers(around center: Int, in tracks: [Track]) {
            let lower = max(0, center - windowRadius)
            let upper = min(tracks.count - 1, center + windowRadius)
            guard lower <= upper else { return }
            for index in lower...upper {
                let track = tracks[index]
                if coverCache[track.id] != nil || pendingCovers.contains(track.id) { continue }
                guard let raw = track.album.picUrl, let url = raw.resizedImageURL(256) else { continue }
                pendingCovers.insert(track.id)
                Task { @MainActor in
                    let image = await ImageCache.shared.image(for: url)
                    self.pendingCovers.remove(track.id)
                    if let image {
                        self.applyCover(image, for: track.id)
                    }
                }
            }
            // 只淘汰已经不在架子上的封面，避免整片封面被清空后再也不回来。
            if coverCache.count > 120 {
                let liveIDs = Set(albums.map(\.trackId))
                let stale = coverCache.keys.filter { !liveIDs.contains($0) }
                for key in stale {
                    coverCache.removeValue(forKey: key)
                }
            }
        }

        private func applyCover(_ image: UIImage, for trackId: Int) {
            coverCache[trackId] = image
            for album in albums where album.trackId == trackId {
                album.front.diffuse.contents = image
                album.back.diffuse.contents = image
            }
        }

        private static func seed(for title: String) -> Int {
            title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        }

        /// 书脊纹理按歌曲缓存，滑动换窗口时不再重复绘制。
        private func spineTexture(for track: Track) -> UIImage {
            if let cached = spineCache[track.id] { return cached }
            if spineCache.count > 160 { spineCache.removeAll() }
            let image = spineImage(title: track.name,
                                   artist: track.artistNames,
                                   seed: Self.seed(for: track.name))
            spineCache[track.id] = image
            return image
        }

        /// 书脊：底色 + 侧光渐变 + 竖排「歌名 · 歌手」。
        /// 纹理宽高比与书脊侧面一致（约 1:22），文字不会被压扁。
        private func spineImage(title: String, artist: String, seed: Int) -> UIImage {
            let size = CGSize(width: 48, height: 1024)
            let hue = CGFloat(seed % 360) / 360
            let base = UIColor(hue: hue, saturation: 0.42, brightness: 0.58, alpha: 1)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let g = context.cgContext
                base.setFill()
                g.fill(CGRect(origin: .zero, size: size))
                let colors = [
                    UIColor.white.withAlphaComponent(0.22).cgColor,
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.30).cgColor,
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors,
                                             locations: [0, 0.25, 1]) {
                    g.drawLinearGradient(gradient,
                                         start: .zero,
                                         end: CGPoint(x: size.width, y: 0),
                                         options: [])
                }
                // 竖排：把坐标系转成沿书脊从下往上阅读，再从底部向中间居中。
                g.translateBy(x: size.width / 2, y: size.height / 2)
                g.rotate(by: -CGFloat.pi / 2)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                paragraph.lineBreakMode = .byTruncatingTail
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                    .paragraphStyle: paragraph,
                ]
                let label = (artist.isEmpty ? title : "\(title)  ·  \(artist)") as NSString
                let rect = CGRect(x: -size.height / 2, y: -size.width / 2,
                                  width: size.height, height: size.width)
                label.draw(in: rect, withAttributes: attributes)
            }
        }
    }
}

/// 一张封面盒：正面封面、侧面书脊与背面封面。
@MainActor
final class ShelfAlbum {
    let node = SCNNode()
    let front = SCNMaterial()
    let back = SCNMaterial()
    let spine = SCNMaterial()
    let index: Int
    let trackId: Int
    /// 0 = 书脊，1 = 完全展开的封面。
    var mix: CGFloat = 0
    var velocity: CGFloat = 0

    init(index: Int, trackId: Int, size: CGFloat, thickness: CGFloat) {
        self.index = index
        self.trackId = trackId

        let box = SCNBox(width: size, height: size, length: thickness, chamferRadius: 0.004)
        let dark = SCNMaterial()
        dark.diffuse.contents = UIColor(white: 0.082, alpha: 1)
        dark.lightingModel = .lambert

        for material in [front, back, spine, dark] {
            material.lightingModel = .lambert
        }
        front.diffuse.contents = UIColor(white: 0.16, alpha: 1)
        back.diffuse.contents = UIColor(white: 0.5, alpha: 1)
        spine.diffuse.contents = UIColor(white: 0.3, alpha: 1)
        // SCNBox 材质顺序：正面、右、背面、左、顶、底。
        box.materials = [front, spine, back, spine, dark, dark]
        node.geometry = box
    }
}
#endif
