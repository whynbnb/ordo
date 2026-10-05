//! 存储变化趋势：记录目录总大小 / 文件数快照，供界面比较。

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub time: i64,
    pub bytes: u64,
    pub files: u64,
}

fn measure(root: &str) -> Result<(u64, u64), String> {
    let start = Path::new(root);
    if !start.is_dir() {
        return Err("路径不是文件夹".into());
    }
    let mut bytes = 0u64;
    let mut files = 0u64;
    let mut stack: Vec<PathBuf> = vec![start.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        for item in reader.flatten() {
            let Ok(meta) = item.metadata() else {
                continue;
            };
            if meta.is_dir() {
                stack.push(item.path());
            } else {
                bytes += meta.len();
                files += 1;
            }
        }
    }
    Ok((bytes, files))
}

fn store_path() -> Option<PathBuf> {
    crate::remote::config_dir().map(|dir| dir.join("ordo_trends.json"))
}

fn load() -> HashMap<String, Vec<Snapshot>> {
    let Some(path) = store_path() else {
        return HashMap::new();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

fn save(all: &HashMap<String, Vec<Snapshot>>) -> Result<(), String> {
    let Some(path) = store_path() else {
        return Err("配置目录不可用".into());
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let text = serde_json::to_string(all).map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(path, text).map_err(|e| format!("保存失败：{e}"))
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 立即测量并记录一次快照，返回最新快照与全部历史。
pub fn record(root: &str) -> Result<Value, String> {
    let (bytes, files) = measure(root)?;
    let snapshot = Snapshot {
        time: now_secs(),
        bytes,
        files,
    };
    let mut all = load();
    let list = all.entry(root.to_string()).or_default();
    list.push(snapshot.clone());
    if list.len() > 90 {
        let drain = list.len() - 90;
        list.drain(0..drain);
    }
    save(&all)?;
    let history = all.get(root).cloned().unwrap_or_default();
    Ok(json!({ "snapshot": snapshot, "history": history }))
}

/// 读取某路径的历史快照。
pub fn history(root: &str) -> Vec<Snapshot> {
    load().remove(root).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_and_history() {
        let dir = std::env::temp_dir().join(format!("ordo_trend_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.bin"), vec![0u8; 1234]).unwrap();

        let result = record(dir.to_str().unwrap()).unwrap();
        assert_eq!(result["snapshot"]["bytes"].as_u64().unwrap(), 1234);
        assert_eq!(result["snapshot"]["files"].as_u64().unwrap(), 1);
        let history = history(dir.to_str().unwrap());
        assert!(!history.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
