//! 存储卷发现。
//!
//! 目标：稳定地找出内部存储、可移动存储卡，以及可插拔的 USB 存储（U 盘 / 移动硬盘）。
//!
//! Android 上同一块可移动介质通常有两个挂载点：
//! - `/mnt/media_rw/<UUID>`：vold 的真实块设备挂载（通常应用不可读）；
//! - `/storage/<UUID>`：给应用看的 FUSE 视图（拥有「所有文件访问权限」时可读）。
//!
//! 因此这里解析 `/proc/self/mountinfo`，按 UUID 把两者配对，优先选择应用可读的路径，
//! 并通过 `/sys/dev/block/<maj>:<min>` 判断底层块设备名来区分 USB（`sd*`）与存储卡（`mmcblk*`）。
//! Android 侧还会通过 `StorageManager` 提供更友好的名称，见 [`set_hints`]。

use crate::model::StorageRoot;
use serde::Deserialize;
use std::collections::HashMap;
use std::ffi::CString;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

const INTERNAL_STORAGE: &str = "/storage/emulated/0";

/// Android `StorageManager` 提供的卷信息（用于命名与兜底）。
#[derive(Debug, Clone, Deserialize, Default)]
pub struct StorageHint {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub removable: bool,
    #[serde(default)]
    pub primary: bool,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub uuid: String,
}

static HINTS: OnceLock<Mutex<Vec<StorageHint>>> = OnceLock::new();

fn hints_cell() -> &'static Mutex<Vec<StorageHint>> {
    HINTS.get_or_init(|| Mutex::new(Vec::new()))
}

/// 由 FFI 写入来自 Android 的卷信息。
pub fn set_hints(list: Vec<StorageHint>) {
    if let Ok(mut guard) = hints_cell().lock() {
        *guard = list;
    }
}

fn snapshot_hints() -> Vec<StorageHint> {
    hints_cell()
        .lock()
        .map(|guard| guard.clone())
        .unwrap_or_default()
}

struct Mount {
    mount_point: String,
    fs_type: String,
    dev: String,
}

struct Volume {
    key: String,
    path: String,
    kind: String,
    name: String,
    total: u64,
    free: u64,
    readable: bool,
}

// ---------------------------------------------------------------------------
// 对外入口
// ---------------------------------------------------------------------------

pub fn storage_roots() -> Vec<StorageRoot> {
    let hints = snapshot_hints();
    let mut volumes = discover_mount_volumes(&hints);
    add_hint_only_volumes(&hints, &mut volumes);
    if volumes.is_empty() {
        scan_fallback(&mut volumes);
    }

    volumes.sort_by(|a, b| {
        rank(&a.kind)
            .cmp(&rank(&b.kind))
            .then_with(|| a.name.cmp(&b.name))
    });

    let mut roots: Vec<StorageRoot> = Vec::new();
    if Path::new(INTERNAL_STORAGE).is_dir() {
        roots.push(make_root("内部存储", INTERNAL_STORAGE, "internal", false));
    }
    for volume in volumes {
        roots.push(StorageRoot {
            name: volume.name,
            path: volume.path,
            kind: volume.kind,
            total: volume.total,
            free: volume.free,
            removable: true,
            readable: volume.readable,
        });
    }
    roots
}

fn rank(kind: &str) -> u8 {
    match kind {
        "internal" => 0,
        "external" => 1,
        "usb" => 2,
        _ => 3,
    }
}

fn make_root(name: &str, path: &str, kind: &str, removable: bool) -> StorageRoot {
    let (total, free) = disk_space(path);
    StorageRoot {
        name: name.to_string(),
        path: path.to_string(),
        kind: kind.to_string(),
        total,
        free,
        removable,
        readable: std::fs::read_dir(path).is_ok(),
    }
}

// ---------------------------------------------------------------------------
// 挂载点解析
// ---------------------------------------------------------------------------

fn unescape_mount(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

fn read_mounts() -> Vec<Mount> {
    let mut mounts: Vec<Mount> = Vec::new();
    if let Ok(text) = std::fs::read_to_string("/proc/self/mountinfo") {
        for line in text.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 7 {
                continue;
            }
            let Some(separator) = parts.iter().position(|p| *p == "-") else {
                continue;
            };
            if parts.len() <= separator + 2 {
                continue;
            }
            mounts.push(Mount {
                mount_point: unescape_mount(parts[4]),
                fs_type: parts[separator + 1].to_string(),
                dev: parts[2].to_string(),
            });
        }
    }
    if mounts.is_empty() {
        if let Ok(text) = std::fs::read_to_string("/proc/mounts") {
            for line in text.lines() {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() < 3 {
                    continue;
                }
                mounts.push(Mount {
                    mount_point: unescape_mount(parts[1]),
                    fs_type: parts[2].to_string(),
                    dev: String::new(),
                });
            }
        }
    }
    mounts
}

/// 是否为可能是「外部介质」的挂载点。
fn candidate_external(mount_point: &str) -> bool {
    let trimmed = mount_point.trim_end_matches('/');
    if trimmed == INTERNAL_STORAGE
        || trimmed.starts_with("/storage/emulated")
        || trimmed.starts_with("/storage/enc_emulated")
        || trimmed == "/storage/self"
    {
        return false;
    }
    const PREFIXES: &[&str] = &[
        "/storage/",
        "/mnt/media_rw/",
        "/mnt/usb",
        "/mnt/sdcard",
        "/mnt/ext",
        "/mnt/external",
        "/mnt/sd",
    ];
    PREFIXES.iter().any(|prefix| trimmed.starts_with(prefix))
}

fn is_pseudo(fs_type: &str) -> bool {
    const PSEUDO: &[&str] = &[
        "proc",
        "sysfs",
        "devpts",
        "tmpfs",
        "devtmpfs",
        "cgroup",
        "cgroup2",
        "pstore",
        "bpf",
        "tracefs",
        "debugfs",
        "securityfs",
        "sockfs",
        "binder",
        "hwbinder",
        "vndbinder",
        "configfs",
        "functionfs",
        "fusectl",
        "overlay",
        "overlayfs",
        "nsfs",
        "ramfs",
        "rootfs",
        "autofs",
        "mqueue",
        "hugetlbfs",
        "selinuxfs",
        "none",
    ];
    PSEUDO.contains(&fs_type)
}

fn volume_key(mount_point: &str) -> String {
    mount_point
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

fn path_score(path: &str) -> i32 {
    if path.starts_with("/storage/") {
        30
    } else if path.starts_with("/mnt/media_rw/") {
        20
    } else {
        10
    }
}

fn choose_path(entries: &[Mount]) -> Option<String> {
    let mut best: Option<(&str, i32)> = None;
    for mount in entries {
        let readable = std::fs::read_dir(&mount.mount_point).is_ok();
        let score = path_score(&mount.mount_point) + if readable { 100 } else { 0 };
        if best.map(|(_, current)| score > current).unwrap_or(true) {
            best = Some((&mount.mount_point, score));
        }
    }
    best.map(|(path, _)| path.to_string())
}

/// 由 `MAJ:MIN` 解析 `/sys/dev/block/<dev>` 得到块设备名，如 `sda1`、`mmcblk1p1`。
fn sys_block_name(dev: &str) -> Option<String> {
    if dev.is_empty() {
        return None;
    }
    let target = std::fs::read_link(format!("/sys/dev/block/{dev}")).ok()?;
    let name = target.file_name()?.to_string_lossy().into_owned();
    if name.is_empty() || name.contains("fuse") {
        None
    } else {
        Some(name)
    }
}

fn base_block(name: &str) -> String {
    match name.find(|c: char| c.is_ascii_digit()) {
        None => name.to_string(),
        Some(index) => {
            let stem = &name[..index];
            if stem.ends_with("mmcblk") || stem.ends_with("nvme") {
                return match name[index..].find('p') {
                    Some(offset) => name[..index + offset].to_string(),
                    // 没有分区标记，说明它本身就是整块磁盘。
                    None => name.to_string(),
                };
            }
            stem.to_string()
        }
    }
}

fn classify(dev_name: Option<&str>, description: &str) -> String {
    if let Some(name) = dev_name {
        let base = base_block(name);
        if base.starts_with("sd") || base.starts_with("usb") {
            return "usb".to_string();
        }
        if base.starts_with("mmc") || base.starts_with("nvme") || base.starts_with("vd") {
            return "external".to_string();
        }
    }
    if description.to_lowercase().contains("usb") {
        return "usb".to_string();
    }
    "external".to_string()
}

fn default_name(kind: &str, key: &str) -> String {
    match kind {
        "usb" => format!("USB 存储 ({key})"),
        _ => format!("存储卡 ({key})"),
    }
}

fn match_hint<'a>(hints: &'a [StorageHint], key: &str, path: &str) -> Option<&'a StorageHint> {
    hints.iter().find(|hint| {
        if hint.primary {
            return false;
        }
        if !hint.uuid.is_empty() && hint.uuid.eq_ignore_ascii_case(key) {
            return true;
        }
        if let Some(hint_path) = hint.path.as_deref() {
            let hint_path = hint_path.trim_end_matches('/');
            if !hint_path.is_empty() {
                if hint_path == path.trim_end_matches('/') {
                    return true;
                }
                if hint_path.rsplit('/').next() == Some(key) {
                    return true;
                }
            }
        }
        false
    })
}

fn discover_mount_volumes(hints: &[StorageHint]) -> Vec<Volume> {
    let mut groups: HashMap<String, Vec<Mount>> = HashMap::new();
    for mount in read_mounts() {
        if is_pseudo(&mount.fs_type) {
            continue;
        }
        if !candidate_external(&mount.mount_point) {
            continue;
        }
        // 注意：这里不要求挂载点当前可读 / 可枚举。已挂载的卷即使应用暂时
        // 无权访问（例如挂载命名空间尚未同步），也应出现在列表里，只是标记为
        // 不可读，而不是整卷消失。
        let key = volume_key(&mount.mount_point);
        if key.is_empty() {
            continue;
        }
        groups.entry(key).or_default().push(mount);
    }

    let mut volumes = Vec::new();
    for (key, entries) in groups {
        let Some(path) = choose_path(&entries) else {
            continue;
        };
        let dev_name = entries.iter().find_map(|mount| sys_block_name(&mount.dev));
        let hint = match_hint(hints, &key, &path);
        let description = hint.map(|h| h.description.clone()).unwrap_or_default();
        let kind = classify(dev_name.as_deref(), &description);
        let name = if description.is_empty() {
            default_name(&kind, &key)
        } else {
            description
        };
        let (total, free) = disk_space(&path);
        let readable = std::fs::read_dir(&path).is_ok();
        volumes.push(Volume {
            key,
            path,
            kind,
            name,
            total,
            free,
            readable,
        });
    }
    volumes
}

/// 补上 `/proc` 中看不到、但 Android 明确告知且可访问的可移动卷。
fn add_hint_only_volumes(hints: &[StorageHint], volumes: &mut Vec<Volume>) {
    for hint in hints {
        if hint.primary || !hint.removable {
            continue;
        }
        if !hint.state.is_empty() && hint.state != "mounted" && hint.state != "mounted_ro" {
            continue;
        }
        let Some(path) = hint.path.as_deref() else {
            continue;
        };
        let path = path.trim_end_matches('/');
        if path.is_empty() {
            continue;
        }
        let key = volume_key(path);
        if key.is_empty() || volumes.iter().any(|v| v.key == key || v.path == path) {
            continue;
        }
        // 只要 Android 报告该卷已挂载，就保留它；路径暂时不可访问时
        // `readable` 会为 false，界面会提示「未开放访问」，而不是直接隐藏。
        let kind = classify(None, &hint.description);
        let name = if hint.description.is_empty() {
            default_name(&kind, &key)
        } else {
            hint.description.clone()
        };
        let (total, free) = disk_space(path);
        volumes.push(Volume {
            key,
            path: path.to_string(),
            kind,
            name,
            total,
            free,
            readable: std::fs::read_dir(path).map(|_| true).unwrap_or(false),
        });
    }
}

/// 兜底：直接扫描常见的挂载目录。
fn scan_fallback(volumes: &mut Vec<Volume>) {
    const ROOTS: &[&str] = &[
        "/storage",
        "/mnt/media_rw",
        "/mnt/usb",
        "/mnt/usbhost",
        "/mnt/usbhost1",
        "/mnt/sdcard",
        "/mnt/extSdCard",
        "/mnt/external_sd",
    ];
    for root in ROOTS {
        let Ok(reader) = std::fs::read_dir(root) else {
            continue;
        };
        for item in reader.flatten() {
            let name = item.file_name().to_string_lossy().into_owned();
            if matches!(name.as_str(), "emulated" | "self" | "enc_emulated") {
                continue;
            }
            let path = item.path();
            if !path.is_dir() {
                continue;
            }
            let path = path.to_string_lossy().into_owned();
            if volumes.iter().any(|v| v.key == name || v.path == path) {
                continue;
            }
            let kind = classify(None, &name);
            let (total, free) = disk_space(&path);
            volumes.push(Volume {
                key: name.clone(),
                path: path.clone(),
                kind: kind.clone(),
                name: default_name(&kind, &name),
                total,
                free,
                readable: std::fs::read_dir(&path).map(|_| true).unwrap_or(false),
            });
        }
    }
}

fn disk_space(path: &str) -> (u64, u64) {
    let Ok(c_path) = CString::new(path) else {
        return (0, 0);
    };
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c_path.as_ptr(), &mut stat) == 0 {
            let block = stat.f_frsize as u64;
            (stat.f_blocks as u64 * block, stat.f_bavail as u64 * block)
        } else {
            (0, 0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_names_strip_partitions() {
        assert_eq!(base_block("sda"), "sda");
        assert_eq!(base_block("sda1"), "sda");
        assert_eq!(base_block("mmcblk1"), "mmcblk1");
        assert_eq!(base_block("mmcblk1p1"), "mmcblk1");
        assert_eq!(base_block("nvme0n1p1"), "nvme0n1");
    }

    #[test]
    fn classify_usb_and_sd() {
        assert_eq!(classify(Some("sda1"), ""), "usb");
        assert_eq!(classify(Some("mmcblk1p1"), ""), "external");
        assert_eq!(classify(None, "SanDisk USB drive"), "usb");
        assert_eq!(classify(None, "SD 卡"), "external");
    }

    #[test]
    fn volume_key_from_mount_point() {
        assert_eq!(volume_key("/storage/1234-5678/"), "1234-5678");
        assert_eq!(volume_key("/mnt/media_rw/1234-5678"), "1234-5678");
    }
}
