//! 统一文件系统门面：本地路径与远程 URI（`ftp://` / `webdav://` / `smb://`）
//! 走同一套接口，远程部分全部由 Rust 实现。

use crate::api;
use crate::jobs::Job;
use crate::model::FileEntry;
use crate::remote::{self, RemoteEntry};
use serde_json::{json, Value};
use std::path::Path;

fn is_remote(path: &str) -> bool {
    remote::is_remote(path)
}

fn join_uri(base: &str, name: &str) -> String {
    if base.ends_with('/') {
        format!("{base}{name}")
    } else {
        format!("{base}/{name}")
    }
}

fn remote_file_entry(scheme: &str, id: &str, inner: &str, entry: RemoteEntry) -> FileEntry {
    let child_inner = remote::join_inner(inner, &entry.name);
    FileEntry {
        name: entry.name.clone(),
        path: remote::make_path(scheme, id, &child_inner),
        is_dir: entry.is_dir,
        is_symlink: false,
        hidden: entry.name.starts_with('.'),
        size: entry.size,
        modified: entry.modified,
        created: 0,
        extension: if entry.is_dir {
            String::new()
        } else {
            remote::extension_of(&entry.name)
        },
        readable: true,
        writable: true,
    }
}

pub fn list(path: &str) -> Result<Vec<FileEntry>, String> {
    match remote::parse(path) {
        Some((scheme, id, inner)) => {
            let entries = remote::list(&id, &inner)?;
            Ok(entries
                .into_iter()
                .map(|e| remote_file_entry(&scheme, &id, &inner, e))
                .collect())
        }
        None => api::list_dir(path),
    }
}

pub fn stat(path: &str) -> Result<FileEntry, String> {
    match remote::parse(path) {
        Some((scheme, id, inner)) => {
            let entry = remote::stat(&id, &inner)?;
            let mut result = remote_file_entry(&scheme, &id, &inner, entry);
            result.path = remote::make_path(&scheme, &id, &inner);
            Ok(result)
        }
        None => api::stat(path),
    }
}

pub fn exists(path: &str) -> bool {
    stat(path).is_ok()
}

pub fn read(path: &str) -> Result<Vec<u8>, String> {
    match remote::parse(path) {
        Some((_, id, inner)) => remote::read(&id, &inner),
        None => api::read_bytes(path),
    }
}

pub fn write(path: &str, data: &[u8]) -> Result<FileEntry, String> {
    match remote::parse(path) {
        Some((_, id, inner)) => {
            remote::write(&id, &inner, data)?;
            stat(path)
        }
        None => api::write_bytes(path, data),
    }
}

pub fn create_dir(path: &str) -> Result<FileEntry, String> {
    match remote::parse(path) {
        Some((_, id, inner)) => {
            remote::mkdir(&id, &inner)?;
            stat(path)
        }
        None => api::create_dir(path),
    }
}

pub fn create_file(path: &str) -> Result<FileEntry, String> {
    match remote::parse(path) {
        Some((_, id, inner)) => {
            remote::write(&id, &inner, &[])?;
            stat(path)
        }
        None => api::create_file(path),
    }
}

pub fn read_text(path: &str, max_bytes: u64) -> Result<Value, String> {
    if let Some((_, id, inner)) = remote::parse(path) {
        let data = remote::read(&id, &inner)?;
        let size = data.len() as u64;
        let limit = if max_bytes == 0 {
            data.len()
        } else {
            (max_bytes as usize).min(data.len())
        };
        let boundary = floor_char_boundary(&data, limit);
        let content = std::str::from_utf8(&data[..boundary])
            .map_err(|_| "不是文本文件（无法按 UTF-8 解码）".to_string())?;
        return Ok(json!({
            "content": content,
            "truncated": size > boundary as u64,
            "size": size,
        }));
    }
    api::read_text(path, max_bytes)
}

pub fn write_text(path: &str, content: &str) -> Result<FileEntry, String> {
    write(path, content.as_bytes())
}

pub fn remove_one(path: &str) -> Result<(), String> {
    match remote::parse(path) {
        Some((_, id, inner)) => {
            let entry = remote::stat(&id, &inner)?;
            remote::remove(&id, &inner, entry.is_dir)
        }
        None => {
            let result = api::delete(&[path.to_string()]);
            if result["errors"]
                .as_array()
                .map(|a| a.is_empty())
                .unwrap_or(true)
            {
                Ok(())
            } else {
                Err(result["errors"][0]
                    .as_str()
                    .unwrap_or("删除失败")
                    .to_string())
            }
        }
    }
}

pub fn rename(path: &str, new_name: &str) -> Result<FileEntry, String> {
    if new_name.is_empty()
        || new_name.contains('/')
        || new_name.contains('\0')
        || new_name == "."
        || new_name == ".."
    {
        return Err("名称无效".into());
    }

    let src_remote = remote::parse(path);
    let dest = match &src_remote {
        Some((scheme, id, inner)) => {
            let parent = remote::parent_inner(inner);
            let child = remote::join_inner(&parent, new_name);
            remote::make_path(scheme, id, &child)
        }
        None => {
            let parent = Path::new(path).parent().unwrap_or_else(|| Path::new("/"));
            parent.join(new_name).to_string_lossy().into_owned()
        }
    };

    let dest_remote = remote::parse(&dest);
    match (&src_remote, &dest_remote) {
        (Some((s1, id1, inner1)), Some((s2, id2, inner2))) if s1 == s2 && id1 == id2 => {
            remote::rename(id1, inner1, inner2)?;
        }
        (None, None) => {
            return api::rename(path, new_name);
        }
        _ => {
            copy_entry(path, &dest, None)?;
            remove_one(path)?;
        }
    }
    stat(&dest)
}

fn copy_entry(source: &str, dest: &str, job: Option<&Job>) -> Result<(), String> {
    if let Some(job) = job {
        if job.is_cancelled() {
            return Err("已取消".into());
        }
    }
    let meta = stat(source)?;
    if meta.is_dir {
        ensure_dir(dest)?;
        for child in list(source)? {
            let target = join_uri(dest, &child.name);
            copy_entry(&child.path, &target, job)?;
        }
    } else {
        let data = read(source)?;
        if let Some(job) = job {
            job.add(data.len() as u64);
        }
        write(dest, &data)?;
    }
    Ok(())
}

fn ensure_dir(path: &str) -> Result<(), String> {
    match create_dir(path) {
        Ok(_) => Ok(()),
        Err(e) => {
            if exists(path) {
                Ok(())
            } else {
                Err(e)
            }
        }
    }
}

fn unique_target(dir: &str, name: &str, is_dir: bool) -> String {
    let candidate = join_uri(dir, name);
    if !exists(&candidate) {
        return candidate;
    }
    let (stem, ext) = split_name(name, is_dir);
    let mut index = 1u32;
    loop {
        let new_name = if ext.is_empty() {
            format!("{stem} ({index})")
        } else {
            format!("{stem} ({index}).{ext}")
        };
        let candidate = join_uri(dir, &new_name);
        if !exists(&candidate) {
            return candidate;
        }
        index += 1;
    }
}

fn split_name(name: &str, is_dir: bool) -> (String, String) {
    if is_dir {
        return (name.to_string(), String::new());
    }
    match name.rfind('.') {
        Some(index) if index > 0 => (name[..index].to_string(), name[index + 1..].to_string()),
        _ => (name.to_string(), String::new()),
    }
}

fn source_size(source: &str) -> u64 {
    if let Some((_, id, inner)) = remote::parse(source) {
        remote::stat(&id, &inner)
            .map(|entry| if entry.is_dir { 0 } else { entry.size })
            .unwrap_or(0)
    } else {
        api::path_size(source)
    }
}

fn measure(sources: &[String]) -> u64 {
    sources.iter().map(|source| source_size(source)).sum()
}

fn transfer(sources: &[String], dest: &str, is_move: bool, job: Option<&Job>) -> Value {
    if stat(dest).map(|e| !e.is_dir).unwrap_or(true) {
        return json!({ "done": 0, "errors": ["目标不是文件夹"] });
    }
    if let Some(job) = job {
        job.set_total(measure(sources));
    }

    let mut done = 0u64;
    let mut errors: Vec<String> = Vec::new();

    for source in sources {
        if let Some(job) = job {
            if job.is_cancelled() {
                errors.push("已取消".into());
                break;
            }
        }
        if !exists(source) {
            errors.push(format!("{source}：源不存在"));
            continue;
        }
        let name = match source.trim_end_matches('/').rsplit('/').next() {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => {
                errors.push(format!("{source}：无法获取名称"));
                continue;
            }
        };
        let is_dir = stat(source).map(|e| e.is_dir).unwrap_or(false);

        let source_remote = remote::parse(source);
        let dest_remote = remote::parse(dest);
        let same_location = match (&source_remote, &dest_remote) {
            (Some((s1, id1, _)), Some((s2, id2, _))) => s1 == s2 && id1 == id2,
            (None, None) => true,
            _ => false,
        };

        if !same_location {
            // 跨存储：先复制再按需删除。
            let target = unique_target(dest, &name, is_dir);
            let result = copy_entry(source, &target, job).and_then(|_| {
                if is_move {
                    remove_one(source)
                } else {
                    Ok(())
                }
            });
            match result {
                Ok(_) => done += 1,
                Err(e) => errors.push(format!("{source}：{e}")),
            }
            continue;
        }

        // 同一存储：交给本地/远程各自的实现，保留“自动改名”语义。
        if let Some((_, id, from_inner)) = source_remote {
            let target = unique_target(dest, &name, is_dir);
            let result = if is_move {
                let (_, _, to_inner) = remote::parse(&target).expect("target is remote");
                remote::rename(&id, &from_inner, &to_inner)
            } else {
                copy_entry(source, &target, job)
            };
            match result {
                Ok(_) => done += 1,
                Err(e) => errors.push(format!("{source}：{e}")),
            }
        } else {
            let result = if is_move {
                api::move_entries(std::slice::from_ref(source), dest, job)
            } else {
                api::copy(std::slice::from_ref(source), dest, job)
            };
            let count = result["done"].as_u64().unwrap_or(0);
            if count > 0 {
                done += count;
            }
            if let Some(list) = result["errors"].as_array() {
                for item in list {
                    errors.push(item.as_str().unwrap_or_default().to_string());
                }
            }
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

pub fn search(root: &str, query: &str, limit: usize) -> Result<Value, String> {
    if is_remote(root) {
        return Err("网络位置暂不支持搜索".into());
    }
    api::search(root, query, limit)
}

fn floor_char_boundary(data: &[u8], mut index: usize) -> usize {
    if index >= data.len() {
        return data.len();
    }
    while index > 0 && (data[index] & 0xC0) == 0x80 {
        index -= 1;
    }
    index
}
