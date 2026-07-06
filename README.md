# venera (Fork — 持续维护)

> 上游 venera-app/venera 已停止维护。此 fork 由 [lll152872](https://github.com/lll152872) 维护，新增自动跳章、跨章无缝滚动、书源隐藏等功能。

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/venera-app/venera)](https://github.com/venera-app/venera/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/lll152872/venera?style=flat)](https://github.com/lll152872/venera/stargazers)

[![Download](https://img.shields.io/github/v/release/lll152872/venera)](https://github.com/lll152872/venera/releases)

## 新增功能

- 📖 **自动跳章**：阅读完当前章节自动跳转下一章
- 🔗 **跨章无缝滚动**：连续滚动模式支持跨章节拼接阅读，真正的无缝体验
- 👁️ **书源隐藏**：可隐藏不想看到的漫画源，搜索/历史/收藏同步过滤
- 🔄 **章节正序/倒序**：章节列表支持正序倒序切换
- 📡 **自动追更**：打开漫画详情页自动判断更新

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

