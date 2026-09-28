//! Ordo 安序 —— 文件系统核心。
//!
//! 所有文件操作都在 Rust 侧完成，通过一层极简的 C ABI 暴露给 Flutter。
//! 每个导出函数接收 UTF-8 字符串，返回一段 JSON：`{"ok":true,"data":...}`
//! 或 `{"ok":false,"error":"..."}`。字符串内存由 Rust 分配，调用方使用
//! [`ordo_free_string`] 释放。

mod api;
mod model;

use serde::Serialize;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

// ---------------------------------------------------------------------------
// JSON 与内存辅助
// ---------------------------------------------------------------------------

fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"error\":\"invalid utf8\"}")
            .unwrap()
            .into_raw(),
    }
}

fn ok<T: Serialize>(data: T) -> *mut c_char {
    into_c_string(serde_json::json!({ "ok": true, "data": data }).to_string())
}

fn result<T: Serialize>(r: Result<T, String>) -> *mut c_char {
    match r {
        Ok(data) => ok(data),
        Err(err) => into_c_string(serde_json::json!({ "ok": false, "error": err }).to_string()),
    }
}

unsafe fn read_str(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("收到的参数为空".into());
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(str::to_owned)
        .map_err(|e| format!("参数不是有效的 UTF-8：{e}"))
}

unsafe fn read_paths(ptr: *const c_char) -> Result<Vec<String>, String> {
    let raw = read_str(ptr)?;
    serde_json::from_str::<Vec<String>>(&raw).map_err(|e| format!("路径列表无效：{e}"))
}

/// 捕获 panic，避免任何意外让进程崩溃。
fn guard<F: FnOnce() -> *mut c_char>(f: F) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(ptr) => ptr,
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "内部错误".to_string()
            };
            into_c_string(serde_json::json!({ "ok": false, "error": msg }).to_string())
        }
    }
}

// ---------------------------------------------------------------------------
// 导出函数
// ---------------------------------------------------------------------------

/// 释放由本库返回的字符串。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// 列出目录内容。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_list_dir(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(api::list_dir(&p)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 获取单个路径的元数据。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_stat(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(api::stat(&p)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 读取文本文件。`max_bytes` 为 0 表示不限制。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_read_text(path: *const c_char, max_bytes: u64) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(api::read_text(&p, max_bytes)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 写入文本文件（覆盖）。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_write_text(
    path: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    guard(|| match (read_str(path), read_str(content)) {
        (Ok(p), Ok(c)) => result(api::write_text(&p, &c)),
        (Err(e), _) | (_, Err(e)) => {
            into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
        }
    })
}

/// 创建文件夹（含父级）。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_create_dir(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(api::create_dir(&p)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 创建空文件。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_create_file(path: *const c_char) -> *mut c_char {
    guard(|| match read_str(path) {
        Ok(p) => result(api::create_file(&p)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 递归删除一组路径。入参为 JSON 字符串数组。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_delete(paths: *const c_char) -> *mut c_char {
    guard(|| match read_paths(paths) {
        Ok(list) => ok(api::delete(&list)),
        Err(e) => into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string()),
    })
}

/// 重命名（仅改名，不移动目录）。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_rename(path: *const c_char, new_name: *const c_char) -> *mut c_char {
    guard(|| match (read_str(path), read_str(new_name)) {
        (Ok(p), Ok(n)) => result(api::rename(&p, &n)),
        (Err(e), _) | (_, Err(e)) => {
            into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
        }
    })
}

/// 复制一组路径到目标文件夹。入参为 JSON 字符串数组。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_copy(sources: *const c_char, dest: *const c_char) -> *mut c_char {
    guard(|| match (read_paths(sources), read_str(dest)) {
        (Ok(src), Ok(d)) => ok(api::copy(&src, &d)),
        (Err(e), _) | (_, Err(e)) => {
            into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
        }
    })
}

/// 移动一组路径到目标文件夹。入参为 JSON 字符串数组。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_move(sources: *const c_char, dest: *const c_char) -> *mut c_char {
    guard(|| match (read_paths(sources), read_str(dest)) {
        (Ok(src), Ok(d)) => ok(api::move_entries(&src, &d)),
        (Err(e), _) | (_, Err(e)) => {
            into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
        }
    })
}

/// 在 `root` 下按名称递归搜索。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_search(
    root: *const c_char,
    query: *const c_char,
    limit: u32,
) -> *mut c_char {
    guard(|| match (read_str(root), read_str(query)) {
        (Ok(r), Ok(q)) => result(api::search(&r, &q, limit as usize)),
        (Err(e), _) | (_, Err(e)) => {
            into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
        }
    })
}

/// 列出可用的存储卷。
#[no_mangle]
pub extern "C" fn ordo_storage_roots() -> *mut c_char {
    guard(|| ok(api::storage_roots()))
}

/// 读取任意文件的原始字节，返回指针并通过 `out_len` 回传长度。
/// 调用方处理后必须调用 [`ordo_free_bytes`]。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_read_bytes(path: *const c_char, out_len: *mut usize) -> *mut u8 {
    if !out_len.is_null() {
        *out_len = 0;
    }
    let path = match read_str(path) {
        Ok(p) => p,
        Err(_) => return std::ptr::null_mut(),
    };
    match catch_unwind(AssertUnwindSafe(|| api::read_bytes(&path))) {
        Ok(Ok(bytes)) => {
            let boxed = bytes.into_boxed_slice();
            let len = boxed.len();
            if !out_len.is_null() {
                *out_len = len;
            }
            Box::into_raw(boxed) as *mut u8
        }
        _ => std::ptr::null_mut(),
    }
}

/// 释放 [`ordo_read_bytes`] 返回的内存。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let slice = std::slice::from_raw_parts_mut(ptr, len);
        drop(Box::from_raw(slice as *mut [u8]));
    }
}

/// 写入原始字节。
/// # Safety
/// FFI 边界：传入的指针必须指向合法的、以 NUL 结尾的 UTF-8 字符串
/// （`ordo_read_bytes` / `ordo_write_bytes` 的缓冲区除外），且在本调用期间保持有效。
#[no_mangle]
pub unsafe extern "C" fn ordo_write_bytes(
    path: *const c_char,
    data: *const u8,
    len: usize,
) -> *mut c_char {
    guard(|| {
        let p = match read_str(path) {
            Ok(p) => p,
            Err(e) => {
                return into_c_string(serde_json::json!({ "ok": false, "error": e }).to_string())
            }
        };
        if data.is_null() && len > 0 {
            return into_c_string(
                serde_json::json!({ "ok": false, "error": "数据为空" }).to_string(),
            );
        }
        let slice = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(data, len)
        };
        result(api::write_bytes(&p, slice))
    })
}

/// 简单连通性检查，供 Dart 侧确认动态库已加载。
#[no_mangle]
pub extern "C" fn ordo_ping() -> *mut c_char {
    guard(|| {
        into_c_string(
            serde_json::json!({
                "ok": true,
                "data": { "name": "Ordo", "core": "ordo_core", "version": env!("CARGO_PKG_VERSION") }
            })
            .to_string(),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_test_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn list_and_sort_dirs_first() {
        let dir = temp("list");
        fs::create_dir(dir.join("beta")).unwrap();
        fs::write(dir.join("file10.txt"), b"x").unwrap();
        fs::write(dir.join("file2.txt"), b"x").unwrap();

        let entries = api::list_dir(dir.to_str().unwrap()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["beta", "file2.txt", "file10.txt"]);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn copy_then_move_and_delete() {
        let dir = temp("copy");
        let src = dir.join("a.txt");
        fs::write(&src, b"hello").unwrap();
        let dst = dir.join("sub");
        fs::create_dir(&dst).unwrap();

        let copied = api::copy(&[src.to_string_lossy().into_owned()], dst.to_str().unwrap());
        assert_eq!(copied["done"], 1);
        assert!(dst.join("a.txt").exists());

        let moved = api::move_entries(&[src.to_string_lossy().into_owned()], dst.to_str().unwrap());
        assert_eq!(moved["done"], 1);
        assert!(dst.join("a (1).txt").exists());
        assert!(!src.exists());

        let removed = api::delete(&[dir.to_string_lossy().into_owned()]);
        assert_eq!(removed["deleted"], 1);
    }

    #[test]
    fn search_finds_matches() {
        let dir = temp("search");
        fs::create_dir_all(dir.join("nested")).unwrap();
        fs::write(dir.join("nested/report.txt"), b"x").unwrap();
        fs::write(dir.join("other.txt"), b"x").unwrap();

        let found = api::search(dir.to_str().unwrap(), "report", 50).unwrap();
        assert_eq!(found["entries"].as_array().unwrap().len(), 1);

        let all = api::search(dir.to_str().unwrap(), ".txt", 50).unwrap();
        assert_eq!(all["entries"].as_array().unwrap().len(), 2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn read_text_roundtrip() {
        let dir = temp("text");
        let file = dir.join("note.md");
        api::write_text(file.to_str().unwrap(), "# 标题").unwrap();
        let read = api::read_text(file.to_str().unwrap(), 0).unwrap();
        assert_eq!(read["content"], "# 标题");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn rename_rejects_path_separator() {
        let dir = temp("rename");
        let file = dir.join("x");
        fs::write(&file, b"").unwrap();
        assert!(api::rename(file.to_str().unwrap(), "a/b").is_err());
        assert!(api::rename(file.to_str().unwrap(), "y").is_ok());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn ffi_ping_is_ok() {
        unsafe {
            let ptr = ordo_ping();
            let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
            ordo_free_string(ptr);
            assert!(s.contains("\"ok\":true"));
        }
    }
}
