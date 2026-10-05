use crate::jobs::Job;
use crate::model::{build_entry, FileEntry};
use serde_json::{json, Value};
use std::cmp::Ordering;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

// ---------------------------------------------------------------------------
// 排序
// ---------------------------------------------------------------------------

/// 自然排序：`file2` 排在 `file10` 前面。
fn natural_cmp(a: &str, b: &str) -> Ordering {
    let mut ai = a.chars().peekable();
    let mut bi = b.chars().peekable();
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(ca), Some(cb)) => {
                if ca.is_ascii_digit() && cb.is_ascii_digit() {
                    let mut na = String::new();
                    while let Some(c) = ai.peek().copied() {
                        if c.is_ascii_digit() {
                            na.push(c);
                            ai.next();
                        } else {
                            break;
                        }
                    }
                    let mut nb = String::new();
                    while let Some(c) = bi.peek().copied() {
                        if c.is_ascii_digit() {
                            nb.push(c);
                            bi.next();
                        } else {
                            break;
                        }
                    }
                    let va: u128 = na.parse().unwrap_or(0);
                    let vb: u128 = nb.parse().unwrap_or(0);
                    match va.cmp(&vb) {
                        Ordering::Equal => match na.len().cmp(&nb.len()) {
                            Ordering::Equal => {}
                            other => return other,
                        },
                        other => return other,
                    }
                } else {
                    match ca.to_ascii_lowercase().cmp(&cb.to_ascii_lowercase()) {
                        Ordering::Equal => {
                            ai.next();
                            bi.next();
                        }
                        other => return other,
                    }
                }
            }
        }
    }
}

fn sort_entries(entries: &mut [FileEntry]) {
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| natural_cmp(&a.name, &b.name))
    });
}

// ---------------------------------------------------------------------------
// 基础操作
// ---------------------------------------------------------------------------

pub fn list_dir(path: &str) -> Result<Vec<FileEntry>, String> {
    let p = Path::new(path);
    if !p.exists() {
        return Err(format!("路径不存在：{path}"));
    }
    if !p.is_dir() {
        return Err(format!("不是文件夹：{path}"));
    }
    let rd = std::fs::read_dir(p).map_err(|e| format!("无法读取目录：{e}"))?;
    let mut out = Vec::new();
    for item in rd.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        if let Ok(entry) = build_entry(&item.path(), name) {
            out.push(entry);
        }
    }
    sort_entries(&mut out);
    Ok(out)
}

pub fn stat(path: &str) -> Result<FileEntry, String> {
    let p = Path::new(path);
    if !p.exists() && std::fs::symlink_metadata(p).is_err() {
        return Err(format!("路径不存在：{path}"));
    }
    let name = p
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string());
    build_entry(p, name).map_err(|e| e.to_string())
}

pub fn read_text(path: &str, max_bytes: u64) -> Result<Value, String> {
    let p = Path::new(path);
    let meta = std::fs::metadata(p).map_err(|e| format!("无法读取：{e}"))?;
    if meta.is_dir() {
        return Err("这是一个文件夹".into());
    }
    let size = meta.len();
    let limit = if max_bytes == 0 {
        size
    } else {
        max_bytes.min(size)
    };
    let mut f = std::fs::File::open(p).map_err(|e| format!("打开失败：{e}"))?;
    let mut buf = Vec::with_capacity(limit.min(1 << 20) as usize);
    Read::by_ref(&mut f)
        .take(limit)
        .read_to_end(&mut buf)
        .map_err(|e| format!("读取失败：{e}"))?;
    match String::from_utf8(buf) {
        Ok(content) => Ok(json!({
            "content": content,
            "truncated": size > limit,
            "size": size,
        })),
        Err(_) => Err("不是文本文件（无法按 UTF-8 解码）".into()),
    }
}

pub fn create_dir(path: &str) -> Result<FileEntry, String> {
    if Path::new(path).exists() {
        return Err("路径已存在".into());
    }
    std::fs::create_dir_all(path).map_err(|e| format!("创建失败：{e}"))?;
    stat(path)
}

pub fn create_file(path: &str) -> Result<FileEntry, String> {
    if Path::new(path).exists() {
        return Err("路径已存在".into());
    }
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建失败：{e}"))?;
    }
    std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)
        .map_err(|e| format!("创建失败：{e}"))?;
    stat(path)
}

/// 创建符号链接（`link` 指向 `target`，target 可为相对或绝对路径）。
pub fn create_symlink(target: &str, link: &str) -> Result<FileEntry, String> {
    if target.is_empty() {
        return Err("链接目标为空".into());
    }
    if std::fs::symlink_metadata(link).is_ok() || Path::new(link).exists() {
        return Err("同名路径已存在".into());
    }
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, link).map_err(|e| format!("创建符号链接失败：{e}"))?;
    #[cfg(not(unix))]
    return Err("当前平台不支持符号链接".into());
    stat(link)
}

pub fn delete(paths: &[String]) -> Value {
    let mut deleted = 0u64;
    let mut errors: Vec<String> = Vec::new();
    for p in paths {
        let path = Path::new(p);
        let is_link = std::fs::symlink_metadata(path)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false);
        let result = if path.is_dir() && !is_link {
            std::fs::remove_dir_all(path)
        } else {
            std::fs::remove_file(path)
        };
        match result {
            Ok(_) => deleted += 1,
            Err(e) => errors.push(format!("{p}：{e}")),
        }
    }
    json!({ "deleted": deleted, "errors": errors })
}

pub fn rename(path: &str, new_name: &str) -> Result<FileEntry, String> {
    let src = Path::new(path);
    if new_name.is_empty()
        || new_name.contains('/')
        || new_name.contains('\0')
        || new_name == "."
        || new_name == ".."
    {
        return Err("名称无效".into());
    }
    let parent = src.parent().ok_or_else(|| "无法获取父目录".to_string())?;
    let dest = parent.join(new_name);
    if dest == src {
        return stat(path);
    }
    if dest.exists() {
        return Err("同名文件已存在".into());
    }
    std::fs::rename(src, &dest).map_err(|e| format!("重命名失败：{e}"))?;
    build_entry(&dest, new_name.to_string()).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// 复制 / 移动
// ---------------------------------------------------------------------------

fn cancelled_err() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Interrupted, "已取消")
}

fn copy_recursive(src: &Path, dest: &Path, job: Option<&Job>) -> std::io::Result<()> {
    if let Some(job) = job {
        if job.is_cancelled() {
            return Err(cancelled_err());
        }
    }
    let meta = std::fs::symlink_metadata(src)?;
    if meta.file_type().is_symlink() {
        // 跳过符号链接，避免循环与越权复制。
        return Ok(());
    }
    if meta.is_dir() {
        std::fs::create_dir_all(dest)?;
        for item in std::fs::read_dir(src)? {
            let item = item?;
            copy_recursive(&item.path(), &dest.join(item.file_name()), job)?;
        }
        Ok(())
    } else {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(src, dest)?;
        if let Some(job) = job {
            job.add(meta.len());
        }
        Ok(())
    }
}

/// 递归统计本地路径的字节数（用于进度总量）。
pub fn path_size(path: &str) -> u64 {
    let p = Path::new(path);
    let Ok(meta) = std::fs::symlink_metadata(p) else {
        return 0;
    };
    if meta.file_type().is_symlink() {
        return 0;
    }
    if !meta.is_dir() {
        return meta.len();
    }
    let mut total = 0u64;
    let mut stack = vec![p.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        for item in reader.flatten() {
            if let Ok(file_type) = item.file_type() {
                if file_type.is_symlink() {
                    continue;
                }
                if file_type.is_dir() {
                    stack.push(item.path());
                } else if let Ok(meta) = item.metadata() {
                    total += meta.len();
                }
            }
        }
    }
    total
}

/// 按需统计路径大小与文件 / 文件夹数量（用于「计算大小」）。
pub fn dir_size(path: &str) -> Result<Value, String> {
    let p = Path::new(path);
    let meta = std::fs::symlink_metadata(p).map_err(|e| format!("无法读取：{e}"))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Ok(json!({ "size": meta.len(), "files": 1, "dirs": 0 }));
    }
    let mut size = 0u64;
    let mut files = 0u64;
    let mut dirs = 0u64;
    let mut stack = vec![p.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        for item in reader.flatten() {
            let Ok(file_type) = item.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                dirs += 1;
                stack.push(item.path());
            } else if let Ok(meta) = item.metadata() {
                files += 1;
                size += meta.len();
            }
        }
    }
    Ok(json!({ "size": size, "files": files, "dirs": dirs }))
}

fn split_name(name: &str, is_dir: bool) -> (String, String) {
    if is_dir {
        return (name.to_string(), String::new());
    }
    match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i + 1..].to_string()),
        _ => (name.to_string(), String::new()),
    }
}

fn unique_dest(dest_dir: &Path, name: &str, is_dir: bool) -> PathBuf {
    let candidate = dest_dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = split_name(name, is_dir);
    let mut i = 1u32;
    loop {
        let new_name = if ext.is_empty() {
            format!("{stem} ({i})")
        } else {
            format!("{stem} ({i}).{ext}")
        };
        let candidate = dest_dir.join(new_name);
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}

fn transfer(sources: &[String], dest: &str, is_move: bool, job: Option<&Job>) -> Value {
    let dest_dir = Path::new(dest);
    if !dest_dir.is_dir() {
        return json!({ "done": 0, "errors": ["目标不是文件夹"] });
    }

    let mut done = 0u64;
    let mut errors: Vec<String> = Vec::new();

    for src_str in sources {
        if let Some(job) = job {
            if job.is_cancelled() {
                errors.push("已取消".into());
                break;
            }
        }
        let src = Path::new(src_str);
        if !src.exists() && std::fs::symlink_metadata(src).is_err() {
            errors.push(format!("{src_str}：源不存在"));
            continue;
        }
        if let Some(parent) = src.parent() {
            if parent == dest_dir {
                errors.push(format!("{src_str}：源与目标在同一目录"));
                continue;
            }
        }
        let base_name = match src.file_name() {
            Some(n) => n.to_string_lossy().into_owned(),
            None => {
                errors.push(format!("{src_str}：无法获取名称"));
                continue;
            }
        };
        let src_is_dir = src.is_dir();
        let src_size = path_size(src_str);
        let target = unique_dest(dest_dir, &base_name, src_is_dir);

        let result = if is_move {
            match std::fs::rename(src, &target) {
                Ok(_) => {
                    if let Some(job) = job {
                        job.add(src_size);
                    }
                    Ok(())
                }
                // 跨文件系统时退化为复制 + 删除。
                Err(_) => copy_recursive(src, &target, job).and_then(|_| {
                    if src_is_dir {
                        std::fs::remove_dir_all(src)
                    } else {
                        std::fs::remove_file(src)
                    }
                }),
            }
        } else {
            copy_recursive(src, &target, job)
        };

        match result {
            Ok(_) => done += 1,
            Err(e) => errors.push(format!("{src_str}：{e}")),
        }
    }

    json!({ "done": done, "errors": errors })
}

pub fn copy(sources: &[String], dest: &str, job: Option<&Job>) -> Value {
    transfer(sources, dest, false, job)
}

pub fn move_entries(sources: &[String], dest: &str, job: Option<&Job>) -> Value {
    transfer(sources, dest, true, job)
}

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------

pub fn search(root: &str, query: &str, limit: usize) -> Result<Value, String> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Ok(json!({ "entries": [], "truncated": false, "scanned": 0 }));
    }
    let start = Path::new(root);
    if !start.is_dir() {
        return Err("搜索起点不是文件夹".into());
    }

    let mut results: Vec<FileEntry> = Vec::new();
    let mut stack: Vec<PathBuf> = vec![start.to_path_buf()];
    let mut scanned: u64 = 0;
    let mut truncated = false;

    while let Some(dir) = stack.pop() {
        if results.len() >= limit {
            truncated = true;
            break;
        }
        let rd = match std::fs::read_dir(&dir) {
            Ok(r) => r,
            Err(_) => continue,
        };
        for item in rd.flatten() {
            scanned += 1;
            let name = item.file_name().to_string_lossy().into_owned();
            let path = item.path();
            let is_dir = item.file_type().map(|t| t.is_dir()).unwrap_or(false);

            if name.to_lowercase().contains(&q) {
                if let Ok(entry) = build_entry(&path, name) {
                    results.push(entry);
                }
                if results.len() >= limit {
                    truncated = true;
                    break;
                }
            }
            if is_dir {
                stack.push(path);
            }
        }
    }

    sort_entries(&mut results);
    Ok(json!({ "entries": results, "truncated": truncated, "scanned": scanned }))
}

// ---------------------------------------------------------------------------
// 文件读写（二进制）
// ---------------------------------------------------------------------------

pub fn read_bytes(path: &str) -> Result<Vec<u8>, String> {
    let p = Path::new(path);
    let meta = std::fs::metadata(p).map_err(|e| format!("无法读取：{e}"))?;
    if meta.is_dir() {
        return Err("这是一个文件夹".into());
    }
    std::fs::read(p).map_err(|e| format!("读取失败：{e}"))
}

pub fn write_bytes(path: &str, bytes: &[u8]) -> Result<FileEntry, String> {
    let p = Path::new(path);
    if p.is_dir() {
        return Err("目标是文件夹".into());
    }
    let mut f = std::fs::File::create(p).map_err(|e| format!("写入失败：{e}"))?;
    f.write_all(bytes).map_err(|e| format!("写入失败：{e}"))?;
    stat(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dir_size_counts_files_and_dirs() {
        let dir = std::env::temp_dir().join(format!("ordo_dsize_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::write(dir.join("a.bin"), vec![1u8; 100]).unwrap();
        std::fs::write(dir.join("sub/b.bin"), vec![2u8; 50]).unwrap();

        let value = dir_size(&dir.to_string_lossy()).unwrap();
        assert_eq!(value["size"], 150);
        assert_eq!(value["files"], 2);
        assert_eq!(value["dirs"], 1);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn creates_symlink() {
        let dir = std::env::temp_dir().join(format!("ordo_symlink_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("target.txt");
        std::fs::write(&target, b"hi").unwrap();
        let link = dir.join("link.txt");

        let entry = create_symlink(&target.to_string_lossy(), &link.to_string_lossy()).unwrap();
        assert!(entry.is_symlink);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
