# Echo Music

Echo Music 是一款跨平台音乐播放器，同时提供 iOS 原生版（SwiftUI）与 Android / iOS 跨平台版（React Native）。支持自定义音源、沉浸式歌词、横屏播放页、迷你播放器折叠，以及网易云听歌足迹同步。

## 功能

- 多音源聚合：网易云、QQ 音乐、酷狗、酷我、咪咕、Spotify 等
- 沉浸式 SwiftUI 播放页（iOS 版）：封面、壁纸、动态歌词、横屏三栏布局
- 迷你播放器：胶囊形态，滚动折叠，iPad 自动展开
- 网易云听歌上报：`startplay` + `playend` 两段上报，足迹完整归档
- 深色 / 浅色主题自适应

## 平台

| 路径 | 技术栈 | 最低版本 | 说明 |
| --- | --- | --- | --- |
| `platforms/ios-compat/` | SwiftUI（XcodeGen） | iOS 15.0 | iOS 原生版 |
| `platforms/android/` | React Native + TypeScript | Android 8 / iOS 15 | 跨平台版（含原生壳） |

iOS 原生版通过 GitHub Actions（macOS runner）自动构建 unsigned IPA，推送到 main 分支即触发。

## 构建

```bash
# iOS 原生版（XcodeGen）
cd platforms/ios-compat
xcodegen generate
open EchoMusic.xcodeproj
```

```bash
# React Native 跨平台版
cd platforms/android
npm install
npm run ios      # iOS
npm run android  # Android
```

## 许可证

见 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`。
