//! 远程协议（WebDAV / FTP / SMB）支持。
//!
//! 所有网络协议都用纯 Rust 实现，并集中在一个独立的工作线程上执行：该线程持有
//! 全部连接会话。调用方通过命令通道下发操作并等待结果，因此上层（FFI / vfs）
//! 不需要关心各客户端的线程安全与异步运行时。

pub mod ftp;
pub mod smb;
pub mod webdav;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};

/// 一条连接配置。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProfileSpec {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// `webdav` | `ftp` | `smb`
    pub kind: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 连接后的初始目录（相对服务器根 / 共享根）。
    #[serde(default)]
    pub base_path: String,
    /// SMB 共享名。
    #[serde(default)]
    pub share: String,
    /// SMB 域。
    #[serde(default)]
    pub domain: String,
    /// WebDAV 用 HTTPS / FTP 用 FTPS。
    #[serde(default)]
    pub secure: bool,
    /// 允许无效的 TLS 证书（自签名）。
    #[serde(default)]
    pub insecure_tls: bool,
}

/// 协议无关的目录项。
#[derive(Debug, Clone)]
pub struct RemoteEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified: i64,
}

/// 各协议的统一接口。实现只需在工作线程中使用，因此不要求 `Send`。
pub trait RemoteFs {
    fn test(&mut self) -> Result<(), String> {
        Ok(())
    }
    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String>;
    fn stat(&mut self, inner: &str) -> Result<RemoteEntry, String>;
    fn read(&mut self, inner: &str) -> Result<Vec<u8>, String>;
    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String>;
    fn mkdir(&mut self, inner: &str) -> Result<(), String>;
    fn remove(&mut self, inner: &str, is_dir: bool) -> Result<(), String>;
    fn rename(&mut self, from: &str, to: &str) -> Result<(), String>;
}

// ---------------------------------------------------------------------------
// 工作线程命令
// ---------------------------------------------------------------------------

enum Op {
    List {
        id: String,
        inner: String,
        reply: Sender<Result<Vec<RemoteEntry>, String>>,
    },
    Stat {
        id: String,
        inner: String,
        reply: Sender<Result<RemoteEntry, String>>,
    },
    Read {
        id: String,
        inner: String,
        reply: Sender<Result<Vec<u8>, String>>,
    },
    Write {
        id: String,
        inner: String,
        data: Vec<u8>,
        reply: Sender<Result<(), String>>,
    },
    Mkdir {
        id: String,
        inner: String,
        reply: Sender<Result<(), String>>,
    },
    Remove {
        id: String,
        inner: String,
        is_dir: bool,
        reply: Sender<Result<(), String>>,
    },
    Rename {
        id: String,
        from: String,
        to: String,
        reply: Sender<Result<(), String>>,
    },
}

enum Cmd {
    SetProfiles(Vec<ProfileSpec>),
    Disconnect {
        id: String,
        reply: Sender<Result<(), String>>,
    },
    Test {
        profile: ProfileSpec,
        reply: Sender<Result<(), String>>,
    },
    Run(Op),
}

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

static WORKER: OnceLock<Mutex<Sender<Cmd>>> = OnceLock::new();

/// 配置目录 / 缓存目录（由 Android 侧提供）。
#[derive(Default)]
struct Paths {
    config: Option<PathBuf>,
    cache: Option<PathBuf>,
}

static PATHS: OnceLock<Mutex<Paths>> = OnceLock::new();

fn paths() -> &'static Mutex<Paths> {
    PATHS.get_or_init(|| Mutex::new(Paths::default()))
}

pub fn cache_dir() -> Option<PathBuf> {
    match paths().lock() {
        Ok(guard) => guard.cache.clone(),
        Err(_) => None,
    }
}

/// 应用私有配置目录（由 [`init`] 设置）。
pub fn config_dir() -> Option<PathBuf> {
    match paths().lock() {
        Ok(guard) => guard.config.clone(),
        Err(_) => None,
    }
}

fn config_file() -> Option<PathBuf> {
    let guard = paths().lock().ok()?;
    let dir = guard.config.clone()?;
    Some(dir.join("ordo_connections.json"))
}

pub fn init(config_dir: &str, cache_dir: &str) {
    {
        let mut guard = paths().lock().unwrap();
        guard.config = Some(PathBuf::from(config_dir));
        guard.cache = Some(PathBuf::from(cache_dir));
    }
    let _ = load_profiles();
    let _ = ensure_worker();
    push_profiles();
}

fn load_profiles() -> Vec<ProfileSpec> {
    let Some(file) = config_file() else {
        return Vec::new();
    };
    let Ok(text) = std::fs::read_to_string(&file) else {
        return Vec::new();
    };
    #[derive(Deserialize)]
    struct ConfigFile {
        #[serde(default)]
        profiles: Vec<ProfileSpec>,
    }
    serde_json::from_str::<ConfigFile>(&text)
        .map(|c| c.profiles)
        .unwrap_or_default()
}

fn store_profiles(profiles: &[ProfileSpec]) -> Result<(), String> {
    let Some(file) = config_file() else {
        return Err("配置目录不可用".into());
    };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    #[derive(Serialize)]
    struct ConfigFile<'a> {
        profiles: &'a [ProfileSpec],
    }
    let text = serde_json::to_string_pretty(&ConfigFile { profiles })
        .map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(&file, text).map_err(|e| format!("保存失败：{e}"))
}

fn ensure_worker() -> &'static Mutex<Sender<Cmd>> {
    WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Cmd>();
        std::thread::Builder::new()
            .name("ordo-net".into())
            .spawn(move || worker_loop(rx))
            .expect("启动网络工作线程失败");
        Mutex::new(tx)
    })
}

fn send_cmd(cmd: Cmd) {
    if let Ok(guard) = ensure_worker().lock() {
        let _ = guard.send(cmd);
    }
}

/// 让工作线程刷新它缓存的连接配置。
fn push_profiles() {
    send_cmd(Cmd::SetProfiles(load_profiles()));
}

// ---------------------------------------------------------------------------
// 配置管理（供 FFI 调用）
// ---------------------------------------------------------------------------

pub fn list_profiles() -> Vec<ProfileSpec> {
    load_profiles()
}

pub fn save_profile(mut profile: ProfileSpec) -> Result<ProfileSpec, String> {
    if profile.kind.is_empty() {
        return Err("缺少协议类型".into());
    }
    if profile.host.trim().is_empty() {
        return Err("服务器地址不能为空".into());
    }
    if profile.name.trim().is_empty() {
        profile.name = profile.host.clone();
    }
    if profile.id.is_empty() {
        profile.id = new_id();
    }
    let mut profiles = load_profiles();
    match profiles.iter_mut().find(|p| p.id == profile.id) {
        Some(existing) => *existing = profile.clone(),
        None => profiles.push(profile.clone()),
    }
    store_profiles(&profiles)?;
    push_profiles();
    Ok(profile)
}

pub fn remove_profile(id: &str) -> Result<(), String> {
    let mut profiles = load_profiles();
    profiles.retain(|p| p.id != id);
    store_profiles(&profiles)?;
    let _ = disconnect(id);
    push_profiles();
    Ok(())
}

pub fn test_profile(profile: &ProfileSpec) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Test {
        profile: profile.clone(),
        reply: tx,
    });
    recv(rx)
}

pub fn disconnect(id: &str) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Disconnect {
        id: id.to_string(),
        reply: tx,
    });
    recv(rx)
}

// ---------------------------------------------------------------------------
// 操作（供 vfs 调用）
// ---------------------------------------------------------------------------

pub fn list(id: &str, inner: &str) -> Result<Vec<RemoteEntry>, String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::List {
        id: id.into(),
        inner: inner.into(),
        reply: tx,
    }));
    recv(rx)
}

pub fn stat(id: &str, inner: &str) -> Result<RemoteEntry, String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Stat {
        id: id.into(),
        inner: inner.into(),
        reply: tx,
    }));
    recv(rx)
}

pub fn read(id: &str, inner: &str) -> Result<Vec<u8>, String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Read {
        id: id.into(),
        inner: inner.into(),
        reply: tx,
    }));
    recv(rx)
}

pub fn write(id: &str, inner: &str, data: &[u8]) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Write {
        id: id.into(),
        inner: inner.into(),
        data: data.to_vec(),
        reply: tx,
    }));
    recv(rx)
}

pub fn mkdir(id: &str, inner: &str) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Mkdir {
        id: id.into(),
        inner: inner.into(),
        reply: tx,
    }));
    recv(rx)
}

pub fn remove(id: &str, inner: &str, is_dir: bool) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Remove {
        id: id.into(),
        inner: inner.into(),
        is_dir,
        reply: tx,
    }));
    recv(rx)
}

pub fn rename(id: &str, from: &str, to: &str) -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    send_cmd(Cmd::Run(Op::Rename {
        id: id.into(),
        from: from.into(),
        to: to.into(),
        reply: tx,
    }));
    recv(rx)
}

fn recv<T>(rx: Receiver<T>) -> T {
    rx.recv().unwrap_or_else(|_| panic!("网络工作线程已退出"))
}

fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}{:x}", std::process::id())
}

// ---------------------------------------------------------------------------
// 工作线程
// ---------------------------------------------------------------------------

struct WorkerState {
    profiles: HashMap<String, ProfileSpec>,
    sessions: HashMap<String, Box<dyn RemoteFs>>,
}

fn worker_loop(rx: Receiver<Cmd>) {
    let mut state = WorkerState {
        profiles: HashMap::new(),
        sessions: HashMap::new(),
    };
    while let Ok(cmd) = rx.recv() {
        match cmd {
            Cmd::SetProfiles(profiles) => {
                let ids: Vec<String> = profiles.iter().map(|p| p.id.clone()).collect();
                state.sessions.retain(|id, _| ids.contains(id));
                state.profiles = profiles.into_iter().map(|p| (p.id.clone(), p)).collect();
            }
            Cmd::Disconnect { id, reply } => {
                state.sessions.remove(&id);
                let _ = reply.send(Ok(()));
            }
            Cmd::Test { profile, reply } => {
                let result = connect(&profile).and_then(|mut client| client.test());
                let _ = reply.send(result);
            }
            Cmd::Run(op) => state.run(op),
        }
    }
}

impl WorkerState {
    fn run(&mut self, op: Op) {
        match op {
            Op::List { id, inner, reply } => {
                let r = self.with_session(&id, |c| c.list(&inner));
                let _ = reply.send(r);
            }
            Op::Stat { id, inner, reply } => {
                let r = self.with_session(&id, |c| c.stat(&inner));
                let _ = reply.send(r);
            }
            Op::Read { id, inner, reply } => {
                let r = self.with_session(&id, |c| c.read(&inner));
                let _ = reply.send(r);
            }
            Op::Write {
                id,
                inner,
                data,
                reply,
            } => {
                let r = self.with_session(&id, |c| c.write(&inner, &data));
                let _ = reply.send(r);
            }
            Op::Mkdir { id, inner, reply } => {
                let r = self.with_session(&id, |c| c.mkdir(&inner));
                let _ = reply.send(r);
            }
            Op::Remove {
                id,
                inner,
                is_dir,
                reply,
            } => {
                let r = self.with_session(&id, |c| c.remove(&inner, is_dir));
                let _ = reply.send(r);
            }
            Op::Rename {
                id,
                from,
                to,
                reply,
            } => {
                let r = self.with_session(&id, |c| c.rename(&from, &to));
                let _ = reply.send(r);
            }
        }
    }

    fn with_session<R>(
        &mut self,
        id: &str,
        f: impl FnOnce(&mut Box<dyn RemoteFs>) -> Result<R, String>,
    ) -> Result<R, String> {
        if !self.sessions.contains_key(id) {
            let profile = self
                .profiles
                .get(id)
                .cloned()
                .ok_or_else(|| "连接不存在或已被删除".to_string())?;
            let client = connect(&profile)?;
            self.sessions.insert(id.to_string(), client);
        }
        let result = {
            let session = self.sessions.get_mut(id).expect("session just inserted");
            f(session)
        };
        if result.is_err() {
            // 连接可能已失效，下次访问时重连。
            self.sessions.remove(id);
        }
        result
    }
}

fn connect(profile: &ProfileSpec) -> Result<Box<dyn RemoteFs>, String> {
    match profile.kind.as_str() {
        "ftp" => Ok(Box::new(ftp::FtpRemote::connect(profile)?)),
        "webdav" => Ok(Box::new(webdav::WebdavRemote::connect(profile)?)),
        "smb" => Ok(Box::new(smb::SmbRemote::connect(profile)?)),
        other => Err(format!("不支持的协议：{other}")),
    }
}

// ---------------------------------------------------------------------------
// 路径 / 工具
// ---------------------------------------------------------------------------

/// 远程 URI：`<scheme>://<id><inner>`，其中 `inner` 以 `/` 开头。
pub fn is_remote(uri: &str) -> bool {
    parse(uri).is_some()
}

pub fn parse(uri: &str) -> Option<(String, String, String)> {
    for scheme in ["webdav", "ftp", "smb"] {
        let prefix = format!("{scheme}://");
        if let Some(rest) = uri.strip_prefix(&prefix) {
            let (id, inner) = match rest.find('/') {
                Some(index) => (&rest[..index], &rest[index..]),
                None => (rest, "/"),
            };
            return Some((scheme.to_string(), id.to_string(), inner.to_string()));
        }
    }
    None
}

pub fn make_path(scheme: &str, id: &str, inner: &str) -> String {
    let inner = if inner.starts_with('/') {
        inner.to_string()
    } else {
        format!("/{inner}")
    };
    format!("{scheme}://{id}{inner}")
}

/// 拼接 inner 路径。
pub fn join_inner(base: &str, name: &str) -> String {
    if base.ends_with('/') {
        format!("{base}{name}")
    } else {
        format!("{base}/{name}")
    }
}

/// inner 的父路径。
pub fn parent_inner(inner: &str) -> String {
    let trimmed = inner.trim_end_matches('/');
    match trimmed.rfind('/') {
        Some(0) | None => "/".to_string(),
        Some(index) => trimmed[..index].to_string(),
    }
}

/// 把用户输入的 base_path 规范成以 `/` 开头（若为空则空串）。
pub fn normalize_base(path: &str) -> String {
    let p = path.trim();
    if p.is_empty() || p == "/" {
        return String::new();
    }
    let mut s = String::new();
    if !p.starts_with('/') {
        s.push('/');
    }
    s.push_str(p.trim_end_matches('/'));
    s
}

/// 把 time 转成 unix 秒。
pub fn system_time_to_secs(t: std::time::SystemTime) -> i64 {
    t.duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn extension_of(name: &str) -> String {
    match name.rfind('.') {
        Some(index) if index > 0 => name[index + 1..].to_ascii_lowercase(),
        _ => String::new(),
    }
}
