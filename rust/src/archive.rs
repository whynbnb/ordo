//! ZIP 压缩 / 解压（纯 Rust `zip`，仅使用 deflate）。

use serde::Serialize;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

use crate::jobs::Job;

#[derive(Debug, Clone, Serialize)]
pub struct ArchiveEntry {
    pub name: String,
    pub size: u64,
    pub compressed: u64,
    pub is_dir: bool,
}

fn cancelled() -> String {
    "已取消".to_string()
}

/// 创建 zip，包含 `sources` 中的文件/文件夹（保留各自原名作为根条目）。
pub fn create(sources: &[String], dest_zip: &str, job: Option<&Job>) -> Result<(), String> {
    if sources.is_empty() {
        return Err("没有要压缩的内容".into());
    }
    if let Some(job) = job {
        let total: u64 = sources.iter().map(|path| crate::api::path_size(path)).sum();
        job.set_total(total);
    }

    let file = File::create(dest_zip).map_err(|e| format!("创建压缩包失败：{e}"))?;
    let mut writer = ZipWriter::new(file);

    for source in sources {
        let path = Path::new(source);
        let Some(name) = path.file_name().map(|n| n.to_string_lossy().into_owned()) else {
            continue;
        };
        add_path(&mut writer, path, &name, job)?;
    }

    writer
        .finish()
        .map_err(|e| format!("写入压缩包失败：{e}"))?;
    Ok(())
}

fn add_path(
    writer: &mut ZipWriter<File>,
    path: &Path,
    entry_name: &str,
    job: Option<&Job>,
) -> Result<(), String> {
    if let Some(job) = job {
        if job.is_cancelled() {
            return Err(cancelled());
        }
    }
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| format!("无法读取 {entry_name}：{e}"))?;
    if meta.file_type().is_symlink() {
        return Ok(());
    }

    if meta.is_dir() {
        let dir_name = format!("{}/", entry_name.trim_end_matches('/'));
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o755);
        writer
            .add_directory(dir_name, options)
            .map_err(|e| format!("写入目录失败：{e}"))?;
        let reader = std::fs::read_dir(path).map_err(|e| format!("无法读取目录：{e}"))?;
        for item in reader.flatten() {
            let child_name = item.file_name().to_string_lossy().into_owned();
            add_path(
                writer,
                &item.path(),
                &format!("{entry_name}/{child_name}"),
                job,
            )?;
        }
    } else {
        let options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o644);
        writer
            .start_file(entry_name.to_string(), options)
            .map_err(|e| format!("写入文件失败：{e}"))?;
        let mut source = File::open(path).map_err(|e| format!("打开失败：{e}"))?;
        let mut buffer = vec![0u8; 64 * 1024];
        loop {
            let read = source
                .read(&mut buffer)
                .map_err(|e| format!("读取失败：{e}"))?;
            if read == 0 {
                break;
            }
            writer
                .write_all(&buffer[..read])
                .map_err(|e| format!("写入失败：{e}"))?;
            if let Some(job) = job {
                job.add(read as u64);
            }
        }
    }
    Ok(())
}

/// 解压到 `dest_dir`（安全处理条目名，阻止目录穿越）。
pub fn extract(zip_path: &str, dest_dir: &str, job: Option<&Job>) -> Result<(), String> {
    let file = File::open(zip_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("不是有效的压缩包：{e}"))?;

    if let Some(job) = job {
        let mut total = 0u64;
        for index in 0..archive.len() {
            if let Ok(entry) = archive.by_index(index) {
                total += entry.size();
            }
        }
        job.set_total(total);
    }

    let dest = PathBuf::from(dest_dir);
    std::fs::create_dir_all(&dest).map_err(|e| format!("创建目录失败：{e}"))?;

    for index in 0..archive.len() {
        if let Some(job) = job {
            if job.is_cancelled() {
                return Err(cancelled());
            }
        }
        let mut entry = archive
            .by_index(index)
            .map_err(|e| format!("读取压缩包失败：{e}"))?;
        // `enclosed_name` 会拒绝 `..` 等越权路径。
        let Some(relative) = entry.enclosed_name() else {
            continue;
        };
        let output = dest.join(relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&output).map_err(|e| format!("创建目录失败：{e}"))?;
        } else {
            if let Some(parent) = output.parent() {
                std::fs::create_dir_all(parent).map_err(|e| format!("创建目录失败：{e}"))?;
            }
            let mut out = File::create(&output).map_err(|e| format!("创建文件失败：{e}"))?;
            std::io::copy(&mut entry, &mut out).map_err(|e| format!("写入失败：{e}"))?;
            if let Some(job) = job {
                job.add(entry.size());
            }
        }
    }
    Ok(())
}

/// 列出压缩包内容。
pub fn list(zip_path: &str) -> Result<Vec<ArchiveEntry>, String> {
    let file = File::open(zip_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("不是有效的压缩包：{e}"))?;
    let mut entries = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|e| format!("读取压缩包失败：{e}"))?;
        entries.push(ArchiveEntry {
            name: entry.name().to_string(),
            size: entry.size(),
            compressed: entry.compressed_size(),
            is_dir: entry.is_dir(),
        });
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_zip_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn zip_roundtrip() {
        let dir = temp("roundtrip");
        std::fs::create_dir_all(dir.join("folder")).unwrap();
        std::fs::write(dir.join("folder/a.txt"), b"hello").unwrap();
        std::fs::write(dir.join("b.txt"), b"world").unwrap();

        let zip_path = dir.join("out.zip").to_string_lossy().into_owned();
        create(
            &[
                dir.join("folder").to_string_lossy().into_owned(),
                dir.join("b.txt").to_string_lossy().into_owned(),
            ],
            &zip_path,
            None,
        )
        .unwrap();

        let entries = list(&zip_path).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert!(names.iter().any(|n| n.contains("a.txt")));
        assert!(names.contains(&"b.txt"));

        let out = dir.join("extract");
        extract(&zip_path, &out.to_string_lossy(), None).unwrap();
        assert_eq!(
            std::fs::read_to_string(out.join("folder/a.txt")).unwrap(),
            "hello"
        );
        assert_eq!(std::fs::read_to_string(out.join("b.txt")).unwrap(), "world");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
