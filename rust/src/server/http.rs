//! HTTP / WebDAV 文件服务器。
//!
//! 浏览器可直接浏览 / 下载；Windows、macOS、Linux 可将其映射为网络驱动器。
//! 支持 `GET`、`HEAD`、`PUT`、`DELETE`、`MKCOL`、`PROPFIND`、`PROPPATCH`、
//! `MOVE`、`COPY`、`LOCK`、`UNLOCK` 与 `OPTIONS`。

use super::fsutil;
use super::ServerCtx;
use std::io::Read;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tiny_http::{Header, Request, Response, Server};

pub fn bind(port: u16) -> Result<Server, String> {
    Server::http(("0.0.0.0", port)).map_err(|e| format!("HTTP 端口 {port} 绑定失败：{e}"))
}

pub fn serve(server: Server, ctx: Arc<ServerCtx>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Relaxed) {
        match server.recv_timeout(Duration::from_millis(200)) {
            Ok(Some(request)) => handle(request, &ctx),
            Ok(None) => {}
            Err(_) => {}
        }
    }
}

fn header<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}

fn respond(req: Request, code: u16, body: Vec<u8>, content_type: &str) {
    let mut response = Response::from_data(body).with_status_code(code);
    if !content_type.is_empty() {
        if let Ok(header) = Header::from_bytes(&b"Content-Type"[..], content_type.as_bytes()) {
            response = response.with_header(header);
        }
    }
    let _ = req.respond(response);
}

fn respond_text(req: Request, code: u16, body: String) {
    respond(req, code, body.into_bytes(), "text/plain; charset=utf-8");
}

fn respond_html(req: Request, code: u16, body: String) {
    respond(req, code, body.into_bytes(), "text/html; charset=utf-8");
}

fn respond_xml(req: Request, code: u16, body: String) {
    respond(
        req,
        code,
        body.into_bytes(),
        "application/xml; charset=utf-8",
    );
}

fn unauthorized(req: Request) {
    let response = Response::from_string("需要登录")
        .with_status_code(401)
        .with_header(
            Header::from_bytes(&b"WWW-Authenticate"[..], &b"Basic realm=\"Ordo\""[..]).unwrap(),
        )
        .with_header(
            Header::from_bytes(&b"Content-Type"[..], &b"text/plain; charset=utf-8"[..]).unwrap(),
        );
    let _ = req.respond(response);
}

fn handle(request: Request, ctx: &ServerCtx) {
    let method = request.method().as_str().to_ascii_uppercase();
    if ctx.auth && method != "OPTIONS" && !authorized(&request, ctx) {
        unauthorized(request);
        return;
    }
    match method.as_str() {
        "OPTIONS" => options(request),
        "GET" => get(request, ctx, false),
        "HEAD" => get(request, ctx, true),
        "PROPFIND" => propfind(request, ctx),
        "PROPPATCH" => proppatch(request),
        "PUT" => put(request, ctx),
        "DELETE" => delete(request, ctx),
        "MKCOL" => mkcol(request, ctx),
        "MOVE" => move_or_copy(request, ctx, true),
        "COPY" => move_or_copy(request, ctx, false),
        "LOCK" => lock(request),
        "UNLOCK" => respond(request, 204, Vec::new(), ""),
        _ => respond_text(request, 405, "方法不被支持".into()),
    }
}

fn authorized(req: &Request, ctx: &ServerCtx) -> bool {
    let Some(value) = header(req, "authorization") else {
        return false;
    };
    let encoded = if let Some(v) = value.strip_prefix("Basic ") {
        v
    } else if let Some(v) = value.strip_prefix("basic ") {
        v
    } else {
        return false;
    };
    use base64::Engine;
    let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(encoded.trim()) else {
        return false;
    };
    let Ok(text) = String::from_utf8(decoded) else {
        return false;
    };
    match text.split_once(':') {
        Some((user, pass)) => user == ctx.username && pass == ctx.password,
        None => false,
    }
}

fn options(req: Request) {
    let response = Response::empty(200)
        .with_header(Header::from_bytes(&b"DAV"[..], &b"1, 2"[..]).unwrap())
        .with_header(
            Header::from_bytes(
                &b"Allow"[..],
                &b"OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK"[..],
            )
            .unwrap(),
        )
        .with_header(Header::from_bytes(&b"MS-Author-Via"[..], &b"DAV"[..]).unwrap());
    let _ = req.respond(response);
}

fn request_path(req: &Request) -> String {
    req.url().split('?').next().unwrap_or("/").to_string()
}

fn resolve(req: &Request, ctx: &ServerCtx) -> Option<std::path::PathBuf> {
    let path = request_path(req);
    fsutil::resolve_rel(&ctx.root, &fsutil::decode(path.trim_start_matches('/')))
}

fn get(req: Request, ctx: &ServerCtx, head: bool) {
    let url = request_path(&req);
    let Some(fs_path) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    if !fs_path.exists() {
        respond_text(req, 404, "未找到".into());
        return;
    }

    if fs_path.is_dir() {
        if !url.ends_with('/') {
            let location = format!("{}/", fsutil::encode_path(&url));
            let response = Response::empty(301)
                .with_header(Header::from_bytes(&b"Location"[..], location.as_bytes()).unwrap());
            let _ = req.respond(response);
            return;
        }
        respond_html(req, 200, render_listing(&fs_path));
        return;
    }

    let Ok(meta) = std::fs::metadata(&fs_path) else {
        respond_text(req, 404, "未找到".into());
        return;
    };
    let len = meta.len();
    let modified = epoch(meta.modified().ok());
    let name = fs_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let content_type = fsutil::mime_for(&name);

    if head {
        let response = Response::empty(200)
            .with_header(Header::from_bytes(&b"Content-Type"[..], content_type.as_bytes()).unwrap())
            .with_header(Header::from_bytes(&b"Accept-Ranges"[..], &b"bytes"[..]).unwrap())
            .with_header(
                Header::from_bytes(
                    &b"Last-Modified"[..],
                    fsutil::http_date(modified).as_bytes(),
                )
                .unwrap(),
            );
        let _ = req.respond(response);
        return;
    }

    if let Some(range) = header(&req, "range").map(str::to_string) {
        if let Some((start, end)) = parse_range(&range, len) {
            use std::io::{Seek, SeekFrom};
            if let Ok(mut file) = std::fs::File::open(&fs_path) {
                let mut buffer = vec![0u8; (end - start + 1) as usize];
                if file.seek(SeekFrom::Start(start)).is_ok() && file.read_exact(&mut buffer).is_ok()
                {
                    let content_range = format!("bytes {start}-{end}/{len}");
                    let response = Response::from_data(buffer)
                        .with_status_code(206)
                        .with_header(
                            Header::from_bytes(&b"Content-Type"[..], content_type.as_bytes())
                                .unwrap(),
                        )
                        .with_header(
                            Header::from_bytes(&b"Accept-Ranges"[..], &b"bytes"[..]).unwrap(),
                        )
                        .with_header(
                            Header::from_bytes(&b"Content-Range"[..], content_range.as_bytes())
                                .unwrap(),
                        );
                    let _ = req.respond(response);
                    return;
                }
            }
        }
    }

    match std::fs::File::open(&fs_path) {
        Ok(file) => {
            let response = Response::from_file(file)
                .with_header(
                    Header::from_bytes(&b"Content-Type"[..], content_type.as_bytes()).unwrap(),
                )
                .with_header(Header::from_bytes(&b"Accept-Ranges"[..], &b"bytes"[..]).unwrap())
                .with_header(
                    Header::from_bytes(
                        &b"Last-Modified"[..],
                        fsutil::http_date(modified).as_bytes(),
                    )
                    .unwrap(),
                );
            let _ = req.respond(response);
        }
        Err(_) => respond_text(req, 500, "无法读取文件".into()),
    }
}

fn parse_range(value: &str, len: u64) -> Option<(u64, u64)> {
    let body = value.strip_prefix("bytes=")?;
    let (start, end) = body.split_once('-')?;
    if len == 0 {
        return None;
    }
    if start.trim().is_empty() {
        let count: u64 = end.trim().parse().ok()?;
        if count == 0 {
            return None;
        }
        let from = len.saturating_sub(count);
        Some((from, len - 1))
    } else {
        let from: u64 = start.trim().parse().ok()?;
        let to = if end.trim().is_empty() {
            len - 1
        } else {
            end.trim().parse::<u64>().ok()?.min(len - 1)
        };
        if from > to || from >= len {
            return None;
        }
        Some((from, to))
    }
}

fn render_listing(fs_path: &Path) -> String {
    let entries = crate::api::list_dir(&fs_path.to_string_lossy()).unwrap_or_default();
    let mut rows = String::new();
    rows.push_str("<tr><td>📁 <a href=\"../\">../</a></td><td>—</td><td>—</td></tr>");
    for entry in entries {
        let href = format!(
            "{}{}",
            fsutil::encode_path(&entry.name),
            if entry.is_dir { "/" } else { "" }
        );
        let icon = if entry.is_dir { "📁" } else { "📄" };
        let size = if entry.is_dir {
            "—".to_string()
        } else {
            fsutil::human_size(entry.size)
        };
        let modified = fsutil::format_display(entry.modified);
        rows.push_str(&format!(
            "<tr><td>{icon} <a href=\"{href}\">{name}</a></td><td>{size}</td><td>{modified}</td></tr>",
            name = fsutil::html_escape(&entry.name),
        ));
    }
    format!(
        "<!doctype html><html lang=\"zh\"><head><meta charset=\"utf-8\">\
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
<title>安序 Ordo</title><style>\
body{{font-family:system-ui,-apple-system,'Segoe UI',sans-serif;margin:0;background:#fafafa;color:#222}}\
header{{background:#6750a4;color:#fff;padding:16px 24px}}\
header h1{{margin:0;font-size:20px;font-weight:600}}\
main{{padding:16px 24px}}\
table{{border-collapse:collapse;width:100%;max-width:900px}}\
th,td{{text-align:left;padding:8px 12px;border-bottom:1px solid #eee;white-space:nowrap}}\
td:first-child{{overflow:hidden;text-overflow:ellipsis;max-width:520px}}\
a{{color:#6750a4;text-decoration:none}}a:hover{{text-decoration:underline}}\
</style></head><body><header><h1>安序 Ordo · 文件服务器</h1></header><main>\
<table><thead><tr><th>名称</th><th>大小</th><th>修改时间</th></tr></thead>\
<tbody>{rows}</tbody></table></main></body></html>"
    )
}

fn propfind(req: Request, ctx: &ServerCtx) {
    let url = request_path(&req);
    let Some(fs_path) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    if !fs_path.exists() {
        respond_text(req, 404, "未找到".into());
        return;
    }
    let depth = header(&req, "depth").unwrap_or("1").to_string();
    let is_dir = fs_path.is_dir();
    let base = if is_dir {
        if url.ends_with('/') {
            url
        } else {
            format!("{url}/")
        }
    } else {
        url
    };

    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n",
    );
    append_response(&mut xml, &base, &fs_path, is_dir);
    if is_dir && depth != "0" {
        if let Ok(entries) = crate::api::list_dir(&fs_path.to_string_lossy()) {
            for entry in entries {
                let href = format!(
                    "{base}{}{}",
                    fsutil::encode_path(&entry.name),
                    if entry.is_dir { "/" } else { "" }
                );
                append_response(&mut xml, &href, &fs_path.join(&entry.name), entry.is_dir);
            }
        }
    }
    xml.push_str("</D:multistatus>");

    let response = Response::from_string(xml)
        .with_status_code(207)
        .with_header(
            Header::from_bytes(&b"Content-Type"[..], &b"application/xml; charset=utf-8"[..])
                .unwrap(),
        )
        .with_header(Header::from_bytes(&b"DAV"[..], &b"1, 2"[..]).unwrap());
    let _ = req.respond(response);
}

fn append_response(xml: &mut String, href: &str, path: &Path, is_dir: bool) {
    let meta = std::fs::metadata(path).ok();
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/".into());
    let modified = epoch(meta.as_ref().and_then(|m| m.modified().ok()));

    xml.push_str("<D:response>\n");
    xml.push_str(&format!("<D:href>{}</D:href>\n", fsutil::xml_escape(href)));
    xml.push_str("<D:propstat>\n<D:prop>\n");
    xml.push_str(&format!(
        "<D:displayname>{}</D:displayname>\n",
        fsutil::xml_escape(&name)
    ));
    if is_dir {
        xml.push_str("<D:resourcetype><D:collection/></D:resourcetype>\n");
    } else {
        xml.push_str("<D:resourcetype/>\n");
        let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        xml.push_str(&format!(
            "<D:getcontentlength>{size}</D:getcontentlength>\n"
        ));
        xml.push_str(&format!(
            "<D:getcontenttype>{}</D:getcontenttype>\n",
            fsutil::xml_escape(fsutil::mime_for(&name))
        ));
    }
    if modified > 0 {
        xml.push_str(&format!(
            "<D:getlastmodified>{}</D:getlastmodified>\n",
            fsutil::http_date(modified)
        ));
    }
    xml.push_str("</D:prop>\n<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n</D:response>\n");
}

fn proppatch(req: Request) {
    let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">\
<D:response><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status>\
</D:propstat></D:response></D:multistatus>";
    respond_xml(req, 207, xml.to_string());
}

fn put(mut req: Request, ctx: &ServerCtx) {
    if ctx.read_only {
        respond_text(req, 403, "服务器为只读".into());
        return;
    }
    let Some(fs_path) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    if fs_path.is_dir() {
        respond_text(req, 405, "目标是目录".into());
        return;
    }
    let existed = fs_path.exists();
    let mut body = Vec::new();
    if req.as_reader().read_to_end(&mut body).is_err() {
        respond_text(req, 500, "读取请求失败".into());
        return;
    }
    if let Some(parent) = fs_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    match std::fs::write(&fs_path, &body) {
        Ok(_) => respond(req, if existed { 204 } else { 201 }, Vec::new(), ""),
        Err(e) => respond_text(req, 500, format!("写入失败：{e}")),
    }
}

fn delete(req: Request, ctx: &ServerCtx) {
    if ctx.read_only {
        respond_text(req, 403, "服务器为只读".into());
        return;
    }
    let Some(fs_path) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    let result = if fs_path.is_dir() {
        std::fs::remove_dir_all(&fs_path)
    } else if fs_path.exists() {
        std::fs::remove_file(&fs_path)
    } else {
        respond_text(req, 404, "未找到".into());
        return;
    };
    match result {
        Ok(_) => respond(req, 204, Vec::new(), ""),
        Err(e) => respond_text(req, 500, format!("删除失败：{e}")),
    }
}

fn mkcol(req: Request, ctx: &ServerCtx) {
    if ctx.read_only {
        respond_text(req, 403, "服务器为只读".into());
        return;
    }
    let Some(fs_path) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    if fs_path.exists() {
        respond_text(req, 405, "已存在".into());
        return;
    }
    match std::fs::create_dir(&fs_path) {
        Ok(_) => respond(req, 201, Vec::new(), ""),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            respond_text(req, 409, "父目录不存在".into())
        }
        Err(e) => respond_text(req, 500, format!("创建失败：{e}")),
    }
}

fn destination_path(value: &str) -> String {
    let trimmed = value.trim();
    let path = if let Some(rest) = trimmed.strip_prefix("http://") {
        rest.find('/').map(|i| &rest[i..]).unwrap_or("/")
    } else if let Some(rest) = trimmed.strip_prefix("https://") {
        rest.find('/').map(|i| &rest[i..]).unwrap_or("/")
    } else {
        trimmed
    };
    fsutil::decode(path.split('?').next().unwrap_or("/"))
}

fn move_or_copy(req: Request, ctx: &ServerCtx, is_move: bool) {
    if ctx.read_only {
        respond_text(req, 403, "服务器为只读".into());
        return;
    }
    let Some(source) = resolve(&req, ctx) else {
        respond_text(req, 403, "禁止访问".into());
        return;
    };
    let Some(destination) = header(&req, "destination") else {
        respond_text(req, 400, "缺少 Destination".into());
        return;
    };
    let Some(target) = fsutil::resolve_rel(
        &ctx.root,
        destination_path(destination).trim_start_matches('/'),
    ) else {
        respond_text(req, 403, "目标路径非法".into());
        return;
    };
    if !source.exists() {
        respond_text(req, 404, "源不存在".into());
        return;
    }
    let overwrite = header(&req, "overwrite")
        .map(|v| v.eq_ignore_ascii_case("t"))
        .unwrap_or(true);
    let target_existed = target.exists();
    if target_existed {
        if !overwrite {
            respond_text(req, 412, "目标已存在".into());
            return;
        }
        let _ = if target.is_dir() {
            std::fs::remove_dir_all(&target)
        } else {
            std::fs::remove_file(&target)
        };
    }

    let result = if is_move {
        std::fs::rename(&source, &target).or_else(|_| {
            fsutil::copy_path(&source, &target).and_then(|_| {
                if source.is_dir() {
                    std::fs::remove_dir_all(&source)
                } else {
                    std::fs::remove_file(&source)
                }
            })
        })
    } else {
        fsutil::copy_path(&source, &target)
    };

    match result {
        Ok(_) => respond(req, if target_existed { 204 } else { 201 }, Vec::new(), ""),
        Err(e) => respond_text(req, 500, format!("操作失败：{e}")),
    }
}

fn lock(req: Request) {
    let token = format!("opaquelocktoken:{}", random_token());
    let body = format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:prop xmlns:D=\"DAV:\"><D:lockdiscovery>\
<D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>\
<D:depth>infinity</D:depth><D:timeout>Second-3600</D:timeout>\
<D:locktoken><D:href>{token}</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>"
    );
    let response = Response::from_string(body)
        .with_status_code(200)
        .with_header(
            Header::from_bytes(&b"Content-Type"[..], &b"application/xml; charset=utf-8"[..])
                .unwrap(),
        )
        .with_header(
            Header::from_bytes(&b"Lock-Token"[..], format!("<{token}>").as_bytes()).unwrap(),
        );
    let _ = req.respond(response);
}

fn epoch(time: Option<std::time::SystemTime>) -> i64 {
    time.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn random_token() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}{:x}", std::process::id())
}
