//! 本地文件服务器：可同时开启 HTTP/WebDAV 与 FTP，供同一局域网内的其他设备访问。
//!
//! 服务器运行在独立线程上，通过 [`start`] / [`stop`] / [`status`] 控制；配置持久化到
//! 应用私有目录，方便下次直接启动。

pub mod fsutil;
pub mod ftp;
pub mod http;

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::net::UdpSocket;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ServerConfig {
    /// 共享目录（绝对路径）。
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub http: bool,
    #[serde(default)]
    pub http_port: u16,
    #[serde(default)]
    pub ftp: bool,
    #[serde(default)]
    pub ftp_port: u16,
    /// 是否要求用户名 / 密码。
    #[serde(default)]
    pub auth: bool,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 只读模式。
    #[serde(default)]
    pub read_only: bool,
    /// 多用户：非空时按用户鉴权，并可用 `path` 限定子目录。
    #[serde(default)]
    pub users: Vec<ServerUser>,
}

/// 单个访问账号。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ServerUser {
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 限定子目录（相对共享根，空表示根目录）。
    #[serde(default)]
    pub path: String,
    /// 该账号只读。
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerStatus {
    pub running: bool,
    pub http_port: Option<u16>,
    pub ftp_port: Option<u16>,
    pub root: String,
    pub auth: bool,
    pub read_only: bool,
    pub addresses: Vec<String>,
    pub users: Vec<String>,
    pub error: Option<String>,
}

/// 一条访问记录。
#[derive(Debug, Clone, Serialize)]
pub struct AccessEntry {
    pub time: i64,
    pub protocol: String,
    pub client: String,
    pub action: String,
    pub path: String,
    pub status: u16,
}

/// 最近活跃的客户端。
#[derive(Debug, Clone, Serialize)]
pub struct ClientEntry {
    pub address: String,
    pub protocol: String,
    pub last_seen: i64,
    pub requests: u64,
}

/// 服务器访问日志与客户端统计（HTTP / FTP 共享）。
#[derive(Default)]
pub struct Activity {
    entries: Mutex<VecDeque<AccessEntry>>,
    clients: Mutex<HashMap<String, ClientEntry>>,
    revision: AtomicU64,
}

impl Activity {
    pub fn record(&self, protocol: &str, client: &str, action: &str, path: &str, status: u16) {
        let now = now_secs();
        {
            let mut entries = self.entries.lock().unwrap_or_else(|e| e.into_inner());
            entries.push_front(AccessEntry {
                time: now,
                protocol: protocol.to_string(),
                client: client.to_string(),
                action: action.to_string(),
                path: path.to_string(),
                status,
            });
            while entries.len() > 300 {
                entries.pop_back();
            }
        }
        {
            let mut clients = self.clients.lock().unwrap_or_else(|e| e.into_inner());
            let entry = clients
                .entry(client.to_string())
                .or_insert_with(|| ClientEntry {
                    address: client.to_string(),
                    protocol: protocol.to_string(),
                    last_seen: now,
                    requests: 0,
                });
            entry.protocol = protocol.to_string();
            entry.last_seen = now;
            entry.requests += 1;
        }
        self.revision.fetch_add(1, Ordering::SeqCst);
    }

    pub fn snapshot(&self) -> (Vec<AccessEntry>, Vec<ClientEntry>, u64) {
        let entries = self
            .entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned()
            .collect();
        let mut clients: Vec<ClientEntry> = self
            .clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .cloned()
            .collect();
        clients.sort_by_key(|entry| std::cmp::Reverse(entry.last_seen));
        let revision = self.revision.load(Ordering::SeqCst);
        (entries, clients, revision)
    }

    pub fn clear(&self) {
        self.entries
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        self.clients
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
        // revision 单调递增，清空时也 +1 以便界面刷新。
        self.revision.fetch_add(1, Ordering::SeqCst);
    }
}

static ACTIVITY: OnceLock<Arc<Activity>> = OnceLock::new();

/// 全局访问日志单例。
pub fn activity() -> Arc<Activity> {
    ACTIVITY
        .get_or_init(|| Arc::new(Activity::default()))
        .clone()
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 各协议线程共享的上下文。
pub struct ServerCtx {
    pub root: PathBuf,
    pub auth: bool,
    pub username: String,
    pub password: String,
    pub read_only: bool,
    pub users: Vec<ServerUser>,
    pub activity: Arc<Activity>,
}

struct RunningServer {
    stop: Arc<AtomicBool>,
    handle: JoinHandle<()>,
    port: u16,
}

#[derive(Default)]
struct State {
    http: Option<RunningServer>,
    ftp: Option<RunningServer>,
    config: ServerConfig,
    error: Option<String>,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| Mutex::new(State::default()))
}

pub fn start(config: ServerConfig) -> Result<ServerStatus, String> {
    let root = PathBuf::from(config.root.trim());
    if root.as_os_str().is_empty() {
        return Err("请选择要共享的目录".into());
    }
    if !root.is_dir() {
        return Err(format!("目录不存在或不可读：{}", root.display()));
    }
    if !config.http && !config.ftp {
        return Err("请至少启用一种服务器（HTTP/WebDAV 或 FTP）".into());
    }
    if config.auth && (config.username.trim().is_empty() || config.password.is_empty()) {
        return Err("启用密码保护时必须填写用户名与密码".into());
    }
    for user in &config.users {
        if user.username.trim().is_empty() || user.password.is_empty() {
            return Err("多用户账号需要填写用户名与密码".into());
        }
    }

    stop();

    let shared_activity = activity();
    shared_activity.clear();

    let ctx = Arc::new(ServerCtx {
        root,
        auth: config.auth,
        username: config.username.clone(),
        password: config.password.clone(),
        read_only: config.read_only,
        users: config.users.clone(),
        activity: shared_activity,
    });

    let mut http_running: Option<RunningServer> = None;
    let mut ftp_running: Option<RunningServer> = None;

    if config.http {
        let port = if config.http_port == 0 {
            8080
        } else {
            config.http_port
        };
        match http::bind(port) {
            Ok(server) => {
                let actual = server
                    .server_addr()
                    .to_ip()
                    .map(|addr| addr.port())
                    .unwrap_or(port);
                let stop_flag = Arc::new(AtomicBool::new(false));
                let thread_ctx = ctx.clone();
                let thread_stop = stop_flag.clone();
                let handle = std::thread::Builder::new()
                    .name("ordo-http".into())
                    .spawn(move || http::serve(server, thread_ctx, thread_stop))
                    .map_err(|e| format!("启动 HTTP 线程失败：{e}"))?;
                http_running = Some(RunningServer {
                    stop: stop_flag,
                    handle,
                    port: actual,
                });
            }
            Err(e) => {
                return Err(e);
            }
        }
    }

    if config.ftp {
        let port = if config.ftp_port == 0 {
            2121
        } else {
            config.ftp_port
        };
        match ftp::bind(port) {
            Ok(listener) => {
                let actual = listener
                    .local_addr()
                    .map(|addr| addr.port())
                    .unwrap_or(port);
                let stop_flag = Arc::new(AtomicBool::new(false));
                let thread_ctx = ctx.clone();
                let thread_stop = stop_flag.clone();
                let handle = std::thread::Builder::new()
                    .name("ordo-ftp".into())
                    .spawn(move || ftp::serve(listener, thread_ctx, thread_stop))
                    .map_err(|e| format!("启动 FTP 线程失败：{e}"))?;
                ftp_running = Some(RunningServer {
                    stop: stop_flag,
                    handle,
                    port: actual,
                });
            }
            Err(e) => {
                // HTTP 已启动则一并回滚。
                if let Some(server) = http_running.take() {
                    server.stop.store(true, Ordering::SeqCst);
                    let _ = server.handle.join();
                }
                return Err(e);
            }
        }
    }

    {
        let mut guard = state().lock().unwrap();
        guard.http = http_running;
        guard.ftp = ftp_running;
        guard.config = config.clone();
        guard.error = None;
    }
    let _ = save_config(&config);
    Ok(status())
}

pub fn stop() {
    let (http, ftp) = {
        let mut guard = state().lock().unwrap();
        (guard.http.take(), guard.ftp.take())
    };
    for server in [http, ftp].into_iter().flatten() {
        server.stop.store(true, Ordering::SeqCst);
        let _ = server.handle.join();
    }
}

pub fn status() -> ServerStatus {
    let (http_port, ftp_port, config, error) = {
        let guard = state().lock().unwrap();
        (
            guard.http.as_ref().map(|server| server.port),
            guard.ftp.as_ref().map(|server| server.port),
            guard.config.clone(),
            guard.error.clone(),
        )
    };

    let mut addresses = Vec::new();
    if let Some(ip) = local_ipv4() {
        addresses.push(ip);
    }
    if addresses.is_empty() {
        addresses.push("127.0.0.1".to_string());
    }

    ServerStatus {
        running: http_port.is_some() || ftp_port.is_some(),
        http_port,
        ftp_port,
        root: config.root,
        auth: config.auth || !config.users.is_empty(),
        read_only: config.read_only,
        addresses,
        users: config.users.iter().map(|u| u.username.clone()).collect(),
        error,
    }
}

pub fn save_config(config: &ServerConfig) -> Result<(), String> {
    let Some(dir) = crate::remote::config_dir() else {
        return Err("配置目录不可用".into());
    };
    let _ = std::fs::create_dir_all(&dir);
    let text = serde_json::to_string_pretty(config).map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(dir.join("ordo_server.json"), text).map_err(|e| format!("保存失败：{e}"))
}

pub fn load_config() -> ServerConfig {
    let Some(dir) = crate::remote::config_dir() else {
        return ServerConfig::default();
    };
    let Ok(text) = std::fs::read_to_string(dir.join("ordo_server.json")) else {
        return ServerConfig::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

/// 获取本机局域网 IPv4（不发送任何数据）。
fn local_ipv4() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let ip = socket.local_addr().ok()?.ip();
    if ip.is_loopback() || ip.is_unspecified() {
        None
    } else {
        Some(ip.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::sync::Mutex;

    // 服务器使用全局单例，测试必须串行。
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("ordo_server_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn base_config(root: &std::path::Path) -> ServerConfig {
        ServerConfig {
            root: root.to_string_lossy().into_owned(),
            ..Default::default()
        }
    }

    #[test]
    fn http_webdav_roundtrip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("http");
        std::fs::write(dir.join("hello.txt"), "你好, Ordo").unwrap();

        let status = start(ServerConfig {
            http: true,
            ..base_config(&dir)
        })
        .unwrap();
        let port = status.http_port.unwrap();
        let base = format!("http://127.0.0.1:{port}");
        let client = reqwest::blocking::Client::new();

        // PROPFIND 列出目录
        let response = client
            .request(
                reqwest::Method::from_bytes(b"PROPFIND").unwrap(),
                format!("{base}/"),
            )
            .header("Depth", "1")
            .header("Content-Type", "application/xml")
            .body("<?xml version=\"1.0\"?><D:propfind xmlns:D=\"DAV:\"><D:prop><D:resourcetype/></D:prop></D:propfind>")
            .send()
            .unwrap();
        assert_eq!(response.status().as_u16(), 207);
        let body = response.text().unwrap();
        assert!(body.contains("hello.txt"), "PROPFIND body: {body}");

        // GET 下载
        let response = client.get(format!("{base}/hello.txt")).send().unwrap();
        assert!(response.status().is_success());
        assert_eq!(response.text().unwrap(), "你好, Ordo");

        // PUT 上传（自动创建父目录）
        let response = client
            .put(format!("{base}/nested/up.txt"))
            .body("uploaded")
            .send()
            .unwrap();
        assert!(response.status().is_success());
        assert_eq!(
            std::fs::read_to_string(dir.join("nested/up.txt")).unwrap(),
            "uploaded"
        );

        // MKCOL
        let response = client
            .request(
                reqwest::Method::from_bytes(b"MKCOL").unwrap(),
                format!("{base}/folder"),
            )
            .send()
            .unwrap();
        assert_eq!(response.status().as_u16(), 201);
        assert!(dir.join("folder").is_dir());

        // MOVE
        let response = client
            .request(
                reqwest::Method::from_bytes(b"MOVE").unwrap(),
                format!("{base}/folder"),
            )
            .header("Destination", format!("{base}/folder2"))
            .send()
            .unwrap();
        assert!(response.status().is_success());
        assert!(dir.join("folder2").is_dir());

        // DELETE
        let response = client.delete(format!("{base}/hello.txt")).send().unwrap();
        assert!(response.status().is_success());
        assert!(!dir.join("hello.txt").exists());

        stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn http_auth_and_read_only() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("auth");
        std::fs::write(dir.join("a.txt"), "x").unwrap();

        let status = start(ServerConfig {
            http: true,
            auth: true,
            username: "u".into(),
            password: "p".into(),
            read_only: true,
            ..base_config(&dir)
        })
        .unwrap();
        let base = format!("http://127.0.0.1:{}/", status.http_port.unwrap());
        let client = reqwest::blocking::Client::new();

        let response = client.get(&base).send().unwrap();
        assert_eq!(response.status().as_u16(), 401);

        let response = client.get(&base).basic_auth("u", Some("p")).send().unwrap();
        assert!(response.status().is_success());

        let response = client
            .put(format!("{base}new.txt"))
            .basic_auth("u", Some("p"))
            .body("data")
            .send()
            .unwrap();
        assert_eq!(response.status().as_u16(), 403);

        stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ftp_roundtrip() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("ftp");
        std::fs::write(dir.join("seed.txt"), "seed").unwrap();

        let status = start(ServerConfig {
            ftp: true,
            ..base_config(&dir)
        })
        .unwrap();
        let port = status.ftp_port.unwrap();

        let mut ftp = suppaftp::FtpStream::connect(("127.0.0.1", port)).unwrap();
        ftp.login("anonymous", "anonymous").unwrap();

        let list = ftp.mlsd(Some("/")).unwrap();
        assert!(list.iter().any(|line| line.contains("seed.txt")));

        // 上传
        let mut cursor = Cursor::new(b"uploaded via ftp".to_vec());
        ftp.put_file("up.txt", &mut cursor).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join("up.txt")).unwrap(),
            "uploaded via ftp"
        );

        // 下载
        let buffer = ftp.retr_as_buffer("up.txt").unwrap();
        assert_eq!(buffer.into_inner(), b"uploaded via ftp");

        // 目录与重命名
        ftp.mkdir("sub").unwrap();
        ftp.cwd("sub").unwrap();
        assert_eq!(ftp.pwd().unwrap(), "/sub");
        ftp.cdup().unwrap();
        ftp.rename("up.txt", "renamed.txt").unwrap();
        assert!(dir.join("renamed.txt").exists());

        ftp.rm("renamed.txt").unwrap();
        ftp.rmdir("sub").unwrap();
        assert!(!dir.join("renamed.txt").exists());

        ftp.quit().unwrap();

        stop();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn http_multi_user_and_upload_page() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_dir("users");
        std::fs::create_dir_all(dir.join("alice")).unwrap();
        std::fs::write(dir.join("alice/a.txt"), "a").unwrap();
        std::fs::write(dir.join("root.txt"), "r").unwrap();

        let status = start(ServerConfig {
            http: true,
            users: vec![
                ServerUser {
                    username: "alice".into(),
                    password: "pw".into(),
                    path: "alice".into(),
                    read_only: false,
                },
                ServerUser {
                    username: "bob".into(),
                    password: "pw".into(),
                    path: String::new(),
                    read_only: true,
                },
            ],
            ..base_config(&dir)
        })
        .unwrap();
        let base = format!("http://127.0.0.1:{}/", status.http_port.unwrap());
        let client = reqwest::blocking::Client::new();

        // 未认证返回 401。
        assert_eq!(client.get(&base).send().unwrap().status().as_u16(), 401);

        // alice 的根被限定在其子目录，且可上传。
        let body = client
            .get(&base)
            .basic_auth("alice", Some("pw"))
            .send()
            .unwrap()
            .text()
            .unwrap();
        assert!(body.contains("a.txt"), "alice listing: {body}");
        assert!(!body.contains("root.txt"));
        assert!(body.contains("上传文件"), "upload toolbar missing");

        let response = client
            .put(format!("{base}new.txt"))
            .basic_auth("alice", Some("pw"))
            .body("hi")
            .send()
            .unwrap();
        assert!(response.status().is_success());
        assert!(dir.join("alice/new.txt").exists());

        // bob 只读：可读根目录，但禁止写入，且页面无上传工具栏。
        let body = client
            .get(&base)
            .basic_auth("bob", Some("pw"))
            .send()
            .unwrap()
            .text()
            .unwrap();
        assert!(body.contains("root.txt"));
        assert!(!body.contains("上传文件"));
        let response = client
            .put(format!("{base}blocked.txt"))
            .basic_auth("bob", Some("pw"))
            .body("x")
            .send()
            .unwrap();
        assert_eq!(response.status().as_u16(), 403);

        // 访问日志包含请求记录。
        let (entries, clients, _) = activity().snapshot();
        assert!(!entries.is_empty());
        assert!(clients.iter().any(|c| c.protocol == "http"));

        stop();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
