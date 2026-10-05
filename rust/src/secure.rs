//! 安全删除：覆盖写后再删除（SSD 上由于磨损均衡意义有限，但可减少残留）。

use serde_json::{json, Value};
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const BUFFER: usize = 64 * 1024;

fn seed() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e37_79b9_7f4a_7c15)
        ^ (std::process::id() as u64)
}

fn fill_random(buffer: &mut [u8], state: &mut u64) {
    for chunk in buffer.chunks_mut(8) {
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        let bytes = state.to_le_bytes();
        for (dst, src) in chunk.iter_mut().zip(bytes.iter()) {
            *dst = *src;
        }
    }
}

fn overwrite_file(path: &Path, passes: u32) -> std::io::Result<()> {
    let len = std::fs::metadata(path)?.len();
    if len == 0 {
        return Ok(());
    }
    let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
    let mut buffer = vec![0u8; BUFFER];
    let mut state = seed() | 1;
    for _ in 0..passes.max(1) {
        file.seek(SeekFrom::Start(0))?;
        let mut remaining = len;
        while remaining > 0 {
            let n = remaining.min(BUFFER as u64) as usize;
            fill_random(&mut buffer[..n], &mut state);
            file.write_all(&buffer[..n])?;
            remaining -= n as u64;
        }
        file.flush()?;
    }
    file.set_len(0)?;
    file.sync_all()?;
    Ok(())
}

fn wipe(path: &Path, passes: u32, errors: &mut Vec<String>) {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return;
    };
    if meta.is_dir() {
        if let Ok(reader) = std::fs::read_dir(path) {
            for item in reader.flatten() {
                wipe(&item.path(), passes, errors);
            }
        }
        if let Err(e) = std::fs::remove_dir(path) {
            errors.push(format!("{}: {e}", path.display()));
        }
    } else if meta.file_type().is_symlink() {
        let _ = std::fs::remove_file(path);
    } else {
        if let Err(e) = overwrite_file(path, passes) {
            errors.push(format!("{}: {e}", path.display()));
        }
        if let Err(e) = std::fs::remove_file(path) {
            errors.push(format!("{}: {e}", path.display()));
        }
    }
}

/// 覆盖写后删除给定路径。
pub fn secure_delete(paths: &[String], passes: u32) -> Value {
    let mut deleted = 0u64;
    let mut errors: Vec<String> = Vec::new();
    for raw in paths {
        let path = PathBuf::from(raw);
        if !path.exists() {
            errors.push(format!("{raw}: 不存在"));
            continue;
        }
        if crate::remote::is_remote(raw) {
            errors.push(format!("{raw}: 远程路径不支持安全删除"));
            continue;
        }
        wipe(&path, passes, &mut errors);
        if !path.exists() {
            deleted += 1;
        }
    }
    json!({ "deleted": deleted, "errors": errors })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wipes_file_and_dir() {
        let dir = std::env::temp_dir().join(format!("ordo_secure_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        let secret = dir.join("secret.bin");
        std::fs::write(&secret, vec![7u8; 4096]).unwrap();
        std::fs::write(dir.join("sub/nested.txt"), b"nested").unwrap();

        let result = secure_delete(&[dir.to_string_lossy().into_owned()], 2);
        assert_eq!(result["deleted"], 1);
        assert!(result["errors"].as_array().unwrap().is_empty());
        assert!(!dir.exists());
    }
}
