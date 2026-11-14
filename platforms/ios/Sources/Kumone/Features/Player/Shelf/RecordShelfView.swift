#if os(iOS)
import QuartzCore
import SceneKit
import SwiftUI
import UIKit

/// 原生 3D 唱片架：还原预览页的透视相机、立体封面盒、侧面书脊和接触阴影。
/// 用 SceneKit 而不是内嵌网页，渲染只在场景变化时进行。
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
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isPlaying = true
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        context.coordinator.view = view
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.sync(tracks: tracks, currentIndex: currentIndex, artwork: currentArtwork)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        weak var view: SCNView?

        let scene = SCNScene()
        let cameraNode = SCNNode()

        private let albumRoot = SCNNode()
        private var albums: [ShelfAlbum] = []
        private var coverCache: [Int: UIImage] = [:]
        private var pendingCovers: Set<Int> = []
        private var signature = ""
        private var current = 0
        private var lastIndex: Int?

        /// 与预览页一致的几何参数。
        private let albumSize: CGFloat = 0.62
        private let albumThickness: CGFloat = 0.62 / 22
        private let rightGap: Float = 0.55
        private let leftGap: Float = 0.60
        private let stackPitch: Float = 0.19
        private let bodyZ: CGFloat = 0.32
        private let depthZ: CGFloat = 0.035
        private let albumScale: Float = 1.32
        private let spineAngle: Float = 87.5 * .pi / 180
        private let window = 7

        init(onSelect: @escaping (Int) -> Void) {
            self.onSelect = onSelect
            super.init()
            buildScene()
        }

        private func buildScene() {
            scene.background.contents = UIColor.clear
            scene.rootNode.addChildNode(albumRoot)

            let camera = SCNCamera()
            camera.fieldOfView = 30
            camera.zNear = 0.01
            camera.zFar = 200
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.07, 2.99)

            let target = SCNNode()
            target.position = SCNVector3(0, 0.10, 0)
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

        func installGestures(on view: SCNView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            view.addGestureRecognizer(tap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            view.addGestureRecognizer(pan)
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }
            let point = gesture.location(in: view)
            for hit in view.hitTest(point, options: [:]) {
                var node: SCNNode? = hit.node
                while let found = node {
                    if let name = found.name, name.hasPrefix("album:"),
                       let index = Int(name.dropFirst(6)) {
                        onSelect(index)
                        return
                    }
                    node = found.parent
                }
            }
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled else { return }
            let dx = gesture.translation(in: gesture.view).x
            guard abs(dx) > 40 else { return }
            onSelect(current + (dx < 0 ? 1 : -1))
        }

        func sync(tracks: [Track], currentIndex: Int, artwork: PlatformImage?) {
            guard !tracks.isEmpty else {
                if !albums.isEmpty {
                    albumRoot.childNodes.forEach { $0.removeFromParentNode() }
                    albums = []
                    signature = ""
                }
                return
            }
            let center = min(max(currentIndex, 0), tracks.count - 1)
            current = center
            let lower = max(0, center - window)
            let upper = min(tracks.count - 1, center + window)
            let visible = Array(tracks[lower...upper])
            let nextSignature = "\(lower):" + visible.map { "\($0.id)" }.joined(separator: ",")

            if nextSignature != signature {
                signature = nextSignature
                rebuild(visible, startIndex: lower)
            }

            if let artwork {
                applyCover(artwork, for: tracks[center].id)
            }
            layout(currentIndex: center, animated: lastIndex != nil)
            lastIndex = center
            loadVisibleCovers(in: visible)
        }

        private func rebuild(_ visible: [Track], startIndex: Int) {
            albumRoot.childNodes.forEach { $0.removeFromParentNode() }
            albums = visible.enumerated().map { offset, track in
                let queueIndex = startIndex + offset
                let album = ShelfAlbum(index: queueIndex, trackId: track.id,
                                       size: albumSize, thickness: albumThickness)
                album.spine.diffuse.contents = spineImage(title: track.name,
                                                          seed: Self.seed(for: track.name))
                album.node.name = "album:\(queueIndex)"
                album.node.addChildNode(album.contact)
                if let cached = coverCache[track.id] {
                    album.front.diffuse.contents = cached
                    album.back.diffuse.contents = cached
                }
                albumRoot.addChildNode(album.node)
                return album
            }
        }

        private func layout(currentIndex: Int, animated: Bool) {
            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.45
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            for album in albums {
                let offset = album.index - currentIndex
                let node = album.node
                if offset == 0 {
                    node.position = SCNVector3(-0.02, -0.01, 0.48)
                    node.eulerAngles = SCNVector3(-15 * .pi / 180, 16 * .pi / 180, 6 * .pi / 180)
                } else {
                    let x: Float = offset > 0
                        ? -0.02 + rightGap + Float(offset - 1) * stackPitch
                        : -0.02 - leftGap + Float(offset + 1) * stackPitch
                    let depth = Float(min(abs(offset), 4))
                    node.position = SCNVector3(x,
                                               0,
                                               Float(bodyZ) - Float(depthZ) * depth)
                    node.eulerAngles = SCNVector3(0, spineAngle, 0)
                }
                node.scale = SCNVector3(albumScale, albumScale, albumScale * 1.1)
                node.opacity = CGFloat(abs(offset) > 5 ? 0.2 : 1)
            }
            if animated {
                SCNTransaction.commit()
            }
        }

        private func loadVisibleCovers(in visible: [Track]) {
            for track in visible {
                if coverCache[track.id] != nil || pendingCovers.contains(track.id) { continue }
                guard let raw = track.album.picUrl, let url = raw.resizedImageURL(512) else { continue }
                pendingCovers.insert(track.id)
                Task { @MainActor in
                    let image = await ImageCache.shared.image(for: url)
                    self.pendingCovers.remove(track.id)
                    if let image {
                        self.applyCover(image, for: track.id)
                    }
                }
            }
            if coverCache.count > 60 {
                coverCache.removeAll()
            }
        }

        private func applyCover(_ image: UIImage, for trackId: Int) {
            guard let album = albums.first(where: { $0.trackId == trackId }) else { return }
            coverCache[trackId] = image
            album.front.diffuse.contents = image
            album.back.diffuse.contents = image
        }

        private static func seed(for title: String) -> Int {
            title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        }

        /// 书脊：底色 + 侧光渐变 + 竖排歌名，对应预览页里每张专辑的书脊贴图。
        private func spineImage(title: String, seed: Int) -> UIImage {
            let size = CGSize(width: 96, height: 512)
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
                g.translateBy(x: size.width / 2, y: size.height / 2)
                g.rotate(by: -.pi / 2)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 34, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.94),
                ]
                let text = title as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2),
                          withAttributes: attributes)
            }
        }
    }
}

/// 一张封面盒：正面封面、侧面书脊、背面封面与脚下的接触阴影。
@MainActor
final class ShelfAlbum {
    let node = SCNNode()
    let front = SCNMaterial()
    let back = SCNMaterial()
    let spine = SCNMaterial()
    let contact = SCNNode()
    let index: Int
    let trackId: Int

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

        let shadow = SCNPlane(width: size * 1.35, height: size * 0.58)
        let shadowMaterial = SCNMaterial()
        shadowMaterial.diffuse.contents = Self.contactImage()
        shadowMaterial.lightingModel = .constant
        shadowMaterial.isDoubleSided = true
        shadowMaterial.transparency = 0.55
        shadowMaterial.writesToDepthBuffer = false
        shadow.materials = [shadowMaterial]
        contact.geometry = shadow
        contact.eulerAngles = SCNVector3(-.pi / 2, 0, 0)
        contact.position = SCNVector3(0, Float(-size / 2) - 0.006, 0)
    }

    /// 径向渐变的椭圆软阴影。
    private static func contactImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let g = context.cgContext
            let colors = [
                UIColor.black.withAlphaComponent(0.72).cgColor,
                UIColor.black.withAlphaComponent(0.28).cgColor,
                UIColor.black.withAlphaComponent(0).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 0.55, 1]) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                g.drawRadialGradient(gradient,
                                     startCenter: center, startRadius: 6,
                                     endCenter: center, endRadius: size.width / 2,
                                     options: [])
            }
        }
    }
}
#endif
