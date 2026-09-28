use super::{normalize_base, ProfileSpec, RemoteEntry, RemoteFs};
use std::io::Cursor;
use suppaftp::types::FileType;
use suppaftp::{FtpStream, Mode};

pub struct FtpRemote {
    stream: FtpStream,
    base: String,
}

impl FtpRemote {
    pub fn connect(profile: &ProfileSpec) -> Result<Self, String> {
        let port = if profile.port == 0 { 21 } else { profile.port };
        let address = format!("{}:{}", profile.host, port);
        let mut stream = FtpStream::connect(&address).map_err(|e| format!("FTP 连接失败：{e}"))?;
        let user = if profile.username.is_empty() {
            "anonymous"
        } else {
            profile.username.as_str()
        };
        let password = if profile.username.is_empty() {
            "anonymous"
        } else {
            profile.password.as_str()
        };
        stream
            .login(user, password)
            .map_err(|e| format!("FTP 登录失败：{e}"))?;
        stream.set_mode(Mode::Passive);
        let _ = stream.transfer_type(FileType::Binary);
        Ok(FtpRemote {
            stream,
            base: normalize_base(&profile.base_path),
        })
    }

    fn full(&self, inner: &str) -> String {
        let base = self.base.trim_end_matches('/');
        if inner == "/" || inner.is_empty() {
            base.to_string()
        } else {
            format!("{base}/{}", inner.trim_start_matches('/'))
        }
    }

    fn entries(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        let path = self.full(inner);
        let target = if path.is_empty() {
            None
        } else {
            Some(path.as_str())
        };

        match self.stream.mlsd(target) {
            Ok(lines) => {
                let mut out = Vec::new();
                for line in lines {
                    if let Some(entry) = parse_mlsd(&line) {
                        out.push(entry);
                    }
                }
                Ok(out)
            }
            Err(_) => {
                // 服务器不支持 MLSD 时退回普通 LIST。
                let lines = self
                    .stream
                    .list(target)
                    .map_err(|e| format!("读取目录失败：{e}"))?;
                Ok(lines.iter().filter_map(|l| parse_list(l)).collect())
            }
        }
    }
}

impl RemoteFs for FtpRemote {
    fn test(&mut self) -> Result<(), String> {
        self.stream
            .noop()
            .map_err(|e| format!("FTP 连接测试失败：{e}"))
    }

    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        self.entries(inner)
    }

    fn stat(&mut self, inner: &str) -> Result<RemoteEntry, String> {
        if inner == "/" || inner.is_empty() {
            return Ok(RemoteEntry {
                name: "/".into(),
                is_dir: true,
                size: 0,
                modified: 0,
            });
        }
        let parent = super::parent_inner(inner);
        let name = inner.trim_end_matches('/').rsplit('/').next().unwrap_or("");
        let entries = self.entries(&parent)?;
        entries
            .into_iter()
            .find(|e| e.name == name)
            .ok_or_else(|| format!("找不到：{name}"))
    }

    fn read(&mut self, inner: &str) -> Result<Vec<u8>, String> {
        let path = self.full(inner);
        let cursor = self
            .stream
            .retr_as_buffer(&path)
            .map_err(|e| format!("下载失败：{e}"))?;
        Ok(cursor.into_inner())
    }

    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String> {
        let path = self.full(inner);
        let mut reader = Cursor::new(data);
        self.stream
            .put_file(&path, &mut reader)
            .map_err(|e| format!("上传失败：{e}"))?;
        Ok(())
    }

    fn mkdir(&mut self, inner: &str) -> Result<(), String> {
        let path = self.full(inner);
        self.stream
            .mkdir(&path)
            .map_err(|e| format!("创建目录失败：{e}"))
    }

    fn remove(&mut self, inner: &str, is_dir: bool) -> Result<(), String> {
        let path = self.full(inner);
        if is_dir {
            self.stream
                .rmdir(&path)
                .map_err(|e| format!("删除目录失败：{e}"))
        } else {
            self.stream.rm(&path).map_err(|e| format!("删除失败：{e}"))
        }
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        let from = self.full(from);
        let to = self.full(to);
        self.stream
            .rename(&from, &to)
            .map_err(|e| format!("重命名失败：{e}"))
    }
}

fn parse_mlsd(line: &str) -> Option<RemoteEntry> {
    let space = line.find(' ')?;
    let facts = &line[..space];
    let name = line[space + 1..].trim_end();
    if name.is_empty() {
        return None;
    }
    let mut is_dir = false;
    let mut size = 0u64;
    let mut modified = 0i64;
    for fact in facts.split(';') {
        if let Some(value) = fact.strip_prefix("type=") {
            match value {
                "dir" => is_dir = true,
                "cdir" | "pdir" => return None,
                _ => {}
            }
        } else if let Some(value) = fact.strip_prefix("size=") {
            size = value.parse().unwrap_or(0);
        } else if let Some(value) = fact.strip_prefix("modify=") {
            modified = parse_ftp_time(value);
        }
    }
    Some(RemoteEntry {
        name: name.to_string(),
        is_dir,
        size: if is_dir { 0 } else { size },
        modified,
    })
}

fn parse_list(line: &str) -> Option<RemoteEntry> {
    let first = line.as_bytes().first().copied()?;
    if first != b'd' && first != b'-' && first != b'l' {
        return None;
    }
    let is_dir = first == b'd';

    // 跳过前 8 个字段（权限/链接/属主/属组/大小/月/日/时间），剩下的是文件名。
    let mut rest = line;
    for _ in 0..8 {
        rest = rest.trim_start();
        let end = rest.find(char::is_whitespace)?;
        rest = &rest[end..];
    }
    let name = rest.trim();
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }

    let tokens: Vec<&str> = line.split_whitespace().collect();
    let size = tokens
        .get(4)
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);

    Some(RemoteEntry {
        name: name.to_string(),
        is_dir,
        size: if is_dir { 0 } else { size },
        modified: 0,
    })
}

/// 解析 `YYYYMMDDHHMMSS[.sss]`。
fn parse_ftp_time(value: &str) -> i64 {
    if value.len() < 14 {
        return 0;
    }
    let num = |a: usize, b: usize| value.get(a..b).and_then(|s| s.parse::<i64>().ok());
    let (Some(year), Some(month), Some(day), Some(hour), Some(minute), Some(second)) = (
        num(0, 4),
        num(4, 6),
        num(6, 8),
        num(8, 10),
        num(10, 12),
        num(12, 14),
    ) else {
        return 0;
    };
    days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let adjusted_month = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * adjusted_month + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}
