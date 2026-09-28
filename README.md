# 安序 Ordo

一个使用 **Flutter + Rust** 构建的安卓文件管理器。

- 界面（Flutter）：Material 3，简洁实用。
- 核心（Rust）：所有文件系统操作都在 Rust 中完成，通过一层极简的 C ABI
  以 JSON 形式与 Flutter 通信。
- 面向普通（非 root）安卓设备，使用「所有文件访问权限」（Android 11+）或
  旧版读写权限。

> 本项目**不使用** Flutter 自带的文件读写 API，也**不引入任何文件相关的第三方
> 包**。Dart 侧只负责界面与 FFI 调用，实际的读 / 写 / 复制 / 移动 / 删除 / 搜索
> 全部由 Rust 标准库实现。

## 功能

- 浏览内部存储与存储卡，展示容量占用
- 常用目录快捷入口（下载 / 图片 / 相机 / 音乐 / 视频 / 文档）
- 新建文件夹 / 文件、重命名、删除
- 复制 / 剪切 / 粘贴（跨目录）
- 按名称递归搜索
- 排序（名称 / 大小 / 修改时间 / 类型，升序 / 降序）
- 显示 / 隐藏隐藏文件
- 应用内预览文本与图片，其余文件交给系统「打开方式」
- 分享文件
- **远程位置**：WebDAV、FTP、SMB，全部由 Rust 实现
  - 连接管理（增删改、测试连接），配置保存在应用私有目录
  - 与本地文件列表一致地浏览、新建、重命名、删除
  - 远程与本地之间复制 / 剪切 / 粘贴（流式读写）
  - 远程文件可在应用内预览，或下载到缓存后交给系统打开

> 说明：FTP 目前仅支持明文（未实现 FTPS）；WebDAV 支持 HTTPS 且可选择信任自签名证书。
> SMB 的共享名可以留空，此时连接根目录会列出服务器上的全部共享。

## 架构

```
lib/                      Flutter 界面与 FFI 绑定
  src/ffi/native.dart     dart:ffi 绑定 + 后台 isolate 调度
  src/services/           文件系统门面 / 平台通道
  src/state/              浏览状态、排序偏好、剪贴板、连接配置
  src/ui/                 各页面与组件
rust/                     Rust 核心（cdylib）
  src/lib.rs              C ABI 导出与 panic 防护
  src/api.rs              本地文件系统实现
  src/vfs.rs              统一门面：本地路径与远程 URI 走同一接口
  src/remote/             WebDAV / FTP / SMB 客户端与连接会话
  src/model.rs            元数据模型
android/                  Android 工程
  app/.../MainActivity.kt 存储权限申请、FileProvider 打开 / 分享
  app/build.gradle.kts    调用 cargo-ndk 编译 Rust 并放入 jniLibs
scripts/                  手动构建脚本
```

远程位置以 URI 形式表示：`<scheme>://<连接ID>/路径`，例如
`smb://ab12cd/文档/report.pdf`。Dart 侧只传字符串，协议实现与连接复用都在
Rust 中完成。连接密码保存在应用私有目录的 `ordo_connections.json`（明文，
仅本应用可访问）。

所有原生函数的返回值都是 `{"ok":true,"data":...}` 或
`{"ok":false,"error":"..."}`，字符串内存由 Rust 分配、Dart 释放。

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

## 说明

- 应用不会联网，也不会上传任何数据。
- 所有文件操作均在设备本地完成。
