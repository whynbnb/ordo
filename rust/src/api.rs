use crate::model::{build_entry, FileEntry, StorageRoot};
use serde_json::{json, Value};
use std::cmp::Ordering;
use std::ffi::CString;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

const INTERNAL_STORAGE: &str = "/storage/emulated/0";

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

fn copy_recursive(src: &Path, dest: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(src)?;
    if meta.file_type().is_symlink() {
        // 跳过符号链接，避免循环与越权复制。
        return Ok(());
    }
    if meta.is_dir() {
        std::fs::create_dir_all(dest)?;
        for item in std::fs::read_dir(src)? {
            let item = item?;
            copy_recursive(&item.path(), &dest.join(item.file_name()))?;
        }
        Ok(())
    } else {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::copy(src, dest)?;
        Ok(())
    }
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

fn transfer(sources: &[String], dest: &str, is_move: bool) -> Value {
    let dest_dir = Path::new(dest);
    if !dest_dir.is_dir() {
        return json!({ "done": 0, "errors": ["目标不是文件夹"] });
    }

    let mut done = 0u64;
    let mut errors: Vec<String> = Vec::new();

    for src_str in sources {
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
        let target = unique_dest(dest_dir, &base_name, src_is_dir);

        let result = if is_move {
            match std::fs::rename(src, &target) {
                Ok(_) => Ok(()),
                // 跨文件系统时退化为复制 + 删除。
                Err(_) => copy_recursive(src, &target).and_then(|_| {
                    if src_is_dir {
                        std::fs::remove_dir_all(src)
                    } else {
                        std::fs::remove_file(src)
                    }
                }),
            }
        } else {
            copy_recursive(src, &target)
        };

        match result {
            Ok(_) => done += 1,
            Err(e) => errors.push(format!("{src_str}：{e}")),
        }
    }

    json!({ "done": done, "errors": errors })
}

pub fn copy(sources: &[String], dest: &str) -> Value {
    transfer(sources, dest, false)
}

pub fn move_entries(sources: &[String], dest: &str) -> Value {
    transfer(sources, dest, true)
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
// 存储卷
// ---------------------------------------------------------------------------

fn disk_space(path: &str) -> (u64, u64) {
    let Ok(c_path) = CString::new(path) else {
        return (0, 0);
    };
    unsafe {
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c_path.as_ptr(), &mut st) == 0 {
            let block = st.f_frsize as u64;
            (st.f_blocks as u64 * block, st.f_bavail as u64 * block)
        } else {
            (0, 0)
        }
    }
}

fn make_root(name: &str, path: &str, kind: &str, removable: bool) -> StorageRoot {
    let (total, free) = disk_space(path);
    StorageRoot {
        name: name.to_string(),
        path: path.to_string(),
        kind: kind.to_string(),
        total,
        free,
        removable,
    }
}

pub fn storage_roots() -> Vec<StorageRoot> {
    let mut roots: Vec<StorageRoot> = Vec::new();

    if Path::new(INTERNAL_STORAGE).is_dir() {
        roots.push(make_root("内部存储", INTERNAL_STORAGE, "internal", false));
    }

    if let Ok(rd) = std::fs::read_dir("/storage") {
        let mut external: Vec<(String, String)> = Vec::new();
        for item in rd.flatten() {
            let name = item.file_name().to_string_lossy().into_owned();
            if name == "emulated" || name == "self" || name == "enc_emulated" {
                continue;
            }
            let p = item.path();
            if p.is_dir() {
                external.push((name, p.to_string_lossy().into_owned()));
            }
        }
        external.sort_by(|a, b| a.0.cmp(&b.0));
        for (id, path) in external {
            roots.push(make_root(
                &format!("存储卡 ({id})"),
                &path,
                "external",
                true,
            ));
        }
    }

    roots
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
