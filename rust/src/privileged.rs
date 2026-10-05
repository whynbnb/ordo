//! 高权限后端（Root / Shizuku / ADB）。
//!
//! Android 11+ 的分区存储不允许普通应用访问 `/sdcard/Android/data`、
//! `/sdcard/Android/obb`（即便拥有「所有文件访问」权限），其它应用私有的
//! `/data/data` 更是仅 root 可见。为了看到这些文件，本模块通过本地 TCP 与一个
//! 以 shell（uid 2000）或 root 身份运行的辅助进程 `ordo-privd` 通信，由它代替
//! 应用执行文件操作。
//!
//! 辅助进程是本仓库同一个 Rust 核心的另一个入口（`src/bin/ordo_privd.rs`），
//! 复用 [`crate::api`] 的全部实现，因此文件操作逻辑依然全部在 Rust 中完成。
//!
//! 协议：4 字节大端长度前缀 + UTF-8 JSON。连接后第一条消息必须是
//! `{"token":"..."}`，随后是 `{"op":...,...}` 请求，响应为
//! `{"ok":true,"data":...}` 或 `{"ok":false,"error":"..."}`。

use crate::model::FileEntry;
use base64::Engine as _;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

pub const MODE_OFF: &str = "off";
pub const MODE_ROOT: &str = "root";
pub const MODE_SHIZUKU: &str = "shizuku";
pub const MODE_ADB: &str = "adb";

/// 单条消息上限，防止异常长度导致内存爆炸。
const MAX_FRAME: usize = 512 * 1024 * 1024;

#[derive(Clone)]
struct Config {
    port: u16,
    token: String,
    mode: String,
}

fn config() -> &'static Mutex<Option<Config>> {
    static CONFIG: OnceLock<Mutex<Option<Config>>> = OnceLock::new();
    CONFIG.get_or_init(|| Mutex::new(None))
}

fn config_snapshot() -> Option<Config> {
    config().lock().ok().and_then(|guard| guard.clone())
}

/// 当前生效的模式；未启用时为 [`MODE_OFF`]。
pub fn mode() -> String {
    config_snapshot()
        .map(|c| c.mode)
        .unwrap_or_else(|| MODE_OFF.to_string())
}

/// 是否已配置高权限后端。
pub fn active() -> bool {
    config_snapshot().is_some()
}

/// 配置并验证高权限后端（由 Dart 在原生层启动辅助进程后调用）。
pub fn configure(port: u16, token: String, mode: String) -> Result<(), String> {
    if port == 0 || token.is_empty() {
        return Err("高权限服务参数无效".into());
    }
    if mode != MODE_ROOT && mode != MODE_SHIZUKU && mode != MODE_ADB {
        return Err("未知的权限模式".into());
    }
    {
        let mut guard = config().lock().map_err(|_| "状态锁不可用".to_string())?;
        *guard = Some(Config {
            port,
            token,
            mode,
        });
    }
    // 立即验证连通性与鉴权。
    match call("ping", json!({})) {
        Ok(_) => Ok(()),
        Err(error) => {
            clear();
            Err(error)
        }
    }
}

/// 关闭高权限后端。
pub fn clear() {
    if let Ok(mut guard) = config().lock() {
        *guard = None;
    }
}

/// 状态信息，供界面展示。
pub fn status() -> Value {
    json!({ "mode": mode(), "active": active() })
}

// ---------------------------------------------------------------------------
// 传输
// ---------------------------------------------------------------------------

fn read_frame(stream: &mut TcpStream) -> Result<Value, String> {
    let mut len_bytes = [0u8; 4];
    stream
        .read_exact(&mut len_bytes)
        .map_err(|e| format!("读取高权限服务响应失败：{e}"))?;
    let len = u32::from_be_bytes(len_bytes) as usize;
    if len > MAX_FRAME {
        return Err("高权限服务响应过大".into());
    }
    let mut buffer = vec![0u8; len];
    stream
        .read_exact(&mut buffer)
        .map_err(|e| format!("读取高权限服务响应失败：{e}"))?;
    serde_json::from_slice(&buffer).map_err(|e| format!("解析高权限服务响应失败：{e}"))
}

fn write_frame(stream: &mut TcpStream, value: &Value) -> Result<(), String> {
    let bytes = serde_json::to_vec(value).map_err(|e| format!("序列化失败：{e}"))?;
    stream
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .map_err(|e| format!("发送高权限服务请求失败：{e}"))?;
    stream
        .write_all(&bytes)
        .map_err(|e| format!("发送高权限服务请求失败：{e}"))?;
    stream.flush().ok();
    Ok(())
}

/// 向高权限服务发送一次请求并返回 `data` 字段。
fn call(op: &str, params: Value) -> Result<Value, String> {
    let cfg = config_snapshot().ok_or_else(|| "高权限模式未启用".to_string())?;
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, cfg.port));
    let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(4))
        .map_err(|e| format!("连接高权限服务失败：{e}"))?;
    stream.set_nodelay(true).ok();

    write_frame(&mut stream, &json!({ "token": cfg.token }))?;
    let ack = read_frame(&mut stream)?;
    if ack["ok"] != Value::Bool(true) {
        return Err("高权限服务鉴权失败".into());
    }

    let request = match params {
        Value::Object(mut map) => {
            map.insert("op".to_string(), Value::String(op.to_string()));
            Value::Object(map)
        }
        other => json!({ "op": op, "params": other }),
    };
    write_frame(&mut stream, &request)?;

    let response = read_frame(&mut stream)?;
    if response["ok"] == Value::Bool(true) {
        Ok(response.get("data").cloned().unwrap_or(Value::Null))
    } else {
        Err(response["error"]
            .as_str()
            .unwrap_or("高权限操作失败")
            .to_string())
    }
}

fn decode_entry(value: Value) -> Result<FileEntry, String> {
    serde_json::from_value(value).map_err(|e| format!("解析文件信息失败：{e}"))
}

// ---------------------------------------------------------------------------
// 路由判定
// ---------------------------------------------------------------------------

/// 路径是否位于受分区存储限制的 `Android/data` / `Android/obb` 之下。
fn is_scoped_restricted(path: &str) -> bool {
    let trimmed = path.trim_end_matches('/');
    for marker in ["/Android/data", "/Android/obb"] {
        if let Some(index) = trimmed.rfind(marker) {
            let rest = &trimmed[index + marker.len()..];
            if rest.is_empty() || rest.starts_with('/') {
                return true;
            }
        }
    }
    false
}

/// 仅 root 才值得走特权后端的系统路径。
fn is_root_only(path: &str) -> bool {
    const PREFIXES: [&str; 9] = [
        "/data", "/system", "/vendor", "/product", "/apex", "/root", "/sbin", "/init", "/metadata",
    ];
    PREFIXES.iter().any(|prefix| {
        path == *prefix || path.starts_with(&format!("{prefix}/"))
    })
}

/// 给定本地路径是否需要通过高权限后端执行。
///
/// - Shizuku / ADB（shell）：仅 `Android/data`、`Android/obb` 与 `/data/local/tmp`。
/// - Root：额外覆盖 `/data`、`/system` 等系统目录。
pub fn should_route(path: &str) -> bool {
    let current = mode();
    if current == MODE_OFF || path.is_empty() || !path.starts_with('/') {
        return false;
    }
    if crate::remote::is_remote(path) {
        return false;
    }
    if is_scoped_restricted(path) {
        return true;
    }
    if path == "/data/local/tmp" || path.starts_with("/data/local/tmp/") {
        return true;
    }
    if current == MODE_ROOT && is_root_only(path) {
        return true;
    }
    false
}

// ---------------------------------------------------------------------------
// 文件操作（转发给高权限服务）
// ---------------------------------------------------------------------------

pub fn list(path: &str) -> Result<Vec<FileEntry>, String> {
    let data = call("list", json!({ "path": path }))?;
    serde_json::from_value(data).map_err(|e| format!("解析目录失败：{e}"))
}

pub fn stat(path: &str) -> Result<FileEntry, String> {
    decode_entry(call("stat", json!({ "path": path }))?)
}

pub fn read(path: &str) -> Result<Vec<u8>, String> {
    let data = call("read", json!({ "path": path }))?;
    let encoded = data["data"].as_str().ok_or_else(|| "读取失败".to_string())?;
    base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|e| format!("解码失败：{e}"))
}

pub fn write(path: &str, bytes: &[u8]) -> Result<FileEntry, String> {
    let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
    decode_entry(call("write", json!({ "path": path, "data": encoded }))?)
}

pub fn create_dir(path: &str) -> Result<FileEntry, String> {
    decode_entry(call("create_dir", json!({ "path": path }))?)
}

pub fn create_file(path: &str) -> Result<FileEntry, String> {
    decode_entry(call("create_file", json!({ "path": path }))?)
}

pub fn symlink(target: &str, link: &str) -> Result<FileEntry, String> {
    decode_entry(call("symlink", json!({ "target": target, "link": link }))?)
}

pub fn delete_one(path: &str) -> Result<(), String> {
    call("delete", json!({ "path": path }))?;
    Ok(())
}

pub fn rename(path: &str, new_name: &str) -> Result<FileEntry, String> {
    decode_entry(call("rename", json!({ "path": path, "new_name": new_name }))?)
}

pub fn copy_file(source: &str, dest: &str) -> Result<FileEntry, String> {
    decode_entry(call("copy_file", json!({ "source": source, "dest": dest }))?)
}

pub fn path_size(path: &str) -> u64 {
    call("path_size", json!({ "path": path }))
        .ok()
        .and_then(|value| value.as_u64())
        .unwrap_or(0)
}

pub fn dir_size(path: &str) -> Result<Value, String> {
    call("dir_size", json!({ "path": path }))
}
