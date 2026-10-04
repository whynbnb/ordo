//! 收藏夹（书签）：把常用文件夹固定到主页，配置持久化到应用私有目录。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Favorite {
    #[serde(default)]
    pub name: String,
    pub path: String,
}

fn file() -> Option<std::path::PathBuf> {
    crate::remote::config_dir().map(|dir| dir.join("ordo_favorites.json"))
}

pub fn list() -> Vec<Favorite> {
    let Some(file) = file() else {
        return Vec::new();
    };
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save(items: &[Favorite]) -> Result<(), String> {
    let Some(file) = file() else {
        return Err("配置目录不可用".into());
    };
    if let Some(parent) = file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let text = serde_json::to_string_pretty(items).map_err(|e| format!("序列化失败：{e}"))?;
    std::fs::write(file, text).map_err(|e| format!("保存失败：{e}"))
}

pub fn add(name: &str, path: &str) -> Result<Vec<Favorite>, String> {
    let path = path.trim();
    if path.is_empty() {
        return Err("路径为空".into());
    }
    let mut items = list();
    if !items.iter().any(|favorite| favorite.path == path) {
        let label = if name.trim().is_empty() {
            path.trim_end_matches('/')
                .rsplit('/')
                .next()
                .unwrap_or(path)
                .to_string()
        } else {
            name.trim().to_string()
        };
        items.push(Favorite {
            name: label,
            path: path.to_string(),
        });
        save(&items)?;
    }
    Ok(items)
}

pub fn remove(path: &str) -> Result<Vec<Favorite>, String> {
    let mut items = list();
    items.retain(|favorite| favorite.path != path);
    save(&items)?;
    Ok(items)
}
