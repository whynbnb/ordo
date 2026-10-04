//! 存储分析：分类占用、最大文件、重复文件。
//!
//! 只读扫描，可取消；重复文件按「同大小 → 全文件哈希」两级筛选，避免无谓读取。

use crate::jobs::Job;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize)]
pub struct CategoryStat {
    pub category: String,
    pub size: u64,
    pub count: u64,
}

#[derive(Debug, Serialize)]
pub struct FileRef {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub category: String,
}

#[derive(Debug, Serialize)]
pub struct DuplicateGroup {
    pub size: u64,
    pub hash: String,
    pub files: Vec<FileRef>,
}

#[derive(Debug, Serialize)]
pub struct AnalyzeResult {
    pub root: String,
    pub total_size: u64,
    pub file_count: u64,
    pub dir_count: u64,
    pub categories: Vec<CategoryStat>,
    pub largest: Vec<FileRef>,
    pub duplicates: Vec<DuplicateGroup>,
}

const LARGEST_LIMIT: usize = 50;
const DUPLICATE_LIMIT: usize = 50;
const MIN_DUPLICATE_SIZE: u64 = 4 * 1024;
const MAX_CANDIDATES: usize = 3000;

pub fn analyze(root: &str, job: Option<&Job>) -> Result<AnalyzeResult, String> {
    let root_path = PathBuf::from(root);
    if !root_path.is_dir() {
        return Err("分析起点不是文件夹".into());
    }

    let mut total_size = 0u64;
    let mut file_count = 0u64;
    let mut dir_count = 0u64;
    let mut scanned = 0u64;

    let mut category_size: HashMap<&'static str, u64> = HashMap::new();
    let mut category_count: HashMap<&'static str, u64> = HashMap::new();
    let mut largest: Vec<(u64, PathBuf)> = Vec::new();
    let mut size_groups: HashMap<u64, Vec<PathBuf>> = HashMap::new();

    let mut stack = vec![root_path.clone()];
    while let Some(dir) = stack.pop() {
        if let Some(job) = job {
            if job.is_cancelled() {
                return Err("已取消".into());
            }
        }
        let Ok(reader) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in reader.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                dir_count += 1;
                stack.push(entry.path());
                continue;
            }
            let Ok(meta) = entry.metadata() else {
                continue;
            };
            let path = entry.path();
            let size = meta.len();
            let category = category_of(&path);
            file_count += 1;
            total_size += size;
            *category_size.entry(category).or_insert(0) += size;
            *category_count.entry(category).or_insert(0) += 1;

            largest.push((size, path.clone()));
            if largest.len() > LARGEST_LIMIT * 4 {
                largest.sort_by_key(|(size, _)| std::cmp::Reverse(*size));
                largest.truncate(LARGEST_LIMIT);
            }
            if size >= MIN_DUPLICATE_SIZE {
                size_groups.entry(size).or_default().push(path);
            }

            scanned += 1;
            if let Some(job) = job {
                if scanned.is_multiple_of(128) {
                    job.add(128);
                }
            }
        }
    }

    let mut categories: Vec<CategoryStat> = category_size
        .into_iter()
        .map(|(category, size)| CategoryStat {
            category: category.to_string(),
            size,
            count: *category_count.get(category).unwrap_or(&0),
        })
        .collect();
    categories.sort_by_key(|stat| std::cmp::Reverse(stat.size));

    largest.sort_by_key(|(size, _)| std::cmp::Reverse(*size));
    largest.truncate(LARGEST_LIMIT);
    let largest_refs: Vec<FileRef> = largest
        .into_iter()
        .map(|(size, path)| make_ref(&path, size))
        .collect();

    // 重复文件：仅对「同大小且 >= 4KB」的候选做哈希，并限制总数。
    let mut candidates: Vec<PathBuf> = Vec::new();
    for (_, files) in size_groups {
        if files.len() > 1 {
            candidates.extend(files);
        }
        if candidates.len() >= MAX_CANDIDATES {
            break;
        }
    }
    candidates.truncate(MAX_CANDIDATES);

    let mut by_hash: HashMap<String, Vec<PathBuf>> = HashMap::new();
    let mut hashed = 0u64;
    for path in candidates {
        if let Some(job) = job {
            if job.is_cancelled() {
                return Err("已取消".into());
            }
        }
        if let Some(hash) = hash_file(&path) {
            by_hash.entry(hash).or_default().push(path);
        }
        hashed += 1;
        if let Some(job) = job {
            if hashed.is_multiple_of(32) {
                job.add(32);
            }
        }
    }

    let mut duplicates: Vec<DuplicateGroup> = Vec::new();
    for (hash, files) in by_hash {
        if files.len() < 2 {
            continue;
        }
        let size = std::fs::metadata(&files[0]).map(|m| m.len()).unwrap_or(0);
        duplicates.push(DuplicateGroup {
            size,
            hash,
            files: files.iter().map(|p| make_ref(p, size)).collect(),
        });
    }
    // 按可回收空间（size × (n-1)）排序。
    duplicates.sort_by_key(|group| std::cmp::Reverse(group.size * (group.files.len() as u64 - 1)));
    duplicates.truncate(DUPLICATE_LIMIT);

    Ok(AnalyzeResult {
        root: root.to_string(),
        total_size,
        file_count,
        dir_count,
        categories,
        largest: largest_refs,
        duplicates,
    })
}

fn make_ref(path: &Path, size: u64) -> FileRef {
    FileRef {
        path: path.to_string_lossy().into_owned(),
        name: path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
        size,
        category: category_of(path).to_string(),
    }
}

fn hash_file(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).ok()?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Some(
        hasher
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    )
}

fn category_of(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "heic" | "heif" | "avif" | "svg" => {
            "image"
        }
        "mp4" | "mkv" | "avi" | "mov" | "webm" | "3gp" | "flv" | "wmv" | "m4v" => "video",
        "mp3" | "wav" | "flac" | "aac" | "ogg" | "m4a" | "wma" | "opus" | "amr" => "audio",
        "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "odt" | "ods" => "document",
        "zip" | "rar" | "7z" | "tar" | "gz" | "bz2" | "xz" | "tgz" | "iso" => "archive",
        "apk" | "apks" | "xapk" => "apk",
        "txt" | "md" | "markdown" | "json" | "xml" | "yaml" | "yml" | "csv" | "log" | "ini"
        | "conf" | "toml" | "dart" | "js" | "ts" | "py" | "rs" | "java" | "kt" | "c" | "h"
        | "cpp" | "html" | "htm" | "css" | "sql" => "text",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_largest_and_duplicates() {
        let dir = std::env::temp_dir().join(format!("ordo_analyze_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        std::fs::write(dir.join("big.bin"), vec![1u8; 10_000]).unwrap();
        std::fs::write(dir.join("dup1.bin"), vec![2u8; 5_000]).unwrap();
        std::fs::write(dir.join("dup2.bin"), vec![2u8; 5_000]).unwrap();
        std::fs::write(dir.join("small.txt"), b"hi").unwrap();

        let result = analyze(&dir.to_string_lossy(), None).unwrap();
        assert_eq!(result.file_count, 4);
        assert_eq!(result.largest[0].name, "big.bin");
        assert_eq!(result.duplicates.len(), 1);
        assert_eq!(result.duplicates[0].files.len(), 2);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
