# 安序 Ordo

[English](README.md) | **中文**

一个使用 **Flutter + Rust** 构建的安卓文件管理器：界面由 Flutter 绘制，所有文件操作都在 Rust 中完成。

- 界面（Flutter）：Material 3，简洁实用。
- 核心（Rust）：所有文件系统操作都在 Rust 中完成，通过一层极简的 C ABI
  以 JSON 形式与 Flutter 通信。
- 面向普通（非 root）安卓设备，使用「所有文件访问权限」（Android 11+）或
  旧版读写权限。

> 本项目**不使用** Flutter 自带的文件读写 API，也**不引入任何文件相关的第三方
> 包**。Dart 侧只负责界面与 FFI 调用，实际的读 / 写 / 复制 / 移动 / 删除 / 搜索 /
> 压缩 / 分析全部由 Rust 实现。

## 功能

### 本地文件管理

- 浏览内部存储、可移动存储卡与可插拔 USB 存储（U 盘 / 移动硬盘），展示容量占用
- **热插拔**：插拔 U 盘 / 存储卡时监听系统存储广播自动刷新并提示；插入 USB 存储时
  系统会像其它文件管理器一样询问是否用安序打开
- 常用目录快捷入口（下载 / 图片 / 相机 / 音乐 / 视频 / 文档）
- 可点击的路径面包屑；收藏夹（书签）；**最近访问记录**；目录内**前进 / 后退**导航
- 新建文件夹 / 文件、重命名、删除（默认移入回收站，可恢复 / 清空）；创建**符号链接**
- 多选、复制 / 剪切 / 粘贴（跨目录），大文件带进度与取消
  - 选择增强：反选、按类型选择、按条件选择（最小大小 / 最近天数 / 扩展名）
  - 复制路径；为文件夹创建**桌面快捷方式**
- 排序（名称 / 大小 / 修改时间 / 类型，升序 / 降序）、显示 / 隐藏隐藏文件
- **文件标签颜色**标记（按路径持久化）
- **图片 / 视频缩略图**（图片由 Rust 解码缩放并缓存，视频借助系统媒体框架）
- 按名称递归搜索
- 详细信息面板；**应用内预览图片 / 音频 / 文本**（文本可简单编辑并保存），
  视频等其余文件交给系统「打开方式」；分享文件
- 工具：**文件校验和**（SHA-256 / MD5）、**文件夹大小按需统计**
- **设置**：为图片 / 音频 / 视频 / 文本 / PDF / 安装包等指定默认跳转应用
  （未设置时每次弹出系统选择器），偏好持久化到应用私有目录

### ZIP

- 压缩 / 解压 / 查看压缩包内容

### 存储分析

- 分类占用（图片 / 视频 / 音频 / 文档 / 压缩包 / 安装包 / 文本 / 其它）
- 最大文件列表，可直接打开、打开所在文件夹、分享、移入回收站或永久删除
- 重复文件检测（同大小 + SHA-256 两级筛选），可一键清理

### 远程位置（WebDAV / FTP / SMB，全部由 Rust 实现）

- 连接管理（增删改、测试连接），配置保存在应用私有目录
- 与本地一致的浏览、新建、重命名、删除，以及本地 / 远程之间的复制 / 移动（流式读写）
- 远程文件可在应用内预览，或下载到缓存后交给系统打开
- 从其它应用拖入的图片 / 文件可直接落到当前远程目录

### 本机文件服务器（HTTP/WebDAV + FTP）

- 在手机上直接开启服务，供同一局域网设备访问
- 浏览器可直接浏览 / 下载；Windows / macOS / Linux 可映射为网络驱动器（WebDAV）
- FTP 支持被动（PASV/EPSV）与主动（PORT/EPRT）模式，可读写
- 可选用户名密码、只读模式；配置持久化，端口可自定义

### 跨应用拖放导入

- 在分屏 / 多窗口下，把相册等其它应用里的文件直接拖入安序窗口，即可复制到当前
  浏览的目录（本地或远程）
- Android 系统拖放由原生层接收，文件写入仍由 Rust 完成

> 依赖 Android 的多窗口能力（Android 7.0+ 分屏，或 Android 14+ 的系统拖放）；
> Flutter 框架本身不提供该能力，这里用原生 `View.OnDragListener` 自行实现。

## 说明与限制

- FTP 目前仅支持明文（未实现 FTPS）；WebDAV 支持 HTTPS 且可选择信任自签名证书。
- SMB 的共享名可以留空，此时连接根目录会列出服务器上的全部共享。
- 作为服务端时，FTP 同样为明文传输，请仅在可信局域网中使用。
- 外部介质：应用会解析 `/proc/self/mountinfo` 并借助 Android `StorageManager`
  识别存储卡与可插拔 USB 存储；插拔时会监听系统存储广播自动刷新并提示，回到前台或
  下拉刷新也会更新列表。部分设备若未向应用开放 USB 卷的底层路径，仍会列出该卷并
  标注「未开放访问」，而不是直接隐藏（受系统限制）。
- 连接密码保存在应用私有目录的 `ordo_connections.json`（明文，仅本应用可访问）。
- 应用没有统计 / 上报，不会向开发者上传任何数据；只有你主动配置的远程连接与局域网
  文件服务器会产生网络流量。

## 架构

```
lib/                      Flutter 界面与 FFI 绑定
  src/ffi/native.dart     dart:ffi 绑定 + 后台 isolate 调度
  src/services/           文件系统门面 / 平台通道
  src/state/              浏览状态、排序偏好、剪贴板、连接配置、拖放
  src/ui/                 各页面与组件
rust/                     Rust 核心（cdylib）
  src/lib.rs              C ABI 导出与 panic 防护
  src/api.rs              本地文件系统实现
  src/vfs.rs              统一门面：本地路径与远程 URI 走同一接口
  src/storage.rs          存储卷发现（内部 / 存储卡 / USB）
  src/importer.rs         跨应用拖放文件的导入（fd → 本地 / 远程）
  src/favorites.rs        收藏夹持久化
  src/prefs.rs            界面偏好持久化（默认打开方式等）
  src/trash.rs            回收站（移入 / 恢复 / 清空）
  src/jobs.rs             长任务进度与取消
  src/archive.rs          ZIP 压缩 / 解压
  src/thumbnail.rs        图片缩略图解码与缓存
  src/analyze.rs          存储分析（分类 / 大文件 / 重复）
  src/remote/             WebDAV / FTP / SMB 客户端与连接会话
  src/server/             HTTP/WebDAV 与 FTP 服务端
  src/model.rs            元数据模型
android/                  Android 工程
  app/.../MainActivity.kt 存储权限、文件打开 / 分享、跨应用拖放接收、USB 插拔
  app/build.gradle.kts    调用 cargo-ndk 编译 Rust 并放入 jniLibs
scripts/                  手动构建脚本
```

远程位置以 URI 形式表示：`<scheme>://<连接ID>/路径`，例如
`smb://ab12cd/文档/report.pdf`。Dart 侧只传字符串，协议实现与连接复用都在
Rust 中完成。

所有原生函数的返回值都是 `{"ok":true,"data":...}` 或
`{"ok":false,"error":"..."}`，字符串内存由 Rust 分配、Dart 释放。

## 版本

应用版本号以仓库根目录的 `VERSION` 文件为唯一来源，当前为 **1.0**（两段式
`主版本.次版本`）。Rust 核心通过 `include_str!` 读取该文件并随 `ping` 返回，
Android 的 `versionName` 由 Gradle 读取同一文件；`pubspec.yaml` 因 Dart 要求
三段式而保留 `1.0.0+build`，仅用于 Flutter 工具链。

## 环境要求

- Flutter（已启用 Android 工具链）
- Rust 与 Android 目标：
  ```sh
  rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
  cargo install cargo-ndk
  ```
- Android NDK（Android Studio 自带，或单独安装并设置 `ANDROID_NDK_HOME`）

## 构建与运行

Gradle 会在构建 APK 前自动调用 `cargo-ndk` 编译 Rust（见
`android/app/build.gradle.kts` 中的 `cargoNdkBuild` 任务）：

```sh
flutter run --release
# 或
flutter build apk --release
```

只打包 arm64-v8a（Rust 与 Flutter 都只编译该架构）：

```sh
flutter build apk --release \
  --target-platform android-arm64 \
  -P ordo.rustAbis=arm64-v8a
```

手动编译 Rust 核心（产物放入 `android/app/src/main/jniLibs`）：

```sh
./scripts/build_rust_android.sh
```

首次启动时应用会请求「所有文件访问权限」，请按提示前往系统设置授权。

## 测试

```sh
# Rust 单元测试
cargo test --manifest-path rust/Cargo.toml

# Dart 单元测试（含纯逻辑）
flutter test

# 桌面端可用动态库跑完整的 Dart <-> Rust 集成测试
cargo build --manifest-path rust/Cargo.toml
ORDO_CORE_LIB="$PWD/rust/target/debug/libordo_core.dylib" \
  flutter test test/ffi_integration_test.dart
```
