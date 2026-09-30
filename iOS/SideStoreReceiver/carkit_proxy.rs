use std::ffi::{c_char, c_void, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use idevice::pairing_file::PairingFile;
use idevice::remote_pairing::RpPairingFile;
use idevice::services::lockdown::LockdownClient;
use idevice::{Idevice, ReadWrite};
use tokio::io::copy_bidirectional;
use tokio::net::TcpStream;

use crate::ffi_util::{cstr, opt_str};

pub type ALLogCallback = Option<extern "C" fn(ctx: *mut c_void, msg: *const c_char)>;

struct Logger {
    cb: ALLogCallback,
    ctx: *mut c_void,
}
unsafe impl Send for Logger {}
unsafe impl Sync for Logger {}

impl Logger {
    fn log(&self, msg: impl AsRef<str>) {
        let s = msg.as_ref();
        tracing::info!("{s}");
        if let Some(cb) = self.cb {
            if let Ok(c) = CString::new(s) {
                cb(self.ctx, c.as_ptr());
            }
        }
    }
}


const LOCKDOWN_PORT: u16 = 62078;
const IPLAY_HOST_ID: &str = "49504C41-592D-484F-5354-494441413031";
const IPLAY_SYSTEM_BUID: &str = "49504C41-592D-4255-4944-494441413031";

fn lockdown_pairing_path(remote_pairing_path: &str) -> String {
    let path = std::path::Path::new(remote_pairing_path);
    path.with_file_name("iplay_lockdown_pairing.plist")
        .to_string_lossy()
        .into_owned()
}

async fn connect_lockdown(ip: Ipv4Addr) -> Result<LockdownClient, String> {
    let stream = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        TcpStream::connect(SocketAddr::new(IpAddr::V4(ip), LOCKDOWN_PORT)),
    )
    .await
    .map_err(|_| format!("lockdownd {ip}:{LOCKDOWN_PORT} timed out"))?
    .map_err(|e| format!("lockdownd {ip}:{LOCKDOWN_PORT}: {e}"))?;
    Ok(LockdownClient::new(Idevice::new(Box::new(stream), "iPlay")))
}

async fn open_bare_carkit_lockdown(
    remote_pairing_path: &str,
    logger: &Logger,
) -> Result<Box<dyn ReadWrite>, String> {
    let saved_path = lockdown_pairing_path(remote_pairing_path);
    let saved_bytes = tokio::fs::read(&saved_path).await.ok();
    let targets = [
        Ipv4Addr::new(127, 0, 0, 1),
        Ipv4Addr::new(10, 7, 0, 1),
        Ipv4Addr::new(10, 7, 0, 2),
        Ipv4Addr::new(10, 7, 0, 3),
    ];
    let mut last_error = String::new();

    for ip in targets {
        logger.log(format!(
            "LocalDevVPN: trying real Lockdown CarKit on {ip}:{LOCKDOWN_PORT}"
        ));
        let mut lockdown = match connect_lockdown(ip).await {
            Ok(client) => client,
            Err(e) => {
                last_error = e;
                continue;
            }
        };

        let mut pairing = saved_bytes
            .as_deref()
            .and_then(|bytes| PairingFile::from_bytes(bytes).ok());

        if pairing.is_none() {
            logger.log(
                "LocalDevVPN: creating normal Lockdown pairing record; approve the iPhone trust prompt if shown",
            );
            match lockdown
                .pair(IPLAY_HOST_ID, IPLAY_SYSTEM_BUID, Some("iPlay CarPlay Head Unit"))
                .await
            {
                Ok(record) => {
                    match record.clone().serialize() {
                        Ok(bytes) => {
                            if let Some(parent) = std::path::Path::new(&saved_path).parent() {
                                let _ = tokio::fs::create_dir_all(parent).await;
                            }
                            if let Err(e) = tokio::fs::write(&saved_path, &bytes).await {
                                logger.log(format!(
                                    "LocalDevVPN: warning: could not persist Lockdown pairing record: {e}"
                                ));
                            } else {
                                logger.log(format!(
                                    "LocalDevVPN: saved normal Lockdown pairing record to {saved_path}"
                                ));
                            }
                        }
                        Err(e) => logger.log(format!(
                            "LocalDevVPN: warning: pairing record serialization failed: {e:?}"
                        )),
                    }
                    pairing = Some(record);
                }
                Err(e) => {
                    last_error = format!("Lockdown Pair on {ip} failed: {e:?}");
                    logger.log(&last_error);
                    continue;
                }
            }
        }

        let pairing = pairing.expect("pairing record checked above");
        let legacy = match lockdown.start_session(&pairing).await {
            Ok(value) => value,
            Err(e) => {
                last_error = format!("Lockdown StartSession on {ip} failed: {e:?}");
                logger.log(&last_error);
                continue;
            }
        };

        let (port, ssl) = match lockdown.start_service("com.apple.carkit.service").await {
            Ok(value) => value,
            Err(e) => {
                last_error = format!(
                    "Lockdown StartService(com.apple.carkit.service) on {ip} failed: {e:?}"
                );
                logger.log(&last_error);
                continue;
            }
        };

        logger.log(format!(
            "LocalDevVPN: real com.apple.carkit.service started on {ip}:{port} ssl={ssl}"
        ));
        let stream = TcpStream::connect(SocketAddr::new(IpAddr::V4(ip), port))
            .await
            .map_err(|e| format!("connect real CarKit {ip}:{port}: {e}"))?;
        let mut device = Idevice::new(Box::new(stream), "iPlay");
        if ssl {
            device
                .start_session(&pairing, legacy)
                .await
                .map_err(|e| format!("real CarKit service TLS: {e:?}"))?;
        }
        return device
            .get_socket()
            .ok_or_else(|| "real CarKit service did not expose a socket".to_string());
    }

    Err(format!(
        "normal Lockdown CarKit unavailable; last error: {last_error}"
    ))
}

async fn open_carkit(
    pairing_bytes: &[u8],
    logger: &Logger,
) -> Result<(idevice::tcp::handle::AdapterHandle, idevice::services::rsd::RsdHandshake, Box<dyn ReadWrite>), String> {
    let mut pairing = RpPairingFile::from_bytes(pairing_bytes)
        .map_err(|e| format!("Remote Pairing record is invalid: {e:?}"))?;

    let extra_hosts = vec![
        IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(10, 7, 0, 1)),
        IpAddr::V4(Ipv4Addr::new(10, 7, 0, 2)),
        IpAddr::V4(Ipv4Addr::new(10, 7, 0, 3)),
        IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
    ];
    let targets = [
        Ipv4Addr::new(127, 0, 0, 1),
        Ipv4Addr::new(10, 7, 0, 1),
        Ipv4Addr::new(10, 7, 0, 2),
        Ipv4Addr::new(10, 7, 0, 3),
    ];

    let mut last_error = String::new();
    for ip in targets {
        let address = SocketAddr::new(IpAddr::V4(ip), 49152);
        logger.log(format!("LocalDevVPN: trying trusted RSD on {address} via RemoteXPC"));
        let attempt = tokio::time::timeout(
            std::time::Duration::from_secs(6),
            idevice_ffi::tunnel_provider::tunnel_create_remotexpc_multihost_async(
                address,
                "iPlay",
                &mut pairing,
                &extra_hosts,
            ),
        ).await;

        let (mut adapter, mut handshake) = match attempt {
            Ok(Ok(pair)) => pair,
            Ok(Err(failure)) => {
                last_error = format!("RemoteXPC {address}: {:?} ({:?})", failure.error, failure.kind);
                logger.log(&last_error);
                logger.log(format!("LocalDevVPN: trying raw RPPairing on {address}"));
                match tokio::time::timeout(
                    std::time::Duration::from_secs(6),
                    idevice_ffi::tunnel_provider::tunnel_create_rppairing_multihost_async(
                        address,
                        "iPlay",
                        &mut pairing,
                        &extra_hosts,
                    ),
                ).await {
                    Ok(Ok(pair)) => pair,
                    Ok(Err(failure)) => {
                        last_error = format!("RPPairing {address}: {:?} ({:?})", failure.error, failure.kind);
                        logger.log(&last_error);
                        continue;
                    }
                    Err(_) => {
                        last_error = format!("RPPairing {address}: timed out");
                        logger.log(&last_error);
                        continue;
                    }
                }
            }
            Err(_) => {
                last_error = format!("RemoteXPC {address}: timed out");
                logger.log(&last_error);
                continue;
            }
        };

        /*
         * Preferred A->A path: carkitd's CRCarKitIAPRemoteServiceAgent.
         *
         * This is NOT the same service as com.apple.carkit.service. Apple's
         * remote-iAP agent creates an ACCTransport endpoint, marks the wired
         * CarPlay simulator active, and forwards these raw bytes into the
         * normal iAP stack. That is the path capable of producing the real
         * CarPlay pairing/session state that Settings observes.
         *
         * The service is registered through remote_service_listen(), not the
         * Lockdown shim, so do not send an RSD-checkin plist on its data
         * socket; the payload is the iAP byte stream itself.
         */
        const REMOTE_IAP: &str = "com.apple.carkit.remote-iap.service";
        if let Some(service) = handshake.services.get(REMOTE_IAP) {
            logger.log(format!(
                "LocalDevVPN: opening preferred {REMOTE_IAP} on RSD port {} (entitlement={})",
                service.port, service.entitlement
            ));
            match adapter.connect(service.port).await {
                Ok(stream) => {
                    logger.log("LocalDevVPN: remote-iAP transport connected; handing raw stream to wired iAP2");
                    return Ok((adapter, handshake, Box::new(stream)));
                }
                Err(error) => {
                    logger.log(format!(
                        "LocalDevVPN: remote-iAP connection failed ({error:?}); trying legacy CarKit shim"
                    ));
                }
            }
        } else {
            logger.log("LocalDevVPN: remote-iAP service not advertised; trying legacy CarKit shim");
        }

        /*
         * Compatibility fallback retained for older builds where the
         * dedicated remote-iAP listener is absent. This is a Lockdown shim,
         * so it requires the normal RSD check-in before exposing its socket.
         */
        const SHIM: &str = "com.apple.carkit.service.shim.remote";
        const BARE: &str = "com.apple.carkit.service";
        let (service_name, port) = if let Some(service) = handshake.services.get(SHIM) {
            (SHIM, service.port)
        } else if let Some(service) = handshake.services.get(BARE) {
            (BARE, service.port)
        } else {
            let names = handshake.services.keys()
                .filter(|name| name.contains("carkit"))
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");
            return Err(format!(
                "trusted RSD connected but no usable CarKit service is present (carkit services: {names})"
            ));
        };

        logger.log(format!("LocalDevVPN: compatibility opening {service_name} on RSD port {port}"));
        let stream = adapter
            .connect(port)
            .await
            .map_err(|e| format!("connect {service_name}: {e:?}"))?;
        let mut device = Idevice::new(Box::new(stream), "iPlay");
        device.rsd_checkin()
            .await
            .map_err(|e| format!("RSD checkin for {service_name}: {e:?}"))?;
        let socket = device
            .get_socket()
            .ok_or_else(|| "CarKit RSD shim did not expose a socket".to_string())?;

        Ok((adapter, handshake, socket))
    }

    Err(format!(
        "Could not reach this iPhone through LocalDevVPN/RSD. Last error: {last_error}"
    ))
}

async fn run_proxy_async(
    pairing_path: String,
    local_port: u16,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = tokio::fs::read(&pairing_path)
        .await
        .map_err(|e| format!("read pairing file {pairing_path}: {e}"))?;
    if pairing_bytes.is_empty() {
        return Err("pairing file is empty".into());
    }

    /*
     * Prefer a normal Lockdown service. carkitd treats this as a real wired
     * accessory connection, so its standard vehicle/pairing store can run.
     * If LocalDevVPN does not expose lockdownd on this build, retain the proven
     * Remote-Pairing/RSD shim as the A->A simulator fallback.
     */
    let mut carkit = match open_bare_carkit_lockdown(&pairing_path, logger).await {
        Ok(socket) => {
            logger.log("LocalDevVPN: using real Lockdown com.apple.carkit.service");
            socket
        }
        Err(lockdown_error) => {
            logger.log(format!(
                "LocalDevVPN: real Lockdown CarKit unavailable ({lockdown_error}); falling back to trusted RSD shim"
            ));
            let (_adapter, _handshake, socket) = open_carkit(&pairing_bytes, logger).await?;
            logger.log("LocalDevVPN: trusted CarKit simulator shim opened");
            socket
        }
    };

    let mut local = TcpStream::connect(("127.0.0.1", local_port))
        .await
        .map_err(|e| format!("connect iPlay local iAP2 endpoint on {local_port}: {e}"))?;
    logger.log(format!("LocalDevVPN: proxy attached to iPlay local port {local_port}"));

    let (up, down) = copy_bidirectional(&mut local, &mut carkit)
        .await
        .map_err(|e| format!("CarKit proxy I/O: {e}"))?;
    logger.log(format!("LocalDevVPN: CarKit proxy ended tx={up} rx={down}"));
    Ok(())
}

pub unsafe fn run_proxy(
    pairing_path: *const c_char,
    local_port: u16,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    if local_port == 0 {
        if !out_error.is_null() {
            *out_error = cstr("local_port must be nonzero");
        }
        return 1;
    }
    let pairing_path = opt_str(pairing_path, "aircard_pairing.plist");
    let ctx_usize = ctx as usize;
    let result = crate::ffi_util::run_with_large_stack("al_carkit_proxy_run", move || {
        let logger = Logger { cb: log_cb, ctx: ctx_usize as *mut c_void };
        idevice_ffi::run_sync_local(run_proxy_async(pairing_path, local_port, &logger))
    });

    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {
            if !out_error.is_null() {
                *out_error = cstr(error);
            }
            1
        }
        Err(panic_msg) => {
            if !out_error.is_null() {
                *out_error = cstr(panic_msg);
            }
            1
        }
    }
}
