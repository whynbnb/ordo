//! 回收站：删除时先把文件移入应用私有目录，可恢复或彻底清空。
//!
//! 仅对本地路径生效；远程路径仍按永久删除处理（无法低成本搬进本地回收站）。

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrashEntry {
    pub id: String,
    pub name: String,
    pub original_path: String,
    pub deleted_at: i64,
    pub is_dir: bool,
    pub size: u64,
}

fn root() -> Option<PathBuf> {
    crate::remote::config_dir().map(|dir| dir.join("trash"))
}

fn items_dir() -> Option<PathBuf> {
    root().map(|dir| dir.join("items"))
}

fn index_file() -> Option<PathBuf> {
    root().map(|dir| dir.join("index.json"))
}

fn read_index() -> Vec<TrashEntry> {
    let Some(file) = index_file() else {
        return Vec::new();
    };
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_index(items: &[TrashEntry]) -> Result<(), String> {
    let Some(file) = index_file() else {
        return Err("回收站不可用".into());
    };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let text = serde_json::to_string(items).map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(file, text).map_err(|e| format!("保存失败：{e}"))
}

pub fn list() -> Vec<TrashEntry> {
    let Some(items) = items_dir() else {
        return Vec::new();
    };
    let mut entries = read_index();
    entries.retain(|entry| items.join(&entry.id).exists());
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.deleted_at));
    entries
}

/// 删除一组路径；`to_trash` 为真时本地文件移入回收站。
pub fn delete(paths: &[String], to_trash: bool) -> Value {
    let mut deleted = 0u64;
    let mut trashed = 0u64;
    let mut errors: Vec<String> = Vec::new();

    for path in paths {
        let use_trash =
            to_trash && !crate::remote::is_remote(path) && !crate::privileged::should_route(path);
        let result = if use_trash {
            trash_one(path).map(|_| trashed += 1)
        } else {
            crate::vfs::remove_one(path).map(|_| deleted += 1)
        };
        if let Err(error) = result {
            errors.push(format!("{path}：{error}"));
        }
    }

    json!({ "deleted": deleted, "trashed": trashed, "errors": errors })
}

fn trash_one(path: &str) -> Result<(), String> {
    let source = Path::new(path);
    let meta = std::fs::symlink_metadata(source).map_err(|e| format!("无法读取：{e}"))?;
    let is_dir = meta.is_dir();
    let name = source
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "item".to_string());

    let id = next_id();
    let dest = items_dir().ok_or("回收站不可用")?.join(&id);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("回收站不可用：{e}"))?;
    }

    if std::fs::rename(source, &dest).is_err() {
        // 跨文件系统时退化为复制 + 删除。
        crate::server::fsutil::copy_path(source, &dest)
            .map_err(|e| format!("移入回收站失败：{e}"))?;
        let _ = if is_dir {
            std::fs::remove_dir_all(source)
        } else {
            std::fs::remove_file(source)
        };
    }

    let size = if is_dir { dir_size(&dest) } else { meta.len() };
    let mut index = read_index();
    index.push(TrashEntry {
        id,
        name,
        original_path: path.to_string(),
        deleted_at: now_secs(),
        is_dir,
        size,
    });
    write_index(&index)
}

pub fn restore(ids: &[String]) -> Value {
    let mut restored = 0u64;
    let mut errors: Vec<String> = Vec::new();
    let Some(items) = items_dir() else {
        return json!({ "restored": 0, "errors": ["回收站不可用"] });
    };
    let mut index = read_index();

    for id in ids {
        let Some(position) = index.iter().position(|entry| &entry.id == id) else {
            errors.push(format!("{id}：条目不存在"));
            continue;
        };
        let entry = index[position].clone();
        let source = items.join(id);
        let dest = unique_restore_path(&entry.original_path);
        if let Some(parent) = dest.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let result = if std::fs::rename(&source, &dest).is_ok() {
            Ok(())
        } else {
            crate::server::fsutil::copy_path(&source, &dest).and_then(|_| {
                if entry.is_dir {
                    std::fs::remove_dir_all(&source)
                } else {
                    std::fs::remove_file(&source)
                }
            })
        };
        match result {
            Ok(_) => {
                restored += 1;
                index.remove(position);
            }
            Err(error) => errors.push(format!("{id}：{error}")),
        }
    }

    let _ = write_index(&index);
    json!({ "restored": restored, "errors": errors })
}

/// 从回收站彻底删除若干条目（不恢复）。
pub fn remove(ids: &[String]) -> Value {
    let mut removed = 0u64;
    let mut errors: Vec<String> = Vec::new();
    let Some(items) = items_dir() else {
        return json!({ "deleted": 0, "errors": ["回收站不可用"] });
    };
    let mut index = read_index();
    for id in ids {
        let path = items.join(id);
        let result = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        match result {
            Ok(_) => {
                removed += 1;
                index.retain(|entry| &entry.id != id);
            }
            Err(error) => errors.push(format!("{id}：{error}")),
        }
    }
    let _ = write_index(&index);
    json!({ "deleted": removed, "errors": errors })
}

pub fn empty() -> Value {
    let mut removed = 0u64;
    if let Some(items) = items_dir() {
        if let Ok(reader) = std::fs::read_dir(&items) {
            for item in reader.flatten() {
                let path = item.path();
                let result = if path.is_dir() {
                    std::fs::remove_dir_all(&path)
                } else {
                    std::fs::remove_file(&path)
                };
                if result.is_ok() {
                    removed += 1;
                }
            }
        }
    }
    let _ = write_index(&[]);
    json!({ "deleted": removed })
}

fn next_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let count = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{nanos:x}-{count:x}")
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn dir_size(path: &Path) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        for item in reader.flatten() {
            if let Ok(meta) = item.metadata() {
                if meta.is_dir() {
                    stack.push(item.path());
                } else {
                    total += meta.len();
                }
            }
        }
    }
    total
}

fn unique_restore_path(original: &str) -> PathBuf {
    let path = PathBuf::from(original);
    if !path.exists() {
        return path;
    }
    let parent = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("/"));
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "restored".to_string());
    let (stem, ext) = match name.rfind('.') {
        Some(index) if index > 0 => (name[..index].to_string(), name[index + 1..].to_string()),
        _ => (name.clone(), String::new()),
    };
    let mut index = 1u32;
    loop {
        let candidate_name = if ext.is_empty() {
            format!("{stem} ({index})")
        } else {
            format!("{stem} ({index}).{ext}")
        };
        let candidate = parent.join(candidate_name);
        if !candidate.exists() {
            return candidate;
        }
        index += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // 回收站使用全局配置目录，测试需串行。
    static LOCK: Mutex<()> = Mutex::new(());

    fn setup(name: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("ordo_trash_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("cfg")).unwrap();
        crate::remote::init(
            &base.join("cfg").to_string_lossy(),
            &base.join("cache").to_string_lossy(),
        );
        base
    }

    #[test]
    fn delete_to_trash_restore_and_empty() {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let base = setup("cycle");
        let src = base.join("src");
        std::fs::create_dir_all(&src).unwrap();
        let file = src.join("a.txt");
        std::fs::write(&file, b"hello").unwrap();

        // 移入回收站
        let result = delete(&[file.to_string_lossy().into_owned()], true);
        assert_eq!(result["trashed"], 1);
        assert!(!file.exists());

        let entries = list();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "a.txt");
        assert_eq!(entries[0].original_path, file.to_string_lossy());

        // 恢复
        let restored = restore(&[entries[0].id.clone()]);
        assert_eq!(restored["restored"], 1);
        assert!(file.exists());
        assert!(list().is_empty());

        // 再次移入并清空
        delete(&[file.to_string_lossy().into_owned()], true);
        assert_eq!(list().len(), 1);
        let emptied = empty();
        assert_eq!(emptied["deleted"], 1);
        assert!(list().is_empty());

        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn restore_uses_unique_name_on_conflict() {
        let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let base = setup("conflict");
        let src = base.join("src");
        std::fs::create_dir_all(&src).unwrap();
        let file = src.join("doc.txt");
        std::fs::write(&file, b"original").unwrap();
        delete(&[file.to_string_lossy().into_owned()], true);

        // 在原位置重新创建一个同名文件
        std::fs::write(&file, b"new").unwrap();

        let entries = list();
        restore(&[entries[0].id.clone()]);

        assert_eq!(std::fs::read_to_string(&file).unwrap(), "new");
        assert_eq!(
            std::fs::read_to_string(src.join("doc (1).txt")).unwrap(),
            "original"
        );

        let _ = std::fs::remove_dir_all(&base);
    }
}
