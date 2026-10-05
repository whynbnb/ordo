//! Ordo 安序 —— 文件系统核心。
//!
//! 所有文件操作（本地与远程 WebDAV / FTP / SMB）都在 Rust 侧完成，通过一层极简
//! 的 C ABI 暴露给 Flutter。每个导出函数接收 UTF-8 字符串，返回一段 JSON：
//! `{"ok":true,"data":...}` 或 `{"ok":false,"error":"..."}`。字符串内存由 Rust
//! 分配，调用方使用 [`ordo_free_string`] 释放。

mod analyze;
mod api;
mod archive;
mod favorites;
mod importer;
mod jobs;
mod media;
mod model;
mod prefs;
mod remote;
mod server;
mod storage;
mod thumbnail;
mod trash;
mod vfs;

use remote::ProfileSpec;
use serde::Serialize;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// JSON 与内存辅助
// ---------------------------------------------------------------------------

fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"error\":\"invalid utf8\"}")
            .unwrap()
            .into_raw(),
    }
}

fn ok<T: Serialize>(data: T) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": true, "data": data }).to_string())
}

fn result<T: Serialize>(r: Result<T, String>) -> *mut c_char {
    match r {
        Ok(data) => ok(data),
        Err(err) => into_c_string(serde_json::json!({ "ok": false, "error": err }).to_string()),
    }
}

fn err(msg: impl Into<String>) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": false, "error": msg.into() }).to_string())
}

unsafe fn read_str(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("收到的参数为空".into());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(str::to_owned)
        .map_err(|e| format!("参数不是有效的 UTF-8：{e}"))
}

unsafe fn read_paths(ptr: *const c_char) -> Result<Vec<String>, String> {
    let raw = read_str(ptr)?;
    serde_json::from_str::<Vec<String>>(&raw).map_err(|e| format!("路径列表无效：{e}"))
}

unsafe fn read_profile(ptr: *const c_char) -> Result<ProfileSpec, String> {
    let raw = read_str(ptr)?;
    serde_json::from_str::<ProfileSpec>(&raw).map_err(|e| format!("连接配置无效：{e}"))
}

/// 捕获 panic，避免任何意外让进程崩溃。
fn guard<F: FnOnce() -> *mut c_char>(f: F) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(ptr) => ptr,
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "内部错误".to_string()
            };
            err(msg)
        }
    }
}

// ---------------------------------------------------------------------------
// 导出函数：本地 + 远程统一入口
// ---------------------------------------------------------------------------

/// 释放由本库返回的字符串。
///
/// # Safety
/// `ptr` 必须来自本库的某个返回值，且只能释放一次。
#[no_mangle]
pub unsafe extern "C" fn ordo_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_list_dir(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::list(&p)),
        Err(e) => err(e),
    })
}

/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_stat(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::stat(&p)),
        Err(e) => err(e),
    })
}

/// 读取文本文件。`max_bytes` 为 0 表示不限制。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_read_text(path: *const c_char, max_bytes: u64) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::read_text(&p, max_bytes)),
        Err(e) => err(e),
    })
}

/// 写入文本文件（覆盖）。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_write_text(
    path: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(path), read_str(content)) {
        (Ok(p), Ok(c)) => result(vfs::write_text(&p, &c)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 创建文件夹（含父级）。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_create_dir(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::create_dir(&p)),
        Err(e) => err(e),
    })
}

/// 创建空文件。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_create_file(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::create_file(&p)),
        Err(e) => err(e),
    })
}

/// 删除一组路径。入参为 JSON 字符串数组；支持本地与远程路径。
/// `to_trash` 为真时本地文件移入回收站（可恢复）。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_delete(paths: *const c_char, to_trash: bool) -> *mut c_char {
    guard(|| match read_paths(paths) {
        Ok(list) => ok(trash::delete(&list, to_trash)),
        Err(e) => err(e),
    })
}

/// 重命名（仅改名，不移动目录）。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_rename(path: *const c_char, new_name: *const c_char) -> *mut c_char {
    guard(|| match (read_str(path), read_str(new_name)) {
        (Ok(p), Ok(n)) => result(vfs::rename(&p, &n)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 复制一组路径到目标位置（支持本地 <-> 远程）。入参为 JSON 字符串数组；`job_id` 为 0 表示不跟踪进度。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_copy(
    sources: *const c_char,
    dest: *const c_char,
    job_id: u64,
) -> *mut c_char {
    guard(|| match (read_paths(sources), read_str(dest)) {
        (Ok(src), Ok(d)) => {
            let job = jobs::get(job_id);
            let value = vfs::copy(&src, &d, job.as_deref());
            if let Some(job) = &job {
                job.complete();
            }
            ok(value)
        }
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 移动一组路径到目标位置（支持本地 <-> 远程）。入参为 JSON 字符串数组；`job_id` 为 0 表示不跟踪进度。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_move(
    sources: *const c_char,
    dest: *const c_char,
    job_id: u64,
) -> *mut c_char {
    guard(|| match (read_paths(sources), read_str(dest)) {
        (Ok(src), Ok(d)) => {
            let job = jobs::get(job_id);
            let value = vfs::move_entries(&src, &d, job.as_deref());
            if let Some(job) = &job {
                job.complete();
            }
            ok(value)
        }
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 在 `root` 下按名称递归搜索（仅本地）。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_search(
    root: *const c_char,
    query: *const c_char,
    limit: u32,
) -> *mut c_char {
    guard(|| match (read_str(root), read_str(query)) {
        (Ok(r), Ok(q)) => result(vfs::search(&r, &q, limit as usize)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 列出可用的本地存储卷（内部存储 / 存储卡 / USB 存储）。
#[no_mangle]
pub extern "C" fn ordo_storage_roots() -> *mut c_char {
    guard(|| ok(storage::storage_roots()))
}

/// 计算文件校验和（`sha256` 或 `md5`）。
///
/// # Safety
/// FFI 边界：两个指针均为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_hash(path: *const c_char, algorithm: *const c_char) -> *mut c_char {
    guard(|| match (read_str(path), read_str(algorithm)) {
        (Ok(p), Ok(a)) => result(vfs::hash(&p, &a)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 按需统计文件夹大小（仅本地）。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_dir_size(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(vfs::dir_size(&p)),
        Err(e) => err(e),
    })
}

/// 读取图片的 EXIF / 媒体信息。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_media_info(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(media::info(&p)),
        Err(e) => err(e),
    })
}

/// 创建符号链接（仅本地）。
///
/// # Safety
/// FFI 边界：两个指针均为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_symlink(target: *const c_char, link: *const c_char) -> *mut c_char {
    guard(|| match (read_str(target), read_str(link)) {
        (Ok(t), Ok(l)) => result(vfs::symlink(&t, &l)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 写入来自 Android `StorageManager` 的卷信息（用于命名与兜底）。
///
/// 入参为 JSON 数组，元素形如
/// `{"path":...,"description":...,"removable":...,"primary":...,"state":...,"uuid":...}`。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_storage_hints(hints: *const c_char) -> *mut c_char {
    guard(|| match read_str(hints) {
        Ok(raw) => match serde_json::from_str::<Vec<storage::StorageHint>>(&raw) {
            Ok(list) => {
                storage::set_hints(list);
                ok(serde_json::Value::Null)
            }
            Err(e) => err(format!("存储卷信息无效：{e}")),
        },
        Err(e) => err(e),
    })
}

/// 读取任意文件的原始字节，返回指针并通过 `out_len` 回传长度。
/// 调用方处理后必须调用 [`ordo_free_bytes`]。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_read_bytes(path: *const c_char, out_len: *mut usize) -> *mut u8 {
    if !out_len.is_null() {
        *out_len = 0;
    }
    let path = match read_str(path) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };
    match catch_unwind(AssertUnwindSafe(|| vfs::read(&path))) {
        Ok(Ok(bytes)) => {
            let boxed = bytes.into_boxed_slice();
            let len = boxed.len();
            if !out_len.is_null() {
                *out_len = len;
            }
            Box::into_raw(boxed) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}

/// 释放 [`ordo_read_bytes`] 返回的内存。
///
/// # Safety
/// FFI 边界：`ptr` 必须来自 [`ordo_read_bytes`]，`len` 为其返回的长度。
#[no_mangle]
pub unsafe extern "C" fn ordo_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let slice = std::slice::from_raw_parts_mut(ptr, len);
        drop(Box::from_raw(slice as *mut [u8]));
    }
}

/// 生成图片缩略图（JPEG 字节）。失败或非图片时返回空指针。
/// 调用方处理后必须调用 [`ordo_free_bytes`]。
///
/// # Safety
/// FFI 边界：指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_thumbnail(
    path: *const c_char,
    max_px: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if !out_len.is_null() {
        *out_len = 0;
    }
    let path = match read_str(path) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };
    match catch_unwind(AssertUnwindSafe(|| thumbnail::thumbnail(&path, max_px))) {
        Ok(Ok(bytes)) => {
            let boxed = bytes.into_boxed_slice();
            let len = boxed.len();
            if !out_len.is_null() {
                *out_len = len;
            }
            Box::into_raw(boxed) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}

/// 写入原始字节。
///
/// # Safety
/// FFI 边界：`path` 为合法 C 字符串；`data`/`len` 描述一段有效内存。
#[no_mangle]
pub unsafe extern "C" fn ordo_write_bytes(
    path: *const c_char,
    data: *const u8,
    len: usize,
) -> *mut c_char {
    guard(|| {
        let p = match read_str(path) {
            Ok(p) => p,
            Err(e) => return err(e),
        };
        if data.is_null() && len > 0 {
            return err("数据为空");
        }
        let slice = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(data, len)
        };
        result(vfs::write(&p, slice))
    })
}

/// 应用版本号，唯一来源为仓库根目录的 `VERSION` 文件（形如 `1.0`）。
pub const APP_VERSION: &str = include_str!("../../VERSION");

/// 简单连通性检查，供 Dart 侧确认动态库已加载。
#[no_mangle]
pub extern "C" fn ordo_ping() -> *mut c_char {
    guard(|| {
        into_c_string(
            serde_json::json!({
                "ok": true,
                "data": { "name": "Ordo", "core": "ordo_core", "version": APP_VERSION.trim() }
            })
            .to_string(),
        )
    })
}

/// 把外部应用拖入的文件描述符内容导入到 `dest_dir`，`name` 为建议文件名。
///
/// `fd` 的所有权会移交给本函数（结束时关闭）。用于接收 Android 跨应用拖放。
///
/// # Safety
/// FFI 边界：`fd` 必须为可读且已移交所有权的文件描述符；两个指针需为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_import_fd(
    fd: i32,
    dest_dir: *const c_char,
    name: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(dest_dir), read_str(name)) {
        (Ok(dir), Ok(name)) => result(importer::import_fd(fd, &dir, &name)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

// ---------------------------------------------------------------------------
// 导出函数：远程连接
// ---------------------------------------------------------------------------

/// 设置配置目录与缓存目录（应在启动时调用一次）。
///
/// # Safety
/// FFI 边界：两个指针均为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_config_init(
    config_dir: *const c_char,
    cache_dir: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(config_dir), read_str(cache_dir)) {
        (Ok(config), Ok(cache)) => {
            remote::init(&config, &cache);
            ok(serde_json::Value::Null)
        }
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 列出全部连接配置。
#[no_mangle]
pub extern "C" fn ordo_profile_list() -> *mut c_char {
    guard(|| ok(remote::list_profiles()))
}

/// 新增或更新一条连接配置（入参为 JSON）。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_profile_save(profile: *const c_char) -> *mut c_char {
    guard(|| match read_profile(profile) {
        Ok(p) => result(remote::save_profile(p)),
        Err(e) => err(e),
    })
}

/// 删除一条连接配置。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_profile_remove(id: *const c_char) -> *mut c_char {
    guard(|| match read_str(id) {
        Ok(id) => result(remote::remove_profile(&id).map(|_| serde_json::Value::Null)),
        Err(e) => err(e),
    })
}

/// 测试连接（入参为 JSON 配置，不会保存）。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_profile_test(profile: *const c_char) -> *mut c_char {
    guard(|| match read_profile(profile) {
        Ok(p) => result(remote::test_profile(&p).map(|_| serde_json::Value::Null)),
        Err(e) => err(e),
    })
}

/// 断开指定连接。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_net_disconnect(id: *const c_char) -> *mut c_char {
    guard(|| match read_str(id) {
        Ok(id) => result(remote::disconnect(&id).map(|_| serde_json::Value::Null)),
        Err(e) => err(e),
    })
}

/// 把远程文件下载到本地缓存目录，返回本地路径（供系统应用打开）。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_net_download(uri: *const c_char) -> *mut c_char {
    guard(|| match read_str(uri) {
        Ok(uri) => result(download_to_cache(&uri)),
        Err(e) => err(e),
    })
}

fn download_to_cache(uri: &str) -> Result<serde_json::Value, String> {
    let cache = remote::cache_dir().ok_or_else(|| "缓存目录不可用".to_string())?;
    std::fs::create_dir_all(&cache).map_err(|e| format!("创建缓存目录失败：{e}"))?;
    let data = vfs::read(uri)?;
    let name = uri
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|n| !n.is_empty())
        .unwrap_or("download");
    let safe: String = name
        .chars()
        .map(|c| {
            if c == '/' || c == '\\' || c == '\0' {
                '_'
            } else {
                c
            }
        })
        .collect();
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let dest: PathBuf = cache.join(format!("{nanos}-{safe}"));
    std::fs::write(&dest, data).map_err(|e| format!("写入缓存失败：{e}"))?;
    let path = Path::new(&dest).to_string_lossy().into_owned();
    Ok(serde_json::json!({ "path": path, "name": name }))
}

// ---------------------------------------------------------------------------
// 导出函数：本地文件服务器（HTTP/WebDAV + FTP）
// ---------------------------------------------------------------------------

unsafe fn read_server_config(ptr: *const c_char) -> Result<server::ServerConfig, String> {
    let raw = read_str(ptr)?;
    serde_json::from_str::<server::ServerConfig>(&raw).map_err(|e| format!("服务器配置无效：{e}"))
}

/// 启动服务器（入参为 JSON 配置），返回当前状态。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_server_start(config: *const c_char) -> *mut c_char {
    guard(|| match read_server_config(config) {
        Ok(cfg) => result(server::start(cfg)),
        Err(e) => err(e),
    })
}

/// 停止所有服务器，返回当前状态。
#[no_mangle]
pub extern "C" fn ordo_server_stop() -> *mut c_char {
    guard(|| {
        server::stop();
        ok(server::status())
    })
}

/// 查询服务器状态。
#[no_mangle]
pub extern "C" fn ordo_server_status() -> *mut c_char {
    guard(|| ok(server::status()))
}

/// 保存服务器配置（不启动）。
///
/// # Safety
/// FFI 边界：指针为合法的 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_server_config_save(config: *const c_char) -> *mut c_char {
    guard(|| match read_server_config(config) {
        Ok(cfg) => result(server::save_config(&cfg).map(|_| cfg)),
        Err(e) => err(e),
    })
}

/// 读取已保存的服务器配置。
#[no_mangle]
pub extern "C" fn ordo_server_config_load() -> *mut c_char {
    guard(|| ok(server::load_config()))
}

// ---------------------------------------------------------------------------
// 导出函数：收藏夹
// ---------------------------------------------------------------------------

/// 列出收藏。
#[no_mangle]
pub extern "C" fn ordo_favorite_list() -> *mut c_char {
    guard(|| ok(favorites::list()))
}

/// 添加收藏（入参为显示名与路径）。
///
/// # Safety
/// FFI 边界：两个指针均为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_favorite_add(
    name: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(name), read_str(path)) {
        (Ok(name), Ok(path)) => result(favorites::add(&name, &path)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 移除收藏（按路径）。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_favorite_remove(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(path) => result(favorites::remove(&path)),
        Err(e) => err(e),
    })
}

// ---------------------------------------------------------------------------
// 导出函数：界面偏好（键值）
// ---------------------------------------------------------------------------

/// 读取全部偏好项。
#[no_mangle]
pub extern "C" fn ordo_pref_all() -> *mut c_char {
    guard(|| ok(prefs::all()))
}

/// 写入一个偏好项。
///
/// # Safety
/// FFI 边界：两个指针均为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_pref_set(key: *const c_char, value: *const c_char) -> *mut c_char {
    guard(|| match (read_str(key), read_str(value)) {
        (Ok(key), Ok(value)) => result(prefs::set(&key, &value).map(|_| serde_json::Value::Null)),
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 删除一个偏好项。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_pref_remove(key: *const c_char) -> *mut c_char {
    guard(|| match read_str(key) {
        Ok(key) => result(prefs::remove(&key).map(|_| serde_json::Value::Null)),
        Err(e) => err(e),
    })
}

// ---------------------------------------------------------------------------
// 导出函数：回收站
// ---------------------------------------------------------------------------

/// 列出回收站内容。
#[no_mangle]
pub extern "C" fn ordo_trash_list() -> *mut c_char {
    guard(|| ok(trash::list()))
}

/// 恢复回收站中的若干条目（入参为 JSON id 数组）。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_trash_restore(ids: *const c_char) -> *mut c_char {
    guard(|| match read_paths(ids) {
        Ok(list) => ok(trash::restore(&list)),
        Err(e) => err(e),
    })
}

/// 清空回收站。
#[no_mangle]
pub extern "C" fn ordo_trash_empty() -> *mut c_char {
    guard(|| ok(trash::empty()))
}

/// 从回收站彻底删除若干条目（入参为 JSON id 数组）。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_trash_remove(ids: *const c_char) -> *mut c_char {
    guard(|| match read_paths(ids) {
        Ok(list) => ok(trash::remove(&list)),
        Err(e) => err(e),
    })
}

// ---------------------------------------------------------------------------
// 导出函数：长任务进度
// ---------------------------------------------------------------------------

/// 创建一个任务，返回其 id（用于轮询进度 / 取消）。
#[no_mangle]
pub extern "C" fn ordo_job_create() -> *mut c_char {
    guard(|| {
        let (id, _) = jobs::create();
        ok(id)
    })
}

/// 查询任务进度：`{progress, total, cancelled, done}`。
#[no_mangle]
pub extern "C" fn ordo_job_status(id: u64) -> *mut c_char {
    guard(|| ok(jobs::snapshot(id)))
}

/// 请求取消任务。
#[no_mangle]
pub extern "C" fn ordo_job_cancel(id: u64) -> *mut c_char {
    guard(|| {
        jobs::cancel(id);
        ok(serde_json::Value::Null)
    })
}

/// 释放任务记录。
#[no_mangle]
pub extern "C" fn ordo_job_cleanup(id: u64) -> *mut c_char {
    guard(|| {
        jobs::cleanup(id);
        ok(serde_json::Value::Null)
    })
}

// ---------------------------------------------------------------------------
// 导出函数：归档（ZIP / TAR / TAR.GZ）
// ---------------------------------------------------------------------------

/// 读取可空字符串参数：空指针视为空字符串。
unsafe fn read_password(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        read_str(ptr).unwrap_or_default()
    }
}

/// 创建归档。`dest` 扩展名决定格式（zip / tar / tar.gz），`password` 仅对 zip 生效。
///
/// # Safety
/// FFI 边界：指针均为合法 C 字符串（`password` 可为空）。
#[no_mangle]
pub unsafe extern "C" fn ordo_archive_create(
    sources: *const c_char,
    dest: *const c_char,
    job_id: u64,
    password: *const c_char,
) -> *mut c_char {
    guard(|| match (read_paths(sources), read_str(dest)) {
        (Ok(src), Ok(dest)) => {
            let password = read_password(password);
            let job = jobs::get(job_id);
            let outcome = archive::create(&src, &dest, &password, job.as_deref());
            if let Some(job) = &job {
                job.complete();
            }
            result(outcome)
        }
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 解压归档到目标目录。`only` 非空时只解压该条目。
///
/// # Safety
/// FFI 边界：指针均为合法 C 字符串（`password` / `only` 可为空）。
#[no_mangle]
pub unsafe extern "C" fn ordo_archive_extract(
    archive_path: *const c_char,
    dest_dir: *const c_char,
    job_id: u64,
    password: *const c_char,
    only: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(archive_path), read_str(dest_dir)) {
        (Ok(path), Ok(dest)) => {
            let password = read_password(password);
            let only = if only.is_null() {
                None
            } else {
                read_str(only).ok().filter(|value| !value.is_empty())
            };
            let job = jobs::get(job_id);
            let outcome =
                archive::extract(&path, &dest, &password, only.as_deref(), job.as_deref());
            if let Some(job) = &job {
                job.complete();
            }
            result(outcome)
        }
        (Err(e), _) | (_, Err(e)) => err(e),
    })
}

/// 列出归档内容。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_archive_list(archive_path: *const c_char) -> *mut c_char {
    guard(|| match read_str(archive_path) {
        Ok(path) => result(archive::list(&path)),
        Err(e) => err(e),
    })
}

// ---------------------------------------------------------------------------
// 导出函数：存储分析
// ---------------------------------------------------------------------------

/// 分析存储占用（分类 / 最大文件 / 重复文件）。`job_id` 为 0 表示不跟踪进度。
///
/// # Safety
/// FFI 边界：指针为合法 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn ordo_analyze(root: *const c_char, job_id: u64) -> *mut c_char {
    guard(|| match read_str(root) {
        Ok(root) => {
            let job = jobs::get(job_id);
            let outcome = analyze::analyze(&root, job.as_deref());
            if let Some(job) = &job {
                job.complete();
            }
            result(outcome)
        }
        Err(e) => err(e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_test_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn list_and_sort_dirs_first() {
        let dir = temp("list");
        fs::create_dir(dir.join("beta")).unwrap();
        fs::write(dir.join("file10.txt"), b"x").unwrap();
        fs::write(dir.join("file2.txt"), b"x").unwrap();

        let entries = api::list_dir(dir.to_str().unwrap()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["beta", "file2.txt", "file10.txt"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn copy_then_move_and_delete() {
        let dir = temp("copy");
        let src = dir.join("a.txt");
        fs::write(&src, b"hello").unwrap();
        let dst = dir.join("sub");
        fs::create_dir(&dst).unwrap();

        let copied = api::copy(
            &[src.to_string_lossy().into_owned()],
            dst.to_str().unwrap(),
            None,
        );
        assert_eq!(copied["done"], 1);
        assert!(dst.join("a.txt").exists());

        let moved = api::move_entries(
            &[src.to_string_lossy().into_owned()],
            dst.to_str().unwrap(),
            None,
        );
        assert_eq!(moved["done"], 1);
        assert!(dst.join("a (1).txt").exists());
        assert!(!src.exists());

        let removed = api::delete(&[dir.to_string_lossy().into_owned()]);
        assert_eq!(removed["deleted"], 1);
    }

    #[test]
    fn search_finds_matches() {
        let dir = temp("search");
        fs::create_dir_all(dir.join("nested")).unwrap();
        fs::write(dir.join("nested/report.txt"), b"x").unwrap();
        fs::write(dir.join("other.txt"), b"x").unwrap();

        let found = api::search(dir.to_str().unwrap(), "report", 50).unwrap();
        assert_eq!(found["entries"].as_array().unwrap().len(), 1);

        let all = api::search(dir.to_str().unwrap(), ".txt", 50).unwrap();
        assert_eq!(all["entries"].as_array().unwrap().len(), 2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn read_text_roundtrip() {
        let dir = temp("text");
        let file = dir.join("note.md");
        fs::write(&file, "# 标题").unwrap();
        let read = api::read_text(file.to_str().unwrap(), 0).unwrap();
        assert_eq!(read["content"], "# 标题");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rename_rejects_path_separator() {
        let dir = temp("rename");
        let file = dir.join("x");
        fs::write(&file, b"").unwrap();
        assert!(api::rename(file.to_str().unwrap(), "a/b").is_err());
        assert!(api::rename(file.to_str().unwrap(), "y").is_ok());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn remote_uri_parsing() {
        let (scheme, id, inner) = remote::parse("ftp://abc/dir/file").unwrap();
        assert_eq!(scheme, "ftp");
        assert_eq!(id, "abc");
        assert_eq!(inner, "/dir/file");
        assert_eq!(remote::parent_inner(&inner), "/dir");
        assert_eq!(remote::join_inner("/dir", "x"), "/dir/x");
        assert_eq!(remote::make_path("smb", "1", "a/b"), "smb://1/a/b");
        assert!(remote::is_remote("webdav://1/"));
        assert!(!remote::is_remote("/storage/emulated/0"));
    }

    #[test]
    fn ffi_ping_is_ok() {
        unsafe {
            let ptr = ordo_ping();
            let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
            ordo_free_string(ptr);
            assert!(s.contains("\"ok\":true"));
        }
    }
}
