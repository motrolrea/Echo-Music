#if os(iOS)
import Foundation

extension SettingsManager {
    /// 歌词时间补偿只取用户自己的偏移量。
    ///
    /// 以前这里还叠加了 AVAudioSession 的输出延迟 + 0.12s 前瞻，在蓝牙/音箱上
    /// 会把歌词提前 0.5~0.7 秒，看起来就是"歌词和声音对不上"。对齐 Coda 的做法：
    /// 时钟只跟引擎时间走，逐句歌词的 0.2s 提前量在 `updateLyricsCursor` 里单独加。
    var effectiveLyricsOffset: Double {
        lyricsOffset
    }
}
#endif
