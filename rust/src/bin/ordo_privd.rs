//! `ordo-privd` —— 以 shell（uid 2000）或 root 身份运行的辅助进程。
//!
//! 由 Android 原生层部署到 `/data/local/tmp` 后启动，在本机回环地址上监听，
//! 复用 [`ordo_core::api`] 的文件操作实现，代替普通应用访问被分区存储保护的
//! 目录（`Android/data`、`Android/obb`、`/data/data` 等）。
//!
//! 启动协议：
//! 1. 从标准输入读取一行作为访问令牌；
//! 2. 绑定 `127.0.0.1:0`，向标准输出打印 `ORDO_PRIVD <port>`；
//! 3. 接受连接，每条连接首帧必须为 `{"token":"..."}`，随后为 `{"op":...}` 请求。

use base64::Engine as _;
use ordo_core::api;
use ordo_core::model::FileEntry;
use serde::Serialize;
use serde_json::{json, Value};
use std::io::{BufRead, Read, Write};
use std::net::{TcpListener, TcpStream};

const MAX_FRAME: usize = 512 * 1024 * 1024;

fn main() {
    let mut token = String::new();
    {
        let stdin = std::io::stdin();
        let mut lock = stdin.lock();
        if lock.read_line(&mut token).is_err() {
            eprintln!("ordo-privd: 无法读取令牌");
            std::process::exit(2);
        }
    }
    let token = token.trim().to_string();
    if token.is_empty() {
        eprintln!("ordo-privd: 令牌为空");
        std::process::exit(2);
    }

    let listener = match TcpListener::bind(("127.0.0.1", 0)) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("ordo-privd: 无法绑定端口：{error}");
            std::process::exit(3);
        }
    };
    let port = match listener.local_addr() {
        Ok(address) => address.port(),
        Err(error) => {
            eprintln!("ordo-privd: 无法获取端口：{error}");
            std::process::exit(3);
        }
    };
    println!("ORDO_PRIVD {port}");
    let _ = std::io::stdout().flush();

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let token = token.clone();
                std::thread::spawn(move || {
                    let _ = handle(stream, &token);
                });
            }
            Err(_) => continue,
        }
    }
}

fn read_frame(stream: &mut TcpStream) -> std::io::Result<Value> {
    let mut len_bytes = [0u8; 4];
    stream.read_exact(&mut len_bytes)?;
    let len = u32::from_be_bytes(len_bytes) as usize;
    if len > MAX_FRAME {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }
    let mut buffer = vec![0u8; len];
    stream.read_exact(&mut buffer)?;
    serde_json::from_slice(&buffer)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

fn write_frame(stream: &mut TcpStream, value: &Value) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&bytes)?;
    stream.flush()
}

fn handle(mut stream: TcpStream, token: &str) -> std::io::Result<()> {
    let first = read_frame(&mut stream)?;
    if first["token"].as_str() != Some(token) {
        let _ = write_frame(&mut stream, &json!({ "ok": false, "error": "unauthorized" }));
        return Ok(());
    }
    write_frame(&mut stream, &json!({ "ok": true }))?;

    loop {
        let request = match read_frame(&mut stream) {
            Ok(value) => value,
            Err(_) => return Ok(()),
        };
        let response = dispatch(&request);
        write_frame(&mut stream, &response)?;
    }
}

fn ok<T: Serialize>(data: T) -> Value {
    json!({ "ok": true, "data": data })
}

fn err(message: impl Into<String>) -> Value {
    json!({ "ok": false, "error": message.into() })
}

fn wrap<T: Serialize>(result: Result<T, String>) -> Value {
    match result {
        Ok(data) => ok(data),
        Err(error) => err(error),
    }
}

fn string_field(request: &Value, key: &str) -> Result<String, String> {
    request[key]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("缺少参数：{key}"))
}

fn dispatch(request: &Value) -> Value {
    let op = request["op"].as_str().unwrap_or("");
    match op {
        "ping" => ok(json!({ "pid": std::process::id() })),
        "list" => match string_field(request, "path") {
            Ok(path) => wrap(api::list_dir(&path)),
            Err(error) => err(error),
        },
        "stat" => match string_field(request, "path") {
            Ok(path) => wrap(api::stat(&path)),
            Err(error) => err(error),
        },
        "read" => match string_field(request, "path") {
            Ok(path) => match api::read_bytes(&path) {
                Ok(bytes) => ok(json!({
                    "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
                })),
                Err(error) => err(error),
            },
            Err(error) => err(error),
        },
        "write" => {
            let path = match string_field(request, "path") {
                Ok(path) => path,
                Err(error) => return err(error),
            };
            let encoded = match string_field(request, "data") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            match base64::engine::general_purpose::STANDARD.decode(encoded) {
                Ok(bytes) => wrap(api::write_bytes(&path, &bytes)),
                Err(error) => err(format!("解码写入数据失败：{error}")),
            }
        }
        "create_dir" => match string_field(request, "path") {
            Ok(path) => wrap(api::create_dir(&path)),
            Err(error) => err(error),
        },
        "create_file" => match string_field(request, "path") {
            Ok(path) => wrap(api::create_file(&path)),
            Err(error) => err(error),
        },
        "symlink" => {
            let target = match string_field(request, "target") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            let link = match string_field(request, "link") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            wrap(api::create_symlink(&target, &link))
        }
        "delete" => match string_field(request, "path") {
            Ok(path) => {
                let result = api::delete(std::slice::from_ref(&path));
                if let Some(errors) = result["errors"].as_array() {
                    if let Some(first) = errors.first().and_then(|value| value.as_str()) {
                        return err(first.to_string());
                    }
                }
                ok(result)
            }
            Err(error) => err(error),
        },
        "rename" => {
            let path = match string_field(request, "path") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            let new_name = match string_field(request, "new_name") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            wrap(api::rename(&path, &new_name))
        }
        "copy_file" => {
            let source = match string_field(request, "source") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            let dest = match string_field(request, "dest") {
                Ok(value) => value,
                Err(error) => return err(error),
            };
            match std::fs::copy(&source, &dest) {
                Ok(_) => wrap(api::stat(&dest)),
                Err(error) => err(format!("复制失败：{error}")),
            }
        }
        "path_size" => match string_field(request, "path") {
            Ok(path) => ok(api::path_size(&path)),
            Err(error) => err(error),
        },
        "dir_size" => match string_field(request, "path") {
            Ok(path) => wrap(api::dir_size(&path).map(|value: Value| value)),
            Err(error) => err(error),
        },
        other => err(format!("未知操作：{other}")),
    }
}

// 保持对 FileEntry 的引用，确保类型在编译期与主程序一致。
#[allow(dead_code)]
fn _assert_entry(_: FileEntry) {}
