# venera (Fork — 持续维护)

> 上游 venera-app/venera 已停止维护。此 fork 由 [lll152872](https://github.com/lll152872) 维护，新增自动跳章、跨章无缝滚动、书源隐藏等功能。

[![flutter](https://img.shields.io/badge/flutter-3.44.0-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/venera-app/venera)](https://github.com/venera-app/venera/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/lll152872/venera?style=flat)](https://github.com/lll152872/venera/stargazers)

[![Download](https://img.shields.io/github/v/release/lll152872/venera)](https://github.com/lll152872/venera/releases)

## 主要改动

- 🔗 **无缝跨章连续阅读**：支持上下连续翻页与自动跳章，抽离 SplicedChapters 类管理跨章数据，加入方向感知预加载与跨章内存卸载
- 👁️ **书源隐藏**：可隐藏不需要的书源（含搜索历史），且不丢失已隐藏书源的阅读进度
- 🔍 **快捷搜索**：长按 tag/作者可保存到侧边栏快捷搜索分区，一键跳转绑定源搜索
- 📡 **追更检测优化**：改用章节数对比判断更新（替代不可靠的 updateTime），检查间隔 24h → 1h
- 🔔 **持久化更新通知**：后台检测到更新后在首页显示醒目横幅，App 重启不丢，用户主动处理后才消失（不再弹 4 秒 SnackBar）
- 📖 **翻页后才清除更新标记**：进入阅读器只看一眼封面不再清掉更新标记，实际翻页后才标记已读
- 📊 **检查进度可视化**：手动检查更新时对话框实时显示当前漫画名、更新数、失败数
- 📖 **详情页增强**：Info 区显示最新章节，并根据章节数自动判断追更状态
- 🐸 **manwaba 书源修复**：修复域名失效，新增图片 AES-CBC 解密支持

A comic reader that support reading local and network comics.

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

## Build from source
1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. Build for your platform: e.g. `flutter build apk`

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Thanks

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

