use std::ffi::{c_char, c_void, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};

use idevice::remote_pairing::RpPairingFile;
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
                "trusted RSD connected but CarKit service is absent (carkit services: {names})"
            ));
        };

        logger.log(format!("LocalDevVPN: opening {service_name} on RSD port {port}"));
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
            .ok_or_else(|| "CarKit RSD stream did not expose a socket".to_string())?;

        return Ok((adapter, handshake, socket));
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

    let (_adapter, _handshake, mut carkit) = open_carkit(&pairing_bytes, logger).await?;
    logger.log("LocalDevVPN: trusted CarKit service opened");

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
