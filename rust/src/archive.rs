//! 归档处理：ZIP / TAR / TAR.GZ 的创建、解压与列出。
//!
//! 全部为纯 Rust 实现：`zip`（deflate + AES 加密）、`tar`、`flate2`（rust backend）。

use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::Serialize;
use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use tar::{Archive as TarArchive, Builder as TarBuilder};
use zip::write::SimpleFileOptions;
use zip::{AesMode, CompressionMethod, ZipArchive, ZipWriter};

use crate::jobs::Job;

#[derive(Debug, Clone, Serialize)]
pub struct ArchiveEntry {
    pub name: String,
    pub size: u64,
    pub compressed: u64,
    pub is_dir: bool,
    pub encrypted: bool,
}

/// 归档格式。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Zip,
    Tar,
    TarGz,
}

/// 由扩展名判断格式。
pub fn detect(path: &str) -> Result<Format, String> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".zip") {
        Ok(Format::Zip)
    } else if lower.ends_with(".tar.gz") || lower.ends_with(".tgz") {
        Ok(Format::TarGz)
    } else if lower.ends_with(".tar") {
        Ok(Format::Tar)
    } else {
        Err("不支持的归档格式（支持 zip / tar / tar.gz）".into())
    }
}

fn cancelled() -> String {
    "已取消".to_string()
}

fn require_password() -> String {
    "需要密码".to_string()
}

fn is_password_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("password")
}

// ---------------------------------------------------------------------------
// 创建
// ---------------------------------------------------------------------------

/// 创建归档，格式由 `dest` 扩展名决定；`password` 仅对 ZIP 生效（非空则 AES-256 加密）。
pub fn create(
    sources: &[String],
    dest: &str,
    password: &str,
    job: Option<&Job>,
) -> Result<(), String> {
    if sources.is_empty() {
        return Err("没有要压缩的内容".into());
    }
    if let Some(job) = job {
        let total: u64 = sources.iter().map(|path| crate::api::path_size(path)).sum();
        job.set_total(total);
    }
    match detect(dest)? {
        Format::Zip => create_zip(sources, dest, password, job),
        Format::Tar => {
            let file = File::create(dest).map_err(|e| format!("创建压缩包失败：{e}"))?;
            let mut builder = TarBuilder::new(file);
            for source in sources {
                add_tar(&mut builder, source, job)?;
            }
            builder.finish().map_err(|e| format!("写入压缩包失败：{e}"))
        }
        Format::TarGz => {
            let file = File::create(dest).map_err(|e| format!("创建压缩包失败：{e}"))?;
            let encoder = GzEncoder::new(file, Compression::default());
            let mut builder = TarBuilder::new(encoder);
            for source in sources {
                add_tar(&mut builder, source, job)?;
            }
            builder
                .finish()
                .map_err(|e| format!("写入压缩包失败：{e}"))?;
            let encoder = builder
                .into_inner()
                .map_err(|e| format!("写入压缩包失败：{e}"))?;
            encoder
                .finish()
                .map_err(|e| format!("写入压缩包失败：{e}"))?;
            Ok(())
        }
    }
}

fn create_zip(
    sources: &[String],
    dest: &str,
    password: &str,
    job: Option<&Job>,
) -> Result<(), String> {
    let file = File::create(dest).map_err(|e| format!("创建压缩包失败：{e}"))?;
    let mut writer = ZipWriter::new(file);
    let password = if password.is_empty() {
        None
    } else {
        Some(password)
    };
    for source in sources {
        let path = Path::new(source);
        let Some(name) = path.file_name().map(|n| n.to_string_lossy().into_owned()) else {
            continue;
        };
        add_zip(&mut writer, path, &name, password, job)?;
    }
    writer
        .finish()
        .map_err(|e| format!("写入压缩包失败：{e}"))?;
    Ok(())
}

fn add_zip(
    writer: &mut ZipWriter<File>,
    path: &Path,
    entry_name: &str,
    password: Option<&str>,
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
            add_zip(
                writer,
                &item.path(),
                &format!("{entry_name}/{child_name}"),
                password,
                job,
            )?;
        }
    } else {
        let mut options = SimpleFileOptions::default()
            .compression_method(CompressionMethod::Deflated)
            .unix_permissions(0o644);
        if let Some(password) = password {
            options = options.with_aes_encryption(AesMode::Aes256, password);
        }
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

fn add_tar<W: Write>(
    builder: &mut TarBuilder<W>,
    source: &str,
    job: Option<&Job>,
) -> Result<(), String> {
    let path = Path::new(source);
    let Some(name) = path.file_name().map(|n| n.to_string_lossy().into_owned()) else {
        return Ok(());
    };
    add_tar_path(builder, path, &name, job)
}

fn add_tar_path<W: Write>(
    builder: &mut TarBuilder<W>,
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
        builder
            .append_dir(entry_name, path)
            .map_err(|e| format!("写入目录失败：{e}"))?;
        let reader = std::fs::read_dir(path).map_err(|e| format!("无法读取目录：{e}"))?;
        for item in reader.flatten() {
            let child_name = item.file_name().to_string_lossy().into_owned();
            add_tar_path(
                builder,
                &item.path(),
                &format!("{entry_name}/{child_name}"),
                job,
            )?;
        }
    } else {
        builder
            .append_path_with_name(path, entry_name)
            .map_err(|e| format!("写入文件失败：{e}"))?;
        if let Some(job) = job {
            job.add(meta.len());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 解压
// ---------------------------------------------------------------------------

fn matches_filter(name: &str, only: Option<&str>) -> bool {
    match only {
        None => true,
        Some(target) => {
            let target = target.trim_end_matches('/');
            name.trim_end_matches('/') == target || name.starts_with(&format!("{target}/"))
        }
    }
}

/// 解压到 `dest_dir`。`only` 为 `Some` 时只解压该条目（及其子项）。
pub fn extract(
    archive_path: &str,
    dest_dir: &str,
    password: &str,
    only: Option<&str>,
    job: Option<&Job>,
) -> Result<(), String> {
    let dest = PathBuf::from(dest_dir);
    std::fs::create_dir_all(&dest).map_err(|e| format!("创建目录失败：{e}"))?;
    match detect(archive_path)? {
        Format::Zip => extract_zip(archive_path, &dest, password, only, job),
        Format::Tar => {
            let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
            extract_tar(file, &dest, only)
        }
        Format::TarGz => {
            let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
            extract_tar(GzDecoder::new(file), &dest, only)
        }
    }
}

fn extract_zip(
    archive_path: &str,
    dest: &Path,
    password: &str,
    only: Option<&str>,
    job: Option<&Job>,
) -> Result<(), String> {
    let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("不是有效的压缩包：{e}"))?;

    // 检查是否加密（不触发解密）。
    let mut encrypted = false;
    for index in 0..archive.len() {
        if let Ok(entry) = archive.by_index_raw(index) {
            if entry.encrypted() {
                encrypted = true;
                break;
            }
        }
    }
    if encrypted && password.is_empty() {
        return Err(require_password());
    }

    if let Some(job) = job {
        let mut total = 0u64;
        for index in 0..archive.len() {
            let name = archive.name_for_index(index).unwrap_or("").to_string();
            if !matches_filter(&name, only) {
                continue;
            }
            if let Ok(entry) = archive.by_index_raw(index) {
                total += entry.size();
            }
        }
        job.set_total(total);
    }

    for index in 0..archive.len() {
        if let Some(job) = job {
            if job.is_cancelled() {
                return Err(cancelled());
            }
        }
        let name = archive.name_for_index(index).unwrap_or("").to_string();
        if !matches_filter(&name, only) {
            continue;
        }
        let opened = if encrypted {
            archive.by_index_decrypt(index, password.as_bytes())
        } else {
            archive.by_index(index)
        };
        let mut entry = match opened {
            Ok(entry) => entry,
            Err(error) => {
                let message = error.to_string();
                return Err(if is_password_error(&message) {
                    require_password()
                } else {
                    format!("读取压缩包失败：{message}")
                });
            }
        };
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

fn extract_tar<R: Read>(reader: R, dest: &Path, only: Option<&str>) -> Result<(), String> {
    let mut archive = TarArchive::new(reader);
    archive.set_preserve_permissions(false);
    archive.set_overwrite(true);
    let entries = archive
        .entries()
        .map_err(|e| format!("读取压缩包失败：{e}"))?;
    for entry in entries {
        let mut entry = entry.map_err(|e| format!("读取压缩包失败：{e}"))?;
        if let Some(target) = only {
            let path = entry
                .path()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            if !matches_filter(&path, Some(target)) {
                continue;
            }
        }
        entry
            .unpack_in(dest)
            .map_err(|e| format!("解压失败：{e}"))?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 列出内容
// ---------------------------------------------------------------------------

/// 列出归档内容。
pub fn list(archive_path: &str) -> Result<Vec<ArchiveEntry>, String> {
    match detect(archive_path)? {
        Format::Zip => list_zip(archive_path),
        Format::Tar => {
            let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
            list_tar(file)
        }
        Format::TarGz => {
            let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
            list_tar(GzDecoder::new(file))
        }
    }
}

fn list_zip(archive_path: &str) -> Result<Vec<ArchiveEntry>, String> {
    let file = File::open(archive_path).map_err(|e| format!("打开压缩包失败：{e}"))?;
    let mut archive = ZipArchive::new(file).map_err(|e| format!("不是有效的压缩包：{e}"))?;
    let mut entries = Vec::with_capacity(archive.len());
    for index in 0..archive.len() {
        let entry = archive
            .by_index_raw(index)
            .map_err(|e| format!("读取压缩包失败：{e}"))?;
        entries.push(ArchiveEntry {
            name: entry.name().to_string(),
            size: entry.size(),
            compressed: entry.compressed_size(),
            is_dir: entry.is_dir(),
            encrypted: entry.encrypted(),
        });
    }
    Ok(entries)
}

fn list_tar<R: Read>(reader: R) -> Result<Vec<ArchiveEntry>, String> {
    let mut archive = TarArchive::new(reader);
    let entries = archive
        .entries()
        .map_err(|e| format!("读取压缩包失败：{e}"))?;
    let mut out = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| format!("读取压缩包失败：{e}"))?;
        let header = entry.header();
        let name = entry
            .path()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        out.push(ArchiveEntry {
            name,
            size: header.size().unwrap_or(0),
            compressed: 0,
            is_dir: header.entry_type().is_dir(),
            encrypted: false,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_arc_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn seed(dir: &Path) {
        std::fs::create_dir_all(dir.join("folder")).unwrap();
        std::fs::write(dir.join("folder/a.txt"), b"hello").unwrap();
        std::fs::write(dir.join("b.txt"), b"world").unwrap();
    }

    fn sources(dir: &Path) -> Vec<String> {
        vec![
            dir.join("folder").to_string_lossy().into_owned(),
            dir.join("b.txt").to_string_lossy().into_owned(),
        ]
    }

    #[test]
    fn zip_roundtrip() {
        let dir = temp("zip");
        seed(&dir);
        let archive = dir.join("out.zip").to_string_lossy().into_owned();
        create(&sources(&dir), &archive, "", None).unwrap();

        let entries = list(&archive).unwrap();
        assert!(entries.iter().any(|e| e.name.contains("a.txt")));
        assert!(!entries.iter().any(|e| e.encrypted));

        let out = dir.join("extract");
        extract(&archive, &out.to_string_lossy(), "", None, None).unwrap();
        assert_eq!(
            std::fs::read_to_string(out.join("folder/a.txt")).unwrap(),
            "hello"
        );
        assert_eq!(std::fs::read_to_string(out.join("b.txt")).unwrap(), "world");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn tar_gz_roundtrip() {
        let dir = temp("targz");
        seed(&dir);
        let archive = dir.join("out.tar.gz").to_string_lossy().into_owned();
        create(&sources(&dir), &archive, "", None).unwrap();

        let entries = list(&archive).unwrap();
        assert!(entries.iter().any(|e| e.name.contains("a.txt")));

        let out = dir.join("extract");
        extract(&archive, &out.to_string_lossy(), "", None, None).unwrap();
        assert_eq!(
            std::fs::read_to_string(out.join("folder/a.txt")).unwrap(),
            "hello"
        );
        assert_eq!(std::fs::read_to_string(out.join("b.txt")).unwrap(), "world");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn encrypted_zip_requires_password() {
        let dir = temp("zipenc");
        seed(&dir);
        let archive = dir.join("out.zip").to_string_lossy().into_owned();
        create(&sources(&dir), &archive, "s3cret", None).unwrap();

        let entries = list(&archive).unwrap();
        assert!(entries.iter().any(|e| e.encrypted && !e.is_dir));

        let out = dir.join("nopass");
        let error = extract(&archive, &out.to_string_lossy(), "", None, None).unwrap_err();
        assert_eq!(error, "需要密码");

        let out = dir.join("withpass");
        extract(&archive, &out.to_string_lossy(), "s3cret", None, None).unwrap();
        assert_eq!(std::fs::read_to_string(out.join("b.txt")).unwrap(), "world");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn extracts_single_entry() {
        let dir = temp("single");
        seed(&dir);
        let archive = dir.join("out.zip").to_string_lossy().into_owned();
        create(&sources(&dir), &archive, "", None).unwrap();

        let out = dir.join("only");
        extract(&archive, &out.to_string_lossy(), "", Some("b.txt"), None).unwrap();
        assert!(out.join("b.txt").exists());
        assert!(!out.join("folder/a.txt").exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
