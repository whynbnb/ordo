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

/// SMB 连接。
///
/// - 固定了共享名时：以该共享（及其可选子目录）为根。
/// - 共享名为空时：以服务器共享列表为根，第一级路径即为共享名。
pub struct SmbRemote {
    handle: tokio::runtime::Handle,
    client: SmbClient,
    trees: HashMap<String, Tree>,
    share: String,
    base: String,
}

impl SmbRemote {
    pub fn connect(profile: &ProfileSpec) -> Result<Self, String> {
        let port = if profile.port == 0 { 445 } else { profile.port };
        let addr = format!("{}:{}", profile.host.trim(), port);
        let handle = runtime().handle().clone();

        let client = handle
            .block_on(SmbClient::connect(ClientConfig {
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
            }))
            .map_err(|e| format!("SMB 连接失败：{e}"))?;

        let share = profile.share.trim().to_string();
        let base = if share.is_empty() {
            String::new()
        } else {
            normalize_base(&profile.base_path)
                .trim_matches('/')
                .to_string()
        };

        let mut remote = SmbRemote {
            handle,
            client,
            trees: HashMap::new(),
            share,
            base,
        };
        if !remote.share.is_empty() {
            remote.ensure_tree(&remote.share.clone())?;
        }
        Ok(remote)
    }

    /// inner（以 `/` 开头）-> 共享内相对路径（无前导 `/`，固定共享时叠加 base）。
    fn smb_path(&self, inner: &str) -> String {
        let inner = inner.trim_matches('/');
        match (self.base.as_str(), inner) {
            ("", _) => inner.to_string(),
            (base, "") => base.to_string(),
            (base, rest) => format!("{base}/{rest}"),
        }
    }

    /// 解析出（共享名, 共享内相对路径）。共享名可能为 `None`（服务器根）。
    fn resolve(&self, inner: &str) -> (Option<String>, String) {
        if !self.share.is_empty() {
            return (Some(self.share.clone()), self.smb_path(inner));
        }
        let trimmed = inner.trim_matches('/');
        if trimmed.is_empty() {
            return (None, String::new());
        }
        let mut parts = trimmed.splitn(2, '/');
        let share = parts.next().unwrap_or("").to_string();
        let rest = parts.next().unwrap_or("").to_string();
        (Some(share), rest)
    }

    fn ensure_tree(&mut self, share: &str) -> Result<(), String> {
        if self.trees.contains_key(share) {
            return Ok(());
        }
        let tree = {
            let SmbRemote { handle, client, .. } = self;
            handle
                .block_on(client.connect_share(share))
                .map_err(|e| format!("打开共享「{share}」失败：{e}"))?
        };
        self.trees.insert(share.to_string(), tree);
        Ok(())
    }

    fn list_shares(&mut self) -> Result<Vec<RemoteEntry>, String> {
        let SmbRemote { handle, client, .. } = self;
        let shares = handle
            .block_on(client.list_shares())
            .map_err(|e| format!("枚举共享失败：{e}"))?;
        Ok(shares
            .into_iter()
            .filter(|s| !s.name.is_empty())
            .map(|s| RemoteEntry {
                name: s.name,
                is_dir: true,
                size: 0,
                modified: 0,
            })
            .collect())
    }

    fn directory_entry(name: String) -> RemoteEntry {
        RemoteEntry {
            name,
            is_dir: true,
            size: 0,
            modified: 0,
        }
    }
}

impl RemoteFs for SmbRemote {
    fn test(&mut self) -> Result<(), String> {
        let (share, rel) = self.resolve("/");
        match share {
            None => {
                self.list_shares()?;
                Ok(())
            }
            Some(share) => {
                self.ensure_tree(&share)?;
                let list_path = if rel.is_empty() {
                    String::new()
                } else {
                    format!("{rel}/")
                };
                let handle = self.handle.clone();
                let SmbRemote { client, trees, .. } = self;
                let tree = trees.get_mut(&share).expect("tree exists");
                handle
                    .block_on(client.list_directory(tree, &list_path))
                    .map(|_| ())
                    .map_err(|e| format!("SMB 连接测试失败：{e}"))
            }
        }
    }

    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        let (share, rel) = self.resolve(inner);
        let Some(share) = share else {
            return self.list_shares();
        };
        self.ensure_tree(&share)?;
        let list_path = if rel.is_empty() {
            String::new()
        } else {
            format!("{rel}/")
        };
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        let entries = handle
            .block_on(client.list_directory(tree, &list_path))
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
        let (share, rel) = self.resolve(inner);
        let Some(share) = share else {
            return Ok(Self::directory_entry("/".into()));
        };
        if rel.is_empty() && self.share.is_empty() {
            return Ok(Self::directory_entry(share));
        }
        self.ensure_tree(&share)?;
        if rel.is_empty() {
            return Ok(Self::directory_entry(share));
        }
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        let info = handle
            .block_on(client.stat(tree, &rel))
            .map_err(|e| format!("获取信息失败：{e}"))?;
        let name = rel.rsplit('/').next().unwrap_or("");
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
        let (share, rel) = self.resolve(inner);
        let share = share.ok_or_else(|| "请先进入一个共享".to_string())?;
        self.ensure_tree(&share)?;
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        // 不能使用 `read_file`：它走「CREATE+READ+CLOSE」复合请求，单个 READ 受
        // 服务器 MaxReadSize（通常 8MB）限制，超过即报 FileTooLargeForSingleRead，
        // 也就是「较大的文件下载失败」。`read_file_pipelined` 会分块并发读取任意
        // 大小（小文件仍是单次读取），因此这里统一使用它。
        handle
            .block_on(client.read_file_pipelined(tree, &rel))
            .map_err(|e| format!("下载失败：{e}"))
    }

    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String> {
        let (share, rel) = self.resolve(inner);
        let share = share.ok_or_else(|| "请先进入一个共享".to_string())?;
        self.ensure_tree(&share)?;
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        handle
            .block_on(client.write_file(tree, &rel, data))
            .map(|_| ())
            .map_err(|e| format!("上传失败：{e}"))
    }

    fn mkdir(&mut self, inner: &str) -> Result<(), String> {
        let (share, rel) = self.resolve(inner);
        let share = share.ok_or_else(|| "请先进入一个共享".to_string())?;
        self.ensure_tree(&share)?;
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        handle
            .block_on(client.create_directory(tree, &rel))
            .map_err(|e| format!("创建目录失败：{e}"))
    }

    fn remove(&mut self, inner: &str, is_dir: bool) -> Result<(), String> {
        let (share, rel) = self.resolve(inner);
        let share = share.ok_or_else(|| "请先进入一个共享".to_string())?;
        self.ensure_tree(&share)?;
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&share).expect("tree exists");
        if is_dir {
            handle
                .block_on(client.delete_directory(tree, &rel))
                .map_err(|e| format!("删除目录失败：{e}"))
        } else {
            handle
                .block_on(client.delete_file(tree, &rel))
                .map_err(|e| format!("删除失败：{e}"))
        }
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        let (from_share, from_rel) = self.resolve(from);
        let (to_share, to_rel) = self.resolve(to);
        let (Some(from_share), Some(to_share)) = (from_share, to_share) else {
            return Err("请先进入一个共享".into());
        };
        if from_share != to_share {
            return Err("不支持跨共享重命名".into());
        }
        self.ensure_tree(&from_share)?;
        let handle = self.handle.clone();
        let SmbRemote { client, trees, .. } = self;
        let tree = trees.get_mut(&from_share).expect("tree exists");
        handle
            .block_on(client.rename(tree, &from_rel, &to_rel))
            .map_err(|e| format!("重命名失败：{e}"))
    }
}
