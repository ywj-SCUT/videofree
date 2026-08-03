use std::{
    net::{TcpStream, ToSocketAddrs},
    process::{Child, Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

const SERVER_HOST: &str = "127.0.0.1";
const SERVER_PORT: u16 = 43127;

struct ServerProcess(Mutex<Option<Child>>);

#[cfg(target_os = "windows")]
fn hide_console(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    command.creation_flags(0x0800_0000);
}

#[cfg(not(target_os = "windows"))]
fn hide_console(_command: &mut Command) {}

fn wait_for_server(child: &mut Child) -> Result<(), String> {
    let address = (SERVER_HOST, SERVER_PORT)
        .to_socket_addrs()
        .map_err(|error| error.to_string())?
        .next()
        .ok_or_else(|| "VideoGET server address is invalid".to_string())?;
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(25) {
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            return Err(format!("VideoGET service exited before startup: {status}"));
        }
        if TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok() {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(150));
    }
    Err("VideoGET service did not become ready within 25 seconds".to_string())
}

pub fn run() {
    let app = tauri::Builder::default()
        .setup(|app| {
            let install_root = std::env::current_exe()?
                .parent()
                .ok_or_else(|| std::io::Error::other("VideoGET install directory is invalid"))?
                .to_path_buf();
            let node = install_root.join("videoget-node.exe");
            let server_root = install_root.join("resources").join("server");
            let server_entry = server_root.join("web").join("server.js");
            if !node.is_file() || !server_entry.is_file() {
                return Err("VideoGET packaged service files are missing".into());
            }

            let mut command = Command::new(node);
            command
                .arg(server_entry)
                .current_dir(&server_root)
                .env("HOSTNAME", SERVER_HOST)
                .env("PORT", SERVER_PORT.to_string())
                .env("NODE_ENV", "production")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            hide_console(&mut command);
            let mut child = command.spawn()?;
            wait_for_server(&mut child).map_err(std::io::Error::other)?;
            app.manage(ServerProcess(Mutex::new(Some(child))));

            let url = format!("http://{SERVER_HOST}:{SERVER_PORT}").parse::<url::Url>()?;
            WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
                .title("VideoGET")
                .inner_size(1420.0, 900.0)
                .min_inner_size(1050.0, 680.0)
                .build()?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build VideoGET Tauri application");

    app.run(|app_handle, event| {
        if matches!(event, tauri::RunEvent::Exit) {
            if let Ok(mut child) = app_handle.state::<ServerProcess>().0.lock() {
                if let Some(mut process) = child.take() {
                    let _ = process.kill();
                    let _ = process.wait();
                }
            }
        }
    });
}
