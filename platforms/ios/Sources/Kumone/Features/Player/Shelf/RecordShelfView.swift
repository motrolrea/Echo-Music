#if os(iOS)
import SwiftUI

/// Native landscape shelf inspired by the Three.js preview. Covers are drawn
/// with SwiftUI perspective instead of a WebView, and every sleeve comes from
/// the live playback queue.
struct RecordShelfView: View {
    let tracks: [Track]
    let currentIndex: Int
    let currentArtwork: PlatformImage?
    var onSelect: (Int) -> Void

    @State private var covers: [Int: PlatformImage] = [:]
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let visible = window()
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let span = CGFloat(max(visible.count - 1, 1))

            ZStack {
                shelfBoard(width: width, height: height)
                ForEach(Array(visible.enumerated()), id: \.element.id) { slot, item in
                    let progress = CGFloat(slot) / span
                    sleeve(item, progress: progress, size: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag)
        }
        .task(id: tracks.map(\.playbackKey).joined(separator: "|")) {
            await loadVisibleCovers()
        }
    }

    private func window() -> [ShelfItem] {
        guard !tracks.isEmpty else { return [] }
        let center = min(max(currentIndex, 0), tracks.count - 1)
        let lower = max(0, center - 4)
        let upper = min(tracks.count - 1, center + 4)
        return (lower...upper).map { index in
            ShelfItem(index: index, track: tracks[index], selected: index == center)
        }
    }

    private func sleeve(_ item: ShelfItem, progress: CGFloat, size: CGSize) -> some View {
        let centered = (progress - 0.5) * 2 + dragOffset / max(size.width, 1)
        let depth = abs(centered)
        let cardWidth = min(size.width * 0.24, size.height * 0.72)
        let cardHeight = cardWidth * 1.04
        let image = item.selected ? (currentArtwork ?? covers[item.track.id]) : covers[item.track.id]

        return Button {
            onSelect(item.index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.93))
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardWidth - 7, height: cardHeight - 7)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.black.opacity(0.35))
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.18)).frame(width: 5)
            }
            .rotation3DEffect(.degrees(Double(-centered) * 46), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
            .scaleEffect(1 - min(depth, 1) * 0.18)
            .shadow(color: .black.opacity(item.selected ? 0.38 : 0.22), radius: item.selected ? 18 : 8, y: 8)
        }
        .buttonStyle(.plain)
        .position(
            x: size.width * (0.5 + centered * 0.34),
            y: size.height * (0.46 + depth * 0.035)
        )
        .zIndex(Double(10 - depth * 10))
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: currentIndex)
    }

    private func shelfBoard(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.20), Color(white: 0.08)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: width * 0.92, height: 18)
            .position(x: width / 2, y: height * 0.78)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let shift = value.translation.width
                dragOffset = 0
                if shift < -42 { onSelect(currentIndex + 1) }
                else if shift > 42 { onSelect(currentIndex - 1) }
            }
    }

    private func loadVisibleCovers() async {
        for item in window() where covers[item.track.id] == nil {
            guard let raw = item.track.album.picUrl,
                  let url = raw.resizedImageURL(360),
                  let image = await ImageCache.shared.image(for: url) else { continue }
            covers[item.track.id] = image
        }
    }
}

private struct ShelfItem: Identifiable {
    let index: Int
    let track: Track
    let selected: Bool
    var id: Int { track.id }
}
#endif
