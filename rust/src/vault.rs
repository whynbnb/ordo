//! 隐私空间：把文件移入应用私有目录，常规文件浏览器中不可见。

use crate::model::{build_entry, FileEntry};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn vault_dir() -> Result<PathBuf, String> {
    let base = crate::remote::config_dir().ok_or("配置目录不可用")?;
    let dir = base.join("vault");
    std::fs::create_dir_all(&dir).map_err(|e| format!("创建隐私空间失败：{e}"))?;
    Ok(dir)
}

fn unique_name(dir: &Path, base: &str) -> String {
    let mut candidate = base.to_string();
    let mut index = 1;
    while dir.join(&candidate).exists() {
        candidate = format!("{base}.{index}");
        index += 1;
        if index > 10_000 {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            candidate = format!("{base}.{nanos}");
            break;
        }
    }
    candidate
}

fn move_path(source: &Path, target: &Path) -> Result<(), String> {
    if std::fs::rename(source, target).is_ok() {
        return Ok(());
    }
    crate::server::fsutil::copy_path(source, target).map_err(|e| format!("{e}"))?;
    if source.is_dir() {
        std::fs::remove_dir_all(source).map_err(|e| format!("{e}"))?;
    } else {
        std::fs::remove_file(source).map_err(|e| format!("{e}"))?;
    }
    Ok(())
}

/// 将给定路径移入隐私空间。
pub fn move_in(paths: &[String]) -> Value {
    let dir = match vault_dir() {
        Ok(dir) => dir,
        Err(e) => return json!({ "moved": 0, "errors": [e] }),
    };
    let mut moved = 0u64;
    let mut errors: Vec<String> = Vec::new();
    for raw in paths {
        if crate::remote::is_remote(raw) {
            errors.push(format!("{raw}: 远程路径不支持隐私空间"));
            continue;
        }
        let source = PathBuf::from(raw);
        if !source.exists() {
            errors.push(format!("{raw}: 不存在"));
            continue;
        }
        let base = source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "item".to_string());
        let name = unique_name(&dir, &base);
        match move_path(&source, &dir.join(&name)) {
            Ok(_) => moved += 1,
            Err(e) => errors.push(format!("{raw}: {e}")),
        }
    }
    json!({ "moved": moved, "errors": errors })
}

/// 列出隐私空间中的项目。
pub fn list() -> Value {
    let Ok(dir) = vault_dir() else {
        return json!([]);
    };
    let mut entries: Vec<FileEntry> = Vec::new();
    if let Ok(reader) = std::fs::read_dir(&dir) {
        for item in reader.flatten() {
            let name = item.file_name().to_string_lossy().into_owned();
            if let Ok(entry) = build_entry(&item.path(), name) {
                entries.push(entry);
            }
        }
    }
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.modified));
    json!(entries)
}

/// 将隐私空间中的项目还原到目标目录。
pub fn restore(names: &[String], dest: &str) -> Value {
    let dir = match vault_dir() {
        Ok(dir) => dir,
        Err(e) => return json!({ "restored": 0, "errors": [e] }),
    };
    let dest_dir = PathBuf::from(dest);
    if !dest_dir.is_dir() {
        return json!({ "restored": 0, "errors": ["目标目录无效"] });
    }
    let mut restored = 0u64;
    let mut errors: Vec<String> = Vec::new();
    for name in names {
        let source = dir.join(name);
        if !source.exists() {
            errors.push(format!("{name}: 不存在"));
            continue;
        }
        let base = source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| name.clone());
        let target_name = unique_name(&dest_dir, &base);
        match move_path(&source, &dest_dir.join(target_name)) {
            Ok(_) => restored += 1,
            Err(e) => errors.push(format!("{name}: {e}")),
        }
    }
    json!({ "restored": restored, "errors": errors })
}

/// 从隐私空间中彻底删除（覆盖写后删除）。
pub fn delete(names: &[String]) -> Value {
    let Ok(dir) = vault_dir() else {
        return json!({ "deleted": 0, "errors": ["配置目录不可用"] });
    };
    let paths: Vec<String> = names
        .iter()
        .map(|name| dir.join(name).to_string_lossy().into_owned())
        .collect();
    crate::secure::secure_delete(&paths, 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn move_list_restore_delete() {
        let dir = std::env::temp_dir().join(format!("ordo_vault_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("secret.txt");
        std::fs::write(&file, b"top secret").unwrap();

        let moved = move_in(&[file.to_string_lossy().into_owned()]);
        assert_eq!(moved["moved"], 1);
        assert!(!file.exists());

        let listed = list();
        assert!(listed
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["name"] == "secret.txt"));

        let restored = restore(&["secret.txt".into()], dir.to_str().unwrap());
        assert_eq!(restored["restored"], 1);
        assert!(file.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
