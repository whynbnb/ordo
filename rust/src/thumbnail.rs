//! 图片缩略图：用纯 Rust 解码 + 缩放，缓存到应用缓存目录。
//!
//! Flutter 侧不直接读文件，缩略图字节经 FFI 返回。缓存键包含路径、修改时间、
//! 大小与目标尺寸，文件变化时自动失效。

use image::ImageFormat;
use sha2::{Digest, Sha256};

pub fn thumbnail(path: &str, max_px: u32) -> Result<Vec<u8>, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("无法读取：{e}"))?;
    let px = max_px.clamp(32, 1024);
    let key = cache_key(path, &meta, px);

    if let Some(cache) = cache_file(&key) {
        if let Ok(bytes) = std::fs::read(&cache) {
            if !bytes.is_empty() {
                return Ok(bytes);
            }
        }
    }

    let image = image::open(path).map_err(|e| format!("无法解析图片：{e}"))?;
    let thumb = image.thumbnail(px, px).to_rgb8();
    let mut output = Vec::new();
    thumb
        .write_to(&mut std::io::Cursor::new(&mut output), ImageFormat::Jpeg)
        .map_err(|e| format!("编码缩略图失败：{e}"))?;

    if let Some(cache) = cache_file(&key) {
        if let Some(parent) = cache.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&cache, &output);
    }

    Ok(output)
}

fn cache_key(path: &str, meta: &std::fs::Metadata, px: u32) -> String {
    let modified = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let mut hasher = Sha256::new();
    hasher.update(path.as_bytes());
    hasher.update(modified.to_le_bytes());
    hasher.update(meta.len().to_le_bytes());
    hasher.update(px.to_le_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn cache_file(key: &str) -> Option<std::path::PathBuf> {
    crate::remote::cache_dir().map(|dir| dir.join("thumbs").join(format!("{key}.jpg")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_and_caches_thumbnail() {
        let dir = std::env::temp_dir().join(format!("ordo_thumb_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        crate::remote::init(
            &dir.join("cfg").to_string_lossy(),
            &dir.join("cache").to_string_lossy(),
        );

        // 生成一张 400x200 的 PNG。
        let path = dir.join("big.png");
        let img = image::RgbImage::from_fn(400, 200, |x, _| image::Rgb([(x % 256) as u8, 80, 160]));
        img.save(&path).unwrap();

        let bytes = thumbnail(&path.to_string_lossy(), 100).unwrap();
        assert!(bytes.len() > 100);
        // 第二次应命中缓存，得到相同结果。
        let again = thumbnail(&path.to_string_lossy(), 100).unwrap();
        assert_eq!(bytes, again);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
