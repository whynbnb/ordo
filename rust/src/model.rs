use serde::Serialize;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// 一个文件或文件夹的元数据，序列化后通过 FFI 传给 Flutter。
#[derive(Debug, Clone, Serialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub hidden: bool,
    pub size: u64,
    pub modified: i64,
    pub created: i64,
    pub extension: String,
    pub readable: bool,
    pub writable: bool,
}

/// 可浏览的存储卷（内部存储 / 存储卡 / USB 存储）。
#[derive(Debug, Clone, Serialize)]
pub struct StorageRoot {
    pub name: String,
    pub path: String,
    pub kind: String,
    pub total: u64,
    pub free: u64,
    pub removable: bool,
    /// 应用是否有权限读取该卷（部分 USB 卷可能被系统限制访问）。
    pub readable: bool,
}

fn to_secs(t: std::io::Result<SystemTime>) -> i64 {
    t.ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 读取路径的元数据，构建 [`FileEntry`]。符号链接会被解析到目标（跟随一次）。
pub fn build_entry(path: &Path, name: String) -> std::io::Result<FileEntry> {
    let link_meta = std::fs::symlink_metadata(path)?;
    let is_symlink = link_meta.file_type().is_symlink();
    let meta = if is_symlink {
        std::fs::metadata(path).unwrap_or(link_meta)
    } else {
        link_meta
    };

    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode()
    };
    #[cfg(not(unix))]
    let mode = {
        let readonly = meta.permissions().readonly();
        if readonly {
            0o444
        } else {
            0o666
        }
    };

    let extension = if meta.is_dir() {
        String::new()
    } else {
        path.extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
    };

    Ok(FileEntry {
        name: name.clone(),
        path: path.to_string_lossy().into_owned(),
        is_dir: meta.is_dir(),
        is_symlink,
        hidden: name.starts_with('.'),
        size: meta.len(),
        modified: to_secs(meta.modified()),
        created: to_secs(meta.created()),
        extension,
        readable: mode & 0o444 != 0,
        writable: mode & 0o222 != 0,
    })
}
