use super::{normalize_base, ProfileSpec, RemoteEntry, RemoteFs};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use quick_xml::events::Event;
use quick_xml::Reader;
use std::time::Duration;

const PATH_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:resourcetype/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:displayname/>
  </D:prop>
</D:propfind>"#;

pub struct WebdavRemote {
    client: reqwest::blocking::Client,
    base: String,
    user: String,
    pass: String,
}

#[derive(Default)]
struct DavItem {
    href: String,
    is_dir: bool,
    size: u64,
    modified: i64,
}

impl WebdavRemote {
    pub fn connect(profile: &ProfileSpec) -> Result<Self, String> {
        let client = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(profile.insecure_tls)
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|e| format!("初始化 HTTP 客户端失败：{e}"))?;
        Ok(WebdavRemote {
            client,
            base: build_base(profile),
            user: profile.username.clone(),
            pass: profile.password.clone(),
        })
    }

    fn url(&self, inner: &str) -> String {
        let mut url = self.base.trim_end_matches('/').to_string();
        if inner.is_empty() || inner == "/" {
            url.push('/');
        } else {
            url.push_str(&encode_path(inner));
        }
        url
    }

    fn request(&self, method: &str, url: &str) -> reqwest::blocking::RequestBuilder {
        let method = reqwest::Method::from_bytes(method.as_bytes()).expect("valid HTTP method");
        let builder = self.client.request(method, url);
        if self.user.is_empty() {
            builder
        } else {
            builder.basic_auth(&self.user, Some(&self.pass))
        }
    }

    fn propfind(&self, inner: &str, depth: u32) -> Result<Vec<DavItem>, String> {
        let url = self.url(inner);
        let response = self
            .request("PROPFIND", &url)
            .header("Depth", depth.to_string())
            .header("Content-Type", "application/xml; charset=utf-8")
            .body(PROPFIND_BODY)
            .send()
            .map_err(|e| format!("WebDAV 请求失败：{e}"))?;
        let status = response.status();
        if !status.is_success() {
            return Err(format!("WebDAV 返回 {status}"));
        }
        let text = response.text().map_err(|e| format!("读取响应失败：{e}"))?;
        Ok(parse_multistatus(&text))
    }
}

impl RemoteFs for WebdavRemote {
    fn test(&mut self) -> Result<(), String> {
        let url = self.url("/");
        let response = self
            .request("PROPFIND", &url)
            .header("Depth", "0")
            .header("Content-Type", "application/xml; charset=utf-8")
            .body(PROPFIND_BODY)
            .send()
            .map_err(|e| format!("WebDAV 连接测试失败：{e}"))?;
        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("WebDAV 返回 {status}"))
        }
    }

    fn list(&mut self, inner: &str) -> Result<Vec<RemoteEntry>, String> {
        let target = path_of_url(&self.url(inner));
        let items = self.propfind(inner, 1)?;
        let target_norm = target.trim_end_matches('/').to_string();

        let mut entries = Vec::new();
        for item in items {
            let href_path = path_of_href(&item.href);
            if href_path.trim_end_matches('/') == target_norm {
                continue;
            }
            let name = last_segment(&href_path);
            if name.is_empty() {
                continue;
            }
            entries.push(RemoteEntry {
                name,
                is_dir: item.is_dir,
                size: item.size,
                modified: item.modified,
            });
        }
        Ok(entries)
    }

    fn stat(&mut self, inner: &str) -> Result<RemoteEntry, String> {
        let items = self.propfind(inner, 0)?;
        let item = items
            .into_iter()
            .next()
            .ok_or_else(|| "无法获取条目信息".to_string())?;
        let href_path = path_of_href(&item.href);
        let name = last_segment(&href_path);
        Ok(RemoteEntry {
            name: if name.is_empty() { "/".into() } else { name },
            is_dir: item.is_dir,
            size: item.size,
            modified: item.modified,
        })
    }

    fn read(&mut self, inner: &str) -> Result<Vec<u8>, String> {
        let url = self.url(inner);
        let response = self
            .request("GET", &url)
            .send()
            .map_err(|e| format!("下载失败：{e}"))?;
        let status = response.status();
        if !status.is_success() {
            return Err(format!("下载失败：{status}"));
        }
        let bytes = response.bytes().map_err(|e| format!("读取失败：{e}"))?;
        Ok(bytes.to_vec())
    }

    fn write(&mut self, inner: &str, data: &[u8]) -> Result<(), String> {
        let url = self.url(inner);
        let response = self
            .request("PUT", &url)
            .body(data.to_vec())
            .send()
            .map_err(|e| format!("上传失败：{e}"))?;
        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("上传失败：{status}"))
        }
    }

    fn mkdir(&mut self, inner: &str) -> Result<(), String> {
        let url = self.url(inner);
        let response = self
            .request("MKCOL", &url)
            .send()
            .map_err(|e| format!("创建目录失败：{e}"))?;
        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("创建目录失败：{status}"))
        }
    }

    fn remove(&mut self, inner: &str, _is_dir: bool) -> Result<(), String> {
        let url = self.url(inner);
        let response = self
            .request("DELETE", &url)
            .send()
            .map_err(|e| format!("删除失败：{e}"))?;
        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("删除失败：{status}"))
        }
    }

    fn rename(&mut self, from: &str, to: &str) -> Result<(), String> {
        let from_url = self.url(from);
        let to_url = self.url(to);
        let response = self
            .request("MOVE", &from_url)
            .header("Destination", to_url)
            .header("Overwrite", "T")
            .send()
            .map_err(|e| format!("重命名失败：{e}"))?;
        let status = response.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!("重命名失败：{status}"))
        }
    }
}

fn build_base(profile: &ProfileSpec) -> String {
    let host = profile.host.trim();
    let authority = if host.starts_with("http://") || host.starts_with("https://") {
        host.trim_end_matches('/').to_string()
    } else {
        let scheme = if profile.secure { "https" } else { "http" };
        let default_port = if profile.secure { 443 } else { 80 };
        if profile.port == 0 || profile.port == default_port {
            format!("{scheme}://{host}")
        } else {
            format!("{scheme}://{host}:{}", profile.port)
        }
    };
    let base = normalize_base(&profile.base_path);
    format!("{authority}{base}")
}

fn encode_path(inner: &str) -> String {
    inner
        .split('/')
        .map(|segment| utf8_percent_encode(segment, PATH_SET).to_string())
        .collect::<Vec<_>>()
        .join("/")
}

/// 取 href 的路径部分（解码、去掉协议与主机、去掉结尾 `/`）。
fn path_of_href(href: &str) -> String {
    let decoded = percent_encoding::percent_decode_str(href)
        .decode_utf8_lossy()
        .to_string();
    strip_authority(&decoded).trim_end_matches('/').to_string()
}

fn path_of_url(url: &str) -> String {
    strip_authority(url).trim_end_matches('/').to_string()
}

fn strip_authority(value: &str) -> String {
    if let Some(rest) = value.strip_prefix("https://") {
        return match rest.find('/') {
            Some(index) => rest[index..].to_string(),
            None => "/".to_string(),
        };
    }
    if let Some(rest) = value.strip_prefix("http://") {
        return match rest.find('/') {
            Some(index) => rest[index..].to_string(),
            None => "/".to_string(),
        };
    }
    value.to_string()
}

fn last_segment(path: &str) -> String {
    path.trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .to_string()
}

enum Capture {
    None,
    Href,
    Size,
    Modified,
}

fn parse_multistatus(xml: &str) -> Vec<DavItem> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut items = Vec::new();
    let mut current: Option<DavItem> = None;
    let mut capture = Capture::None;
    let mut buffer = String::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(event)) => {
                let name = event.local_name();
                match name.as_ref() {
                    b"response" => current = Some(DavItem::default()),
                    b"href" => {
                        capture = Capture::Href;
                        buffer.clear();
                    }
                    b"getcontentlength" => {
                        capture = Capture::Size;
                        buffer.clear();
                    }
                    b"getlastmodified" => {
                        capture = Capture::Modified;
                        buffer.clear();
                    }
                    b"collection" => {
                        if let Some(item) = current.as_mut() {
                            item.is_dir = true;
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(event)) => {
                if event.local_name().as_ref() == b"collection" {
                    if let Some(item) = current.as_mut() {
                        item.is_dir = true;
                    }
                }
            }
            Ok(Event::Text(text)) => {
                let value = text.unescape().unwrap_or_default().to_string();
                match capture {
                    Capture::Href => {
                        if let Some(item) = current.as_mut() {
                            item.href.push_str(&value);
                        }
                    }
                    Capture::Size | Capture::Modified => buffer.push_str(&value),
                    Capture::None => {}
                }
            }
            Ok(Event::End(event)) => match event.local_name().as_ref() {
                b"response" => {
                    if let Some(item) = current.take() {
                        items.push(item);
                    }
                }
                b"getcontentlength" => {
                    if let Some(item) = current.as_mut() {
                        item.size = buffer.trim().parse().unwrap_or(0);
                    }
                    capture = Capture::None;
                }
                b"getlastmodified" => {
                    if let Some(item) = current.as_mut() {
                        item.modified = httpdate::parse_http_date(buffer.trim())
                            .map(super::system_time_to_secs)
                            .unwrap_or(0);
                    }
                    capture = Capture::None;
                }
                b"href" => capture = Capture::None,
                _ => {}
            },
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }

    items
}
