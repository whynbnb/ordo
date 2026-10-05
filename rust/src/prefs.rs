//! 轻量键值偏好持久化（应用私有目录，JSON 对象）。
//!
//! 用于保存少量界面偏好，例如各类文件的默认打开应用。所有读写仍由 Rust 完成，
//! Dart 只通过 FFI 读 / 写字符串。

use serde_json::{Map, Value};
use std::path::PathBuf;

fn file() -> Option<PathBuf> {
    crate::remote::config_dir().map(|dir| dir.join("ordo_prefs.json"))
}

fn load_map() -> Map<String, Value> {
    let Some(file) = file() else {
        return Map::new();
    };
    let Ok(text) = std::fs::read_to_string(file) else {
        return Map::new();
    };
    serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

fn save_map(map: &Map<String, Value>) -> Result<(), String> {
    let Some(file) = file() else {
        return Err("配置目录不可用".into());
    };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let text = serde_json::to_string_pretty(map).map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(file, text).map_err(|e| format!("保存失败：{e}"))
}

/// 返回全部偏好（键 -> 字符串值）。
pub fn all() -> Value {
    Value::Object(load_map())
}

/// 写入一个偏好项。
pub fn set(key: &str, value: &str) -> Result<(), String> {
    let mut map = load_map();
    map.insert(key.to_string(), Value::String(value.to_string()));
    save_map(&map)
}

/// 删除一个偏好项（不存在时也视为成功）。
pub fn remove(key: &str) -> Result<(), String> {
    let mut map = load_map();
    if map.remove(key).is_none() {
        return Ok(());
    }
    save_map(&map)
}
