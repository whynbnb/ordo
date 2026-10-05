//! 二维码生成（纯 Rust）：`qrcode` 生成矩阵，`image` 编码为 PNG。

use std::io::Cursor;

/// 生成二维码 PNG 字节；`scale` 为每个模块的像素大小。
pub fn png(text: &str, scale: u32) -> Result<Vec<u8>, String> {
    let code = qrcode::QrCode::new(text.as_bytes()).map_err(|e| format!("生成二维码失败：{e}"))?;
    let width = code.width();
    let colors = code.to_colors();
    let scale = scale.clamp(1, 24);
    let border = 2 * scale;
    let size = width as u32 * scale + border * 2;

    let mut image = image::GrayImage::new(size, size);
    for pixel in image.pixels_mut() {
        *pixel = image::Luma([255u8]);
    }
    for y in 0..width {
        for x in 0..width {
            if colors[y * width + x] != qrcode::Color::Dark {
                continue;
            }
            for dy in 0..scale {
                for dx in 0..scale {
                    let px = border + x as u32 * scale + dx;
                    let py = border + y as u32 * scale + dy;
                    image.put_pixel(px, py, image::Luma([0u8]));
                }
            }
        }
    }

    let mut buffer = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut buffer), image::ImageFormat::Png)
        .map_err(|e| format!("编码二维码失败：{e}"))?;
    Ok(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_png() {
        let png = png("hello ordo", 4).unwrap();
        assert_eq!(&png[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
    }
}
