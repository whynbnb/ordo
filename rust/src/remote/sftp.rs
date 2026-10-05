use super::{normalize_base, ProfileSpec, RemoteEntry, RemoteFs};
use async_trait::async_trait;
use russh::client::{self, Handler};
use russh_sftp::client::SftpSession;
use std::sync::{Arc, OnceLock};
use std::time::UNIX_EPOCH;

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("创建 tokio 运行时失败")
    })
}

struct SshHandler;

#[async_trait]
impl Handler for SshHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh::keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // 暂不校验主机指纹（与其它协议一致的信任策略）。
        Ok(true)
    }
}

/// SFTP 连接（基于 russh + russh-sftp，纯 Rust）。
pub struct SftpRemote {
    handle: tokio::runtime::Handle,
    session: SftpSession,
    base: String,
}

impl SftpRemote {
    pub fn connect(profile: &ProfileSpec) -> Result<Self, String> {
        let port = if profile.port == 0 { 22 } else { profile.port };
        let address = format!("{}:{}", profile.host.trim(), port);
        let handle = runtime().handle().clone();
        let username = profile.username.clone();
        let password = profile.password.clone();

        let session = handle.block_on(async move {
            let config = Arc::new(client::Config::default());
            let mut ssh = client::connect(config, address.as_str(), SshHandler)
                .await
                .map_err(|e| format!("SFTP 连接失败：{e}"))?;
            let ok = ssh
                .authenticate_password(username, password)
                .await
                .map_err(|e| format!("SFTP 认证失败：{e}"))?;
            if !ok {
                return Err("SFTP 认证被拒绝".to_string());
            }
            let channel = ssh
                .channel_open_session()
                .await
                .map_err(|e| format!("打开会话失败：{e}"))?;
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|e| format!("请求 SFTP 子系统失败：{e}"))?;
            SftpSession::new(channel.into_stream())
                .await
                .map_err(|e| format!("初始化 SFTP 失败：{e}"))
        })?;

        Ok(SftpRemote {
            handle,
            session,
            base: normalize_base(&profile.base_path),
        })
    }

    fn full(&self, inner: &str) -> String {
        let base = self.base.trim_end_matches('/');
        if inner == "/" || inner.is_empty() {
            if base.is_empty() {
                "/".to_string()
            } else {
                base.to_string()
            }
        } else {
            format!("{}/{}", base, inner.trim_start_matches('/'))
        }
    }
}

fn to_modified(meta: &russh_sftp::client::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

impl RemoteFs for SftpRemote {
    fn test(&mut self) -> Result<(), String> {
        let path = self.full("/");
        self.handle
            .block_on(self.session.metadata(path))
            .map(|_| ())
            .map_err(|e| format!("SFTP 连接测试失败：{e}"))
    }

    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        let path = self.full(inner);
        let dir = self
            .handle
            .block_on(self.session.read_dir(path))
            .map_err(|e| format!("读取目录失败：{e}"))?;
        let mut out = Vec::new();
        for entry in dir {
            let meta = entry.metadata();
            let is_dir = meta.is_dir();
            out.push(RemoteEntry {
                name: entry.file_name(),
                is_dir,
                size: if is_dir { 0 } else { meta.len() },
                modified: to_modified(&meta),
            });
        }
        Ok(out)
    }

    fn stat(&mut self, inner: &str) -> Result<RemoteEntry, String> {
        let path = self.full(inner);
        let meta = self
            .handle
            .block_on(self.session.metadata(path))
            .map_err(|e| format!("获取信息失败：{e}"))?;
        let name = inner.trim_end_matches('/').rsplit('/').next().unwrap_or("");
        let is_dir = meta.is_dir();
        Ok(RemoteEntry {
            name: if name.is_empty() {
                "/".into()
            } else {
                name.into()
            },
            is_dir,
            size: if is_dir { 0 } else { meta.len() },
            modified: to_modified(&meta),
        })
    }

    fn read(&mut self, inner: &str) -> Result<Vec<u8>, String> {
        let path = self.full(inner);
        self.handle
            .block_on(self.session.read(path))
            .map_err(|e| format!("下载失败：{e}"))
    }

    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String> {
        let path = self.full(inner);
        self.handle
            .block_on(self.session.write(path, data))
            .map_err(|e| format!("上传失败：{e}"))
    }

    fn mkdir(&mut self, inner: &str) -> Result<(), String> {
        let path = self.full(inner);
        self.handle
            .block_on(self.session.create_dir(path))
            .map_err(|e| format!("创建目录失败：{e}"))
    }

    fn remove(&mut self, inner: &str, is_dir: bool) -> Result<(), String> {
        let path = self.full(inner);
        let result = if is_dir {
            self.handle.block_on(self.session.remove_dir(path))
        } else {
            self.handle.block_on(self.session.remove_file(path))
        };
        result.map_err(|e| format!("删除失败：{e}"))
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        let from = self.full(from);
        let to = self.full(to);
        self.handle
            .block_on(self.session.rename(from, to))
            .map_err(|e| format!("重命名失败：{e}"))
    }
}
