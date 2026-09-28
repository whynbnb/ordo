use super::{normalize_base, ProfileSpec, RemoteEntry, RemoteFs};
use smb2::{ClientConfig, SmbClient, Tree};
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;

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

pub struct SmbRemote {
    handle: tokio::runtime::Handle,
    client: SmbClient,
    tree: Tree,
    base: String,
}

impl SmbRemote {
    pub fn connect(profile: &ProfileSpec) -> Result<Self, String> {
        let share = profile.share.trim().to_string();
        if share.is_empty() {
            return Err("请填写 SMB 共享名".into());
        }
        let port = if profile.port == 0 { 445 } else { profile.port };
        let addr = format!("{}:{}", profile.host.trim(), port);
        let handle = runtime().handle().clone();

        let (client, tree) = handle.block_on(async move {
            let mut client = SmbClient::connect(ClientConfig {
                addr,
                timeout: Duration::from_secs(15),
                username: profile.username.clone(),
                password: profile.password.clone(),
                domain: profile.domain.clone(),
                auto_reconnect: true,
                compression: true,
                dfs_enabled: false,
                dfs_target_overrides: HashMap::new(),
                connect_options: None,
            })
            .await
            .map_err(|e| format!("SMB 连接失败：{e}"))?;
            let tree = client
                .connect_share(&share)
                .await
                .map_err(|e| format!("打开共享失败：{e}"))?;
            Ok::<_, String>((client, tree))
        })?;

        let base = normalize_base(&profile.base_path)
            .trim_matches('/')
            .to_string();
        Ok(SmbRemote {
            handle,
            client,
            tree,
            base,
        })
    }

    /// inner（以 `/` 开头）-> 共享内相对路径（无前导 `/`）。
    fn smb_path(&self, inner: &str) -> String {
        let inner = inner.trim_matches('/');
        match (self.base.as_str(), inner) {
            ("", _) => inner.to_string(),
            (base, "") => base.to_string(),
            (base, rest) => format!("{base}/{rest}"),
        }
    }
}

impl RemoteFs for SmbRemote {
    fn test(&mut self) -> Result<(), String> {
        let path = self.smb_path("/");
        let list_path = if path.is_empty() {
            String::new()
        } else {
            format!("{path}/")
        };
        self.handle
            .block_on(self.client.list_directory(&mut self.tree, &list_path))
            .map(|_| ())
            .map_err(|e| format!("SMB 连接测试失败：{e}"))
    }

    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        let path = self.smb_path(inner);
        let list_path = if path.is_empty() {
            String::new()
        } else {
            format!("{path}/")
        };
        let entries = self
            .handle
            .block_on(self.client.list_directory(&mut self.tree, &list_path))
            .map_err(|e| format!("读取目录失败：{e}"))?;
        Ok(entries
            .into_iter()
            .map(|e| RemoteEntry {
                name: e.name,
                is_dir: e.is_directory,
                size: if e.is_directory { 0 } else { e.size },
                modified: e
                    .modified
                    .to_system_time()
                    .map(super::system_time_to_secs)
                    .unwrap_or(0),
            })
            .collect())
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
        let path = self.smb_path(inner);
        let info = self
            .handle
            .block_on(self.client.stat(&mut self.tree, &path))
            .map_err(|e| format!("获取信息失败：{e}"))?;
        let name = inner.trim_end_matches('/').rsplit('/').next().unwrap_or("");
        Ok(RemoteEntry {
            name: name.to_string(),
            is_dir: info.is_directory,
            size: if info.is_directory { 0 } else { info.size },
            modified: info
                .modified
                .to_system_time()
                .map(super::system_time_to_secs)
                .unwrap_or(0),
        })
    }

    fn read(&mut self, inner: &str) -> Result<Vec<u8>, String> {
        let path = self.smb_path(inner);
        self.handle
            .block_on(self.client.read_file(&mut self.tree, &path))
            .map_err(|e| format!("下载失败：{e}"))
    }

    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String> {
        let path = self.smb_path(inner);
        self.handle
            .block_on(self.client.write_file(&mut self.tree, &path, data))
            .map(|_| ())
            .map_err(|e| format!("上传失败：{e}"))
    }

    fn mkdir(&mut self, inner: &str) -> Result<(), String> {
        let path = self.smb_path(inner);
        self.handle
            .block_on(self.client.create_directory(&mut self.tree, &path))
            .map_err(|e| format!("创建目录失败：{e}"))
    }

    fn remove(&mut self, inner: &str, is_dir: bool) -> Result<(), String> {
        let path = self.smb_path(inner);
        if is_dir {
            self.handle
                .block_on(self.client.delete_directory(&mut self.tree, &path))
                .map_err(|e| format!("删除目录失败：{e}"))
        } else {
            self.handle
                .block_on(self.client.delete_file(&mut self.tree, &path))
                .map_err(|e| format!("删除失败：{e}"))
        }
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        let from_path = self.smb_path(from);
        let to_path = self.smb_path(to);
        self.handle
            .block_on(self.client.rename(&mut self.tree, &from_path, &to_path))
            .map_err(|e| format!("重命名失败：{e}"))
    }
}
