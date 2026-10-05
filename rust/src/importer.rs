//! 从其他应用拖入的文件导入到本地目录。
//!
//! Android 的跨应用拖放会把数据以 `content://` URI 交给接收方。为了不在 Java 侧
//! 读取文件内容，我们在原生层打开该 URI 的文件描述符（fd），并把 fd 交给 Rust：
//! Rust 直接在 fd 上做读写与落盘，保证「文件 IO 都在 Rust」这一原则。

use crate::model::FileEntry;
use std::io::{Read, Write};
use std::os::fd::FromRawFd;
use std::path::{Path, PathBuf};

/// 把已移交所有权的 `fd` 内容写入 `dest_dir/name`（自动去重），返回新文件条目。
///
/// `dest_dir` 可以是本地路径，也可以是远程 URI（`webdav://` / `ftp://` /
/// `smb://`）。调用方需保证 `fd` 可读且未在别处使用；本函数负责在结束时关闭它。
pub fn import_fd(fd: i32, dest_dir: &str, name: &str) -> Result<FileEntry, String> {
    if fd < 0 {
        return Err("无效的文件描述符".into());
    }
    let safe = sanitize(name);
    if crate::remote::is_remote(dest_dir) {
        return import_fd_remote(fd, dest_dir, &safe);
    }
    let dir = Path::new(dest_dir);
    if !dir.is_dir() {
        return Err(format!("目标目录不存在：{dest_dir}"));
    }

    let dest = unique_path(dir, &safe);
    // 接管 fd 的所有权：出错时 File 析构也会关闭它。
    let mut source = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut output = std::fs::File::create(&dest).map_err(|e| format!("创建文件失败：{e}"))?;
    std::io::copy(&mut source, &mut output).map_err(|e| format!("写入失败：{e}"))?;
    output.flush().map_err(|e| format!("写入失败：{e}"))?;
    drop(source);

    crate::api::stat(&dest.to_string_lossy())
}

/// 导入到远程目录：先读入 fd 内容，再通过远程会话写入（自动去重）。
fn import_fd_remote(fd: i32, dest_dir: &str, name: &str) -> Result<FileEntry, String> {
    // 接管 fd 的所有权。
    let mut source = unsafe { std::fs::File::from_raw_fd(fd) };
    let mut data = Vec::new();
    source
        .read_to_end(&mut data)
        .map_err(|e| format!("读取失败：{e}"))?;
    drop(source);

    let target = unique_remote_path(dest_dir, name);
    crate::vfs::write(&target, &data)
}

fn join_remote(dir: &str, name: &str) -> String {
    if dir.ends_with('/') {
        format!("{dir}{name}")
    } else {
        format!("{dir}/{name}")
    }
}

fn unique_remote_path(dir: &str, name: &str) -> String {
    let candidate = join_remote(dir, name);
    if !crate::vfs::exists(&candidate) {
        return candidate;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(index) if index > 0 => (&name[..index], &name[index + 1..]),
        _ => (name, ""),
    };
    let mut index = 1u32;
    loop {
        let new_name = if ext.is_empty() {
            format!("{stem} ({index})")
        } else {
            format!("{stem} ({index}).{ext}")
        };
        let candidate = join_remote(dir, &new_name);
        if !crate::vfs::exists(&candidate) {
            return candidate;
        }
        index += 1;
    }
}

fn sanitize(name: &str) -> String {
    // 只取最后一段，避免 `../../evil` 之类越过目录。
    let base = name.rsplit(['/', '\\']).next().unwrap_or(name);
    let cleaned: String = base
        .chars()
        .map(|c| if c == '\0' { '_' } else { c })
        .collect();
    let trimmed = cleaned.trim().trim_matches('.').trim();
    if trimmed.is_empty() {
        "imported".to_string()
    } else {
        trimmed.to_string()
    }
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(index) if index > 0 => (&name[..index], &name[index + 1..]),
        _ => (name, ""),
    };
    let mut index = 1u32;
    loop {
        let new_name = if ext.is_empty() {
            format!("{stem} ({index})")
        } else {
            format!("{stem} ({index}).{ext}")
        };
        let candidate = dir.join(&new_name);
        if !candidate.exists() {
            return candidate;
        }
        index += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_import_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 创建管道并把 `data` 写入后关闭写端，返回读端 fd。
    fn pipe_with(data: &[u8]) -> i32 {
        let mut fds = [0i32; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let write_fd = fds[1];
        let mut writer = unsafe { std::fs::File::from_raw_fd(write_fd) };
        writer.write_all(data).unwrap();
        drop(writer);
        fds[0]
    }

    #[test]
    fn imports_fd_and_deduplicates() {
        let dir = temp("basic");
        let entry = import_fd(
            pipe_with(b"hello import"),
            &dir.to_string_lossy(),
            "photo.jpg",
        )
        .unwrap();
        assert_eq!(entry.name, "photo.jpg");
        assert_eq!(
            std::fs::read(dir.join("photo.jpg")).unwrap(),
            b"hello import"
        );

        let entry = import_fd(pipe_with(b"second"), &dir.to_string_lossy(), "photo.jpg").unwrap();
        assert_eq!(entry.name, "photo (1).jpg");
        assert_eq!(std::fs::read(dir.join("photo (1).jpg")).unwrap(), b"second");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sanitizes_and_falls_back() {
        let dir = temp("sanitize");
        let entry = import_fd(pipe_with(b"x"), &dir.to_string_lossy(), "../../evil").unwrap();
        assert_eq!(entry.name, "evil");
        assert!(dir.join("evil").exists());

        let entry = import_fd(pipe_with(b"y"), &dir.to_string_lossy(), "...").unwrap();
        assert_eq!(entry.name, "imported");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reads_full_payload() {
        let dir = temp("payload");
        let payload: Vec<u8> = (0..50_000u32).map(|i| (i % 251) as u8).collect();
        let entry = import_fd(pipe_with(&payload), &dir.to_string_lossy(), "big.bin").unwrap();
        assert_eq!(entry.size, payload.len() as u64);
        let mut read = Vec::new();
        std::fs::File::open(dir.join("big.bin"))
            .unwrap()
            .read_to_end(&mut read)
            .unwrap();
        assert_eq!(read, payload);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
