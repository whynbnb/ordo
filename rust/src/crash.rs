//! 崩溃 / 错误日志：落地到应用私有目录，便于排查问题。

use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;

fn log_path() -> Option<PathBuf> {
    crate::remote::config_dir().map(|dir| dir.join("ordo_crash.log"))
}

fn timestamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02}",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

/// Howard Hinnant 的 days -> (y, m, d)。
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 追加一条日志。
pub fn append(text: &str) {
    let Some(path) = log_path() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(file, "[{}] {}", timestamp(), text);
    }
}

/// 安装 panic 钩子（只安装一次）。
pub fn install_hook() {
    static INSTALLED: OnceLock<()> = OnceLock::new();
    if INSTALLED.set(()).is_err() {
        return;
    }
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        append(&format!("PANIC: {info}"));
        previous(info);
    }));
}

/// 读取日志内容。
pub fn read() -> Value {
    let path = log_path();
    let text = path
        .as_ref()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    let lines = text.lines().count();
    json!({
        "path": path.map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
        "text": text,
        "lines": lines,
    })
}

/// 清空日志。
pub fn clear() -> Result<(), String> {
    if let Some(path) = log_path() {
        if path.exists() {
            std::fs::remove_file(&path).map_err(|e| format!("清除日志失败：{e}"))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(19_723), (2024, 1, 1));
    }
}
