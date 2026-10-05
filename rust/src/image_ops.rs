//! 图片操作（纯 Rust `image`）：旋转。
//!
//! 本地文件原地重编码；远程文件整读后旋转再写回。

use serde_json::{json, Value};
use std::io::Cursor;

fn apply(image: &image::DynamicImage, direction: &str) -> Result<image::DynamicImage, String> {
    Ok(match direction {
        "left" => image.rotate270(),
        "right" => image.rotate90(),
        "180" => image.rotate180(),
        _ => return Err("旋转方向无效".into()),
    })
}

/// 旋转图片（`left` / `right` / `180`），返回新的宽高。
pub fn rotate(path: &str, direction: &str) -> Result<Value, String> {
    if crate::remote::is_remote(path) {
        let data = crate::vfs::read(path)?;
        let image = image::load_from_memory(&data).map_err(|e| format!("无法解码图片：{e}"))?;
        let rotated = apply(&image, direction)?;
        let format = image::ImageFormat::from_path(path)
            .map_err(|_| "不支持该图片格式的旋转".to_string())?;
        let mut buffer = Vec::new();
        rotated
            .write_to(&mut Cursor::new(&mut buffer), format)
            .map_err(|e| format!("编码失败：{e}"))?;
        crate::vfs::write(path, &buffer)?;
        return Ok(json!({ "width": rotated.width(), "height": rotated.height() }));
    }

    let image = image::open(path).map_err(|e| format!("无法解码图片：{e}"))?;
    let rotated = apply(&image, direction)?;
    rotated.save(path).map_err(|e| format!("保存失败：{e}"))?;
    Ok(json!({ "width": rotated.width(), "height": rotated.height() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_swaps_dimensions() {
        let dir = std::env::temp_dir().join(format!("ordo_img_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.png");
        image::RgbImage::from_pixel(4, 2, image::Rgb([255, 0, 0]))
            .save(&path)
            .unwrap();

        let value = rotate(&path.to_string_lossy(), "right").unwrap();
        assert_eq!(value["width"], 2);
        assert_eq!(value["height"], 4);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
