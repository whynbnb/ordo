//! 智能清理：扫描可安全删除的“垃圾”文件（空文件、空目录、临时 / 缓存文件）。

use crate::model::{build_entry, FileEntry};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const TEMP_SUFFIXES: &[&str] = &[
    ".tmp",
    ".temp",
    ".log",
    ".part",
    ".crdownload",
    ".download",
    ".bak",
    ".old",
];

const TEMP_NAMES: &[&str] = &[".ds_store", "thumbs.db", "desktop.ini"];

fn is_temp(name: &str) -> bool {
    let lower = name.to_lowercase();
    if TEMP_NAMES.contains(&lower.as_str()) {
        return true;
    }
    if lower.ends_with('~') || lower.starts_with("~$") {
        return true;
    }
    TEMP_SUFFIXES.iter().any(|suffix| lower.ends_with(suffix))
}

/// 扫描目录，返回分类后的可疑文件。
pub fn scan(root: &str, limit: usize) -> Result<Value, String> {
    let start = Path::new(root);
    if !start.is_dir() {
        return Err("清理起点不是文件夹".into());
    }
    let cap = if limit == 0 { 2000 } else { limit };

    let mut empty_files: Vec<FileEntry> = Vec::new();
    let mut empty_dirs: Vec<FileEntry> = Vec::new();
    let mut temp_files: Vec<FileEntry> = Vec::new();
    let mut stack: Vec<PathBuf> = vec![start.to_path_buf()];
    let mut scanned: u64 = 0;
    let mut truncated = false;

    while let Some(dir) = stack.pop() {
        if scanned >= 200_000 {
            truncated = true;
            break;
        }
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut has_entries = false;
        let mut subdirs: Vec<PathBuf> = Vec::new();
        for item in reader.flatten() {
            scanned += 1;
            has_entries = true;
            let name = item.file_name().to_string_lossy().into_owned();
            let path = item.path();
            let is_dir = item.file_type().map(|t| t.is_dir()).unwrap_or(false);
            if is_dir {
                subdirs.push(path);
                continue;
            }
            let Ok(entry) = build_entry(&path, name.clone()) else {
                continue;
            };
            if entry.size == 0 {
                empty_files.push(entry.clone());
            }
            if is_temp(&name) {
                temp_files.push(entry);
            }
        }
        if !has_entries && dir != start {
            if let Some(name) = dir.file_name().map(|n| n.to_string_lossy().into_owned()) {
                if let Ok(entry) = build_entry(&dir, name) {
                    empty_dirs.push(entry);
                }
            }
        }
        stack.extend(subdirs);
        if empty_files.len() + temp_files.len() + empty_dirs.len() >= cap {
            truncated = true;
            break;
        }
    }

    for list in [&mut empty_files, &mut temp_files, &mut empty_dirs] {
        list.sort_by(|a, b| a.path.cmp(&b.path));
    }
    let reclaimable: u64 = temp_files.iter().map(|entry| entry.size).sum();

    Ok(json!({
        "empty_files": empty_files,
        "empty_dirs": empty_dirs,
        "temp_files": temp_files,
        "reclaimable": reclaimable,
        "scanned": scanned,
        "truncated": truncated,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_classifies_junk() {
        let dir = std::env::temp_dir().join(format!("ordo_cleanup_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("empty")).unwrap();
        std::fs::write(dir.join("zero.txt"), b"").unwrap();
        std::fs::write(dir.join("cache.tmp"), b"junk data").unwrap();
        std::fs::write(dir.join("keep.txt"), b"keep").unwrap();

        let result = scan(dir.to_str().unwrap(), 100).unwrap();
        assert_eq!(result["empty_files"].as_array().unwrap().len(), 1);
        assert_eq!(result["empty_dirs"].as_array().unwrap().len(), 1);
        assert_eq!(result["temp_files"].as_array().unwrap().len(), 1);
        assert_eq!(result["reclaimable"].as_u64().unwrap(), 9);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
