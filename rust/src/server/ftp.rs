//! 极简 FTP 服务端（纯 Rust）。
//!
//! 支持文件管理器常用的命令：登录、目录切换、列表（LIST/NLST/MLSD/MLST）、
//! 下载（RETR）、上传（STOR/APPE）、删除、新建/删除目录、重命名、SIZE、MDTM。
//! 数据连接同时支持被动（PASV/EPSV）与主动（PORT/EPRT）模式。
//! 为保持简单，仅支持明文 FTP（不实现 FTPS）。

use super::fsutil;
use super::ServerCtx;
use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

pub fn bind(port: u16) -> Result<TcpListener, String> {
    TcpListener::bind(("0.0.0.0", port)).map_err(|e| format!("FTP 端口 {port} 绑定失败：{e}"))
}

pub fn serve(listener: TcpListener, ctx: Arc<ServerCtx>, stop: Arc<AtomicBool>) {
    let _ = listener.set_nonblocking(true);
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                // accept 出来的连接可能继承监听套接字的非阻塞标志，这里显式改回阻塞。
                let _ = stream.set_nonblocking(false);
                let ctx = ctx.clone();
                std::thread::spawn(move || {
                    let _ = handle_client(stream, ctx);
                });
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(120));
            }
            Err(_) => std::thread::sleep(Duration::from_millis(120)),
        }
    }
}

fn handle_client(stream: TcpStream, ctx: Arc<ServerCtx>) -> std::io::Result<()> {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(600)));
    let local_ip = stream
        .local_addr()
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".to_string());
    let peer = stream
        .peer_addr()
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "-".to_string());
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);

    let root = ctx.root.clone();
    let read_only = ctx.read_only;
    ctx.activity.record("ftp", &peer, "CONNECT", "", 200);
    write_line(&mut writer, "220 Ordo FTP server ready")?;

    let mut session = Session {
        ctx,
        root,
        read_only,
        peer,
        cwd: "/".to_string(),
        data: DataMode::None,
        rename_from: None,
        authenticated: false,
        local_ip,
        pending_user: String::new(),
    };

    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => break,
        }
        let line = line.trim_end_matches(['\r', '\n']);
        let (command, argument) = match line.split_once(' ') {
            Some((cmd, arg)) => (cmd.to_ascii_uppercase(), arg.to_string()),
            None => (line.to_ascii_uppercase(), String::new()),
        };
        if !session.handle(&command, &argument, &mut writer)? {
            break;
        }
    }
    Ok(())
}

fn write_line(writer: &mut TcpStream, line: &str) -> std::io::Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.write_all(b"\r\n")?;
    writer.flush()
}

enum DataMode {
    None,
    Passive(TcpListener),
    Active(SocketAddr),
}

struct Session {
    ctx: Arc<ServerCtx>,
    root: PathBuf,
    read_only: bool,
    peer: String,
    cwd: String,
    data: DataMode,
    rename_from: Option<PathBuf>,
    authenticated: bool,
    local_ip: String,
    pending_user: String,
}

const PRE_AUTH: &[&str] = &[
    "USER", "PASS", "QUIT", "FEAT", "SYST", "NOOP", "OPTS", "AUTH", "PBSZ", "PROT", "TYPE",
];

/// 记录到访问日志的命令。
const LOGGED: &[&str] = &[
    "RETR", "STOR", "APPE", "DELE", "MKD", "XMKD", "RMD", "XRMD", "RNTO", "LIST", "NLST", "MLSD",
    "CWD",
];

impl Session {
    fn handle(
        &mut self,
        command: &str,
        argument: &str,
        writer: &mut TcpStream,
    ) -> std::io::Result<bool> {
        if !self.authenticated && !PRE_AUTH.contains(&command) {
            write_line(writer, "530 Please login with USER and PASS.")?;
            return Ok(true);
        }

        if LOGGED.contains(&command) {
            self.ctx
                .activity
                .record("ftp", &self.peer, command, argument, 200);
        }

        match command {
            "USER" => {
                if !self.ctx.users.is_empty() || self.ctx.auth {
                    self.pending_user = argument.to_string();
                    self.authenticated = false;
                    write_line(writer, "331 User name okay, need password.")?;
                } else {
                    self.authenticated = true;
                    write_line(writer, "230 Anonymous login enabled.")?;
                }
            }
            "PASS" => {
                let matched = self
                    .ctx
                    .users
                    .iter()
                    .find(|u| u.username == self.pending_user && u.password == argument)
                    .cloned();
                if let Some(user) = matched {
                    self.root = if user.path.trim().is_empty() {
                        self.ctx.root.clone()
                    } else {
                        fsutil::resolve_rel(&self.ctx.root, user.path.trim())
                            .unwrap_or_else(|| self.ctx.root.clone())
                    };
                    self.read_only = self.ctx.read_only || user.read_only;
                    self.authenticated = true;
                    self.cwd = "/".to_string();
                    self.ctx
                        .activity
                        .record("ftp", &self.peer, "LOGIN", &user.username, 200);
                    write_line(writer, "230 Login successful.")?;
                } else if self.ctx.users.is_empty()
                    && (!self.ctx.auth
                        || (self.pending_user == self.ctx.username
                            && argument == self.ctx.password))
                {
                    self.authenticated = true;
                    let who = if self.ctx.auth {
                        self.pending_user.clone()
                    } else {
                        "anonymous".to_string()
                    };
                    self.ctx
                        .activity
                        .record("ftp", &self.peer, "LOGIN", &who, 200);
                    write_line(writer, "230 Login successful.")?;
                } else {
                    write_line(writer, "530 Login incorrect.")?;
                }
            }
            "AUTH" => write_line(writer, "502 AUTH not supported.")?,
            "PBSZ" => write_line(writer, "200 PBSZ=0")?,
            "PROT" => write_line(writer, "200 Protection level set to C")?,
            "SYST" => write_line(writer, "215 UNIX Type: L8")?,
            "FEAT" => {
                writer.write_all(b"211-Features:\r\n")?;
                for feature in [
                    " UTF8",
                    " EPSV",
                    " PASV",
                    " SIZE",
                    " MDTM",
                    " MLSD",
                    " MLST type*;size*;modify*;",
                ] {
                    writer.write_all(feature.as_bytes())?;
                    writer.write_all(b"\r\n")?;
                }
                write_line(writer, "211 End")?;
            }
            "OPTS" => {
                if argument.to_ascii_uppercase().contains("UTF8") {
                    write_line(writer, "200 UTF8 enabled.")?;
                } else {
                    write_line(writer, "501 Option not understood.")?;
                }
            }
            "NOOP" => write_line(writer, "200 OK")?,
            "QUIT" => {
                write_line(writer, "221 Goodbye.")?;
                return Ok(false);
            }
            "TYPE" => write_line(writer, "200 Type set.")?,
            "MODE" => write_line(writer, "200 Mode set to S.")?,
            "STRU" => write_line(writer, "200 Structure set to F.")?,
            "PWD" | "XPWD" => {
                let cwd = self.cwd.replace('"', "\"\"");
                write_line(writer, &format!("257 \"{cwd}\" is current directory."))?;
            }
            "CWD" => {
                if let Some(path) = self.fs_path(argument) {
                    if path.is_dir() {
                        self.cwd = ftp_join(&self.cwd, argument);
                        write_line(writer, "250 Directory changed.")?;
                    } else {
                        write_line(writer, "550 Not a directory.")?;
                    }
                } else {
                    write_line(writer, "550 Not a directory.")?;
                }
            }
            "CDUP" => {
                self.cwd = ftp_join(&self.cwd, "..");
                write_line(writer, "250 Directory changed.")?;
            }
            "PASV" => self.enter_passive(writer, false)?,
            "EPSV" => self.enter_passive(writer, true)?,
            "PORT" => self.set_active(argument, writer)?,
            "EPRT" => self.set_active_extended(argument, writer)?,
            "LIST" => self.send_listing(argument, Listing::Unix, writer)?,
            "NLST" => self.send_listing(argument, Listing::Names, writer)?,
            "MLSD" => self.send_listing(argument, Listing::Machine, writer)?,
            "MLST" => self.send_single_listing(argument, writer)?,
            "RETR" => self.retrieve(argument, writer)?,
            "STOR" => self.store(argument, false, writer)?,
            "APPE" => self.store(argument, true, writer)?,
            "DELE" => {
                if self.read_only {
                    write_line(writer, "550 Read-only server.")?;
                } else if let Some(path) = self.fs_path(argument) {
                    if path.is_file() && std::fs::remove_file(&path).is_ok() {
                        write_line(writer, "250 File deleted.")?;
                    } else {
                        write_line(writer, "550 Delete failed.")?;
                    }
                } else {
                    write_line(writer, "550 Delete failed.")?;
                }
            }
            "MKD" | "XMKD" => {
                if self.read_only {
                    write_line(writer, "550 Read-only server.")?;
                } else if let Some(path) = self.fs_path(argument) {
                    if std::fs::create_dir(&path).is_ok() {
                        write_line(writer, "257 Directory created.")?;
                    } else {
                        write_line(writer, "550 Create failed.")?;
                    }
                } else {
                    write_line(writer, "550 Create failed.")?;
                }
            }
            "RMD" | "XRMD" => {
                if self.read_only {
                    write_line(writer, "550 Read-only server.")?;
                } else if let Some(path) = self.fs_path(argument) {
                    if std::fs::remove_dir(&path).is_ok() {
                        write_line(writer, "250 Directory removed.")?;
                    } else {
                        write_line(writer, "550 Remove failed.")?;
                    }
                } else {
                    write_line(writer, "550 Remove failed.")?;
                }
            }
            "RNFR" => {
                if let Some(path) = self.fs_path(argument) {
                    if path.exists() {
                        self.rename_from = Some(path);
                        write_line(writer, "350 Ready for destination name.")?;
                    } else {
                        write_line(writer, "550 File not found.")?;
                    }
                } else {
                    write_line(writer, "550 File not found.")?;
                }
            }
            "RNTO" => {
                if self.read_only {
                    write_line(writer, "550 Read-only server.")?;
                    self.rename_from = None;
                } else {
                    match (self.rename_from.take(), self.fs_path(argument)) {
                        (Some(from), Some(to)) if std::fs::rename(&from, &to).is_ok() => {
                            write_line(writer, "250 Renamed.")?;
                        }
                        _ => write_line(writer, "550 Rename failed.")?,
                    }
                }
            }
            "SIZE" => {
                if let Some(path) = self.fs_path(argument) {
                    if path.is_file() {
                        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                        write_line(writer, &format!("213 {size}"))?;
                    } else {
                        write_line(writer, "550 Not a file.")?;
                    }
                } else {
                    write_line(writer, "550 Not a file.")?;
                }
            }
            "MDTM" => {
                if let Some(path) = self.fs_path(argument) {
                    if let Ok(meta) = std::fs::metadata(&path) {
                        let stamp = fsutil::format_timestamp(modified_secs(&meta));
                        write_line(writer, &format!("213 {stamp}"))?;
                    } else {
                        write_line(writer, "550 File not found.")?;
                    }
                } else {
                    write_line(writer, "550 File not found.")?;
                }
            }
            "ABOR" => write_line(writer, "226 Abort successful.")?,
            _ => write_line(writer, "502 Command not implemented.")?,
        }
        Ok(true)
    }

    fn fs_path(&self, argument: &str) -> Option<PathBuf> {
        let ftp_path = ftp_join(&self.cwd, argument);
        fsutil::resolve_rel(&self.root, ftp_path.trim_start_matches('/'))
    }

    fn enter_passive(&mut self, writer: &mut TcpStream, extended: bool) -> std::io::Result<()> {
        match TcpListener::bind(("0.0.0.0", 0)) {
            Ok(listener) => {
                let port = listener.local_addr().map(|a| a.port()).unwrap_or(0);
                self.data = DataMode::Passive(listener);
                if extended {
                    write_line(
                        writer,
                        &format!("229 Entering Extended Passive Mode (|||{port}|)"),
                    )?;
                } else {
                    let octets: Vec<&str> = self.local_ip.split('.').collect();
                    if octets.len() == 4 {
                        write_line(
                            writer,
                            &format!(
                                "227 Entering Passive Mode ({},{},{},{},{},{})",
                                octets[0],
                                octets[1],
                                octets[2],
                                octets[3],
                                port / 256,
                                port % 256
                            ),
                        )?;
                    } else {
                        // 回退到扩展被动模式。
                        write_line(
                            writer,
                            &format!("229 Entering Extended Passive Mode (|||{port}|)"),
                        )?;
                    }
                }
            }
            Err(_) => write_line(writer, "425 Cannot open passive connection.")?,
        }
        Ok(())
    }

    fn set_active(&mut self, argument: &str, writer: &mut TcpStream) -> std::io::Result<()> {
        let parts: Vec<u8> = argument
            .split(',')
            .filter_map(|p| p.trim().parse::<u8>().ok())
            .collect();
        if parts.len() == 6 {
            let ip = format!("{}.{}.{}.{}", parts[0], parts[1], parts[2], parts[3]);
            let port = (parts[4] as u16) * 256 + parts[5] as u16;
            if let Ok(addr) = format!("{ip}:{port}").parse::<SocketAddr>() {
                self.data = DataMode::Active(addr);
                write_line(writer, "200 PORT command successful.")?;
                return Ok(());
            }
        }
        self.data = DataMode::None;
        write_line(writer, "501 Bad PORT syntax.")?;
        Ok(())
    }

    fn set_active_extended(
        &mut self,
        argument: &str,
        writer: &mut TcpStream,
    ) -> std::io::Result<()> {
        // 形如 |1|192.168.1.5|12345|
        let parts: Vec<&str> = argument.split('|').filter(|p| !p.is_empty()).collect();
        if parts.len() >= 3 {
            if let Ok(addr) = format!("{}:{}", parts[1], parts[2]).parse::<SocketAddr>() {
                self.data = DataMode::Active(addr);
                write_line(writer, "200 EPRT command successful.")?;
                return Ok(());
            }
        }
        self.data = DataMode::None;
        write_line(writer, "501 Bad EPRT syntax.")?;
        Ok(())
    }

    fn data_connection(&mut self) -> Option<TcpStream> {
        match std::mem::replace(&mut self.data, DataMode::None) {
            DataMode::Passive(listener) => {
                let _ = listener.set_nonblocking(true);
                let deadline = Instant::now() + Duration::from_secs(15);
                loop {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let _ = stream.set_nonblocking(false);
                            return Some(stream);
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            if Instant::now() > deadline {
                                return None;
                            }
                            std::thread::sleep(Duration::from_millis(50));
                        }
                        Err(_) => return None,
                    }
                }
            }
            DataMode::Active(addr) => {
                TcpStream::connect_timeout(&addr, Duration::from_secs(15)).ok()
            }
            DataMode::None => None,
        }
    }

    fn send_listing(
        &mut self,
        argument: &str,
        style: Listing,
        writer: &mut TcpStream,
    ) -> std::io::Result<()> {
        let target = listing_target(argument);
        let fs_path = if target.is_empty() {
            self.fs_path("")
        } else {
            self.fs_path(&target)
        };
        let Some(fs_path) = fs_path else {
            write_line(writer, "550 Path unavailable.")?;
            return Ok(());
        };
        if !fs_path.exists() {
            write_line(writer, "550 Path unavailable.")?;
            return Ok(());
        }

        write_line(writer, "150 Opening data connection.")?;
        let Some(mut data) = self.data_connection() else {
            write_line(writer, "425 Cannot open data connection.")?;
            return Ok(());
        };

        let mut body = String::new();
        if fs_path.is_dir() {
            let entries = crate::api::list_dir(&fs_path.to_string_lossy()).unwrap_or_default();
            for entry in entries {
                match style {
                    Listing::Unix => body.push_str(&unix_line(
                        &entry.name,
                        entry.is_dir,
                        entry.size,
                        entry.modified,
                    )),
                    Listing::Names => {
                        body.push_str(&entry.name);
                        body.push_str("\r\n");
                    }
                    Listing::Machine => body.push_str(&mlsd_line(
                        &entry.name,
                        entry.is_dir,
                        entry.size,
                        entry.modified,
                    )),
                }
            }
        } else if let Some(name) = fs_path.file_name() {
            let name = name.to_string_lossy().into_owned();
            let meta = std::fs::metadata(&fs_path);
            let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
            let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
            let modified = meta.as_ref().map(modified_secs).unwrap_or(0);
            match style {
                Listing::Unix => body.push_str(&unix_line(&name, is_dir, size, modified)),
                Listing::Names => {
                    body.push_str(&name);
                    body.push_str("\r\n");
                }
                Listing::Machine => body.push_str(&mlsd_line(&name, is_dir, size, modified)),
            }
        }

        let _ = data.write_all(body.as_bytes());
        let _ = data.flush();
        drop(data);
        write_line(writer, "226 Transfer complete.")?;
        Ok(())
    }

    fn send_single_listing(
        &mut self,
        argument: &str,
        writer: &mut TcpStream,
    ) -> std::io::Result<()> {
        let target = if argument.trim().is_empty() {
            self.cwd.clone()
        } else {
            listing_target(argument)
        };
        let Some(fs_path) = self.fs_path(&target) else {
            write_line(writer, "550 Path unavailable.")?;
            return Ok(());
        };
        let name = if target.is_empty() {
            "/".to_string()
        } else {
            target
        };
        let meta = std::fs::metadata(&fs_path);
        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        let modified = meta.as_ref().map(modified_secs).unwrap_or(0);
        writer.write_all(b"250-Listing\r\n")?;
        let line = mlsd_line(&name, is_dir, size, modified);
        let line = line.trim_end_matches(['\r', '\n']);
        writer.write_all(format!(" {line}\r\n").as_bytes())?;
        write_line(writer, "250 End")?;
        Ok(())
    }

    fn retrieve(&mut self, argument: &str, writer: &mut TcpStream) -> std::io::Result<()> {
        let Some(path) = self.fs_path(argument) else {
            write_line(writer, "550 File unavailable.")?;
            return Ok(());
        };
        if !path.is_file() {
            write_line(writer, "550 File unavailable.")?;
            return Ok(());
        }
        let mut file = match std::fs::File::open(&path) {
            Ok(file) => file,
            Err(_) => {
                write_line(writer, "550 File unavailable.")?;
                return Ok(());
            }
        };
        write_line(writer, "150 Opening data connection.")?;
        let Some(mut data) = self.data_connection() else {
            write_line(writer, "425 Cannot open data connection.")?;
            return Ok(());
        };
        let result = std::io::copy(&mut file, &mut data);
        let _ = data.flush();
        drop(data);
        match result {
            Ok(_) => write_line(writer, "226 Transfer complete.")?,
            Err(_) => write_line(writer, "426 Transfer aborted.")?,
        }
        Ok(())
    }

    fn store(
        &mut self,
        argument: &str,
        append: bool,
        writer: &mut TcpStream,
    ) -> std::io::Result<()> {
        if self.read_only {
            write_line(writer, "550 Read-only server.")?;
            return Ok(());
        }
        let Some(path) = self.fs_path(argument) else {
            write_line(writer, "550 File unavailable.")?;
            return Ok(());
        };
        write_line(writer, "150 Opening data connection.")?;
        let Some(mut data) = self.data_connection() else {
            write_line(writer, "425 Cannot open data connection.")?;
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(append)
            .truncate(!append)
            .open(&path);
        match file {
            Ok(mut file) => {
                let result = std::io::copy(&mut data, &mut file);
                drop(data);
                match result {
                    Ok(_) => write_line(writer, "226 Transfer complete.")?,
                    Err(_) => write_line(writer, "426 Transfer aborted.")?,
                }
            }
            Err(_) => {
                drop(data);
                write_line(writer, "550 Cannot store file.")?;
            }
        }
        Ok(())
    }
}

enum Listing {
    Unix,
    Names,
    Machine,
}

fn listing_target(argument: &str) -> String {
    let trimmed = argument.trim();
    if trimmed.starts_with('-') {
        match trimmed.split_once(' ') {
            Some((_, rest)) => rest.trim().to_string(),
            None => String::new(),
        }
    } else {
        trimmed.to_string()
    }
}

fn ftp_join(cwd: &str, argument: &str) -> String {
    let base = if argument.starts_with('/') {
        String::new()
    } else {
        cwd.to_string()
    };
    let combined = format!("{base}/{argument}");
    let mut components: Vec<String> = Vec::new();
    for part in combined.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                components.pop();
            }
            other => components.push(other.to_string()),
        }
    }
    format!("/{}", components.join("/"))
}

fn unix_line(name: &str, is_dir: bool, size: u64, modified: i64) -> String {
    let perms = if is_dir { "drwxr-xr-x" } else { "-rw-r--r--" };
    let (month, day, time) = if modified > 0 {
        let days = modified.div_euclid(86_400);
        let rem = modified.rem_euclid(86_400);
        let (_, month, day) = fsutil::civil_from_days(days);
        (
            MONTHS[(month - 1) as usize],
            day,
            format!("{:02}:{:02}", rem / 3600, (rem % 3600) / 60),
        )
    } else {
        ("Jan", 1, "00:00".to_string())
    };
    format!("{perms} 1 owner group {size} {month} {day:02} {time} {name}\r\n")
}

fn mlsd_line(name: &str, is_dir: bool, size: u64, modified: i64) -> String {
    if is_dir {
        let modify = if modified > 0 {
            format!("modify={};", fsutil::format_timestamp(modified))
        } else {
            String::new()
        };
        format!("type=dir;{modify}perm=el; {name}\r\n")
    } else {
        let modify = if modified > 0 {
            format!("modify={};", fsutil::format_timestamp(modified))
        } else {
            String::new()
        };
        format!("type=file;size={size};{modify}perm=rw; {name}\r\n")
    }
}

fn modified_secs(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
