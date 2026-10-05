//! EXIF / 媒体信息解析（纯 Rust）。
//!
//! 图片读取尺寸与 EXIF（拍摄时间、相机、方向）；其它类型只返回基本信息。
//! 远程文件会先整读，再在内存中解析。

use crate::vfs;
use exif::{In, Reader, Tag};
use serde_json::{json, Map, Value};
use std::fs::File;
use std::io::{BufReader, Cursor};

fn is_image(extension: &str) -> bool {
    matches!(
        extension,
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "heic" | "heif" | "avif" | "tiff" | "tif"
    )
}

/// 返回 `{size, extension, width?, height?, date_taken?, camera?, orientation?}`。
pub fn info(path: &str) -> Result<Value, String> {
    let entry = vfs::stat(path)?;
    let extension = entry.extension.to_ascii_lowercase();
    let mut map = Map::new();
    map.insert("size".into(), json!(entry.size));
    map.insert("extension".into(), json!(extension));

    if !is_image(&extension) {
        return Ok(Value::Object(map));
    }

    let remote = crate::remote::is_remote(path);
    let data = if remote { Some(vfs::read(path)?) } else { None };

    if let Some((width, height)) = dimensions(path, data.as_deref()) {
        map.insert("width".into(), json!(width));
        map.insert("height".into(), json!(height));
    }

    if let Some(fields) = read_exif(path, data.as_deref()) {
        for (key, value) in fields {
            map.insert(key, value);
        }
    }

    Ok(Value::Object(map))
}

fn dimensions(path: &str, data: Option<&[u8]>) -> Option<(u32, u32)> {
    if let Some(data) = data {
        let reader = image::ImageReader::new(Cursor::new(data))
            .with_guessed_format()
            .ok()?;
        reader.into_dimensions().ok()
    } else {
        let file = File::open(path).ok()?;
        let reader = image::ImageReader::new(BufReader::new(file))
            .with_guessed_format()
            .ok()?;
        reader.into_dimensions().ok()
    }
}

fn read_exif(path: &str, data: Option<&[u8]>) -> Option<Vec<(String, Value)>> {
    let exif = if let Some(data) = data {
        Reader::new()
            .read_from_container(&mut BufReader::new(Cursor::new(data)))
            .ok()?
    } else {
        Reader::new()
            .read_from_container(&mut BufReader::new(File::open(path).ok()?))
            .ok()?
    };

    let mut out: Vec<(String, Value)> = Vec::new();
    let text = |tag: Tag| {
        exif.get_field(tag, In::PRIMARY)
            .map(|field| field.display_value().with_unit(&exif).to_string())
    };

    if let Some(value) = text(Tag::DateTimeOriginal) {
        out.push(("date_taken".into(), json!(value)));
    }
    match (text(Tag::Make), text(Tag::Model)) {
        (Some(make), Some(model)) => out.push(("camera".into(), json!(format!("{make} {model}")))),
        (Some(make), None) => out.push(("camera".into(), json!(make))),
        (None, Some(model)) => out.push(("camera".into(), json!(model))),
        (None, None) => {}
    }
    if let Some(field) = exif.get_field(Tag::Orientation, In::PRIMARY) {
        out.push((
            "orientation".into(),
            json!(field.display_value().to_string()),
        ));
    }
    if let Some(field) = exif.get_field(Tag::FNumber, In::PRIMARY) {
        out.push(("f_number".into(), json!(field.display_value().to_string())));
    }
    if let Some(field) = exif.get_field(Tag::ExposureTime, In::PRIMARY) {
        out.push((
            "exposure_time".into(),
            json!(field.display_value().to_string()),
        ));
    }
    if let Some(field) = exif.get_field(Tag::ISOSpeed, In::PRIMARY) {
        out.push(("iso".into(), json!(field.display_value().to_string())));
    }

    Some(out)
}
