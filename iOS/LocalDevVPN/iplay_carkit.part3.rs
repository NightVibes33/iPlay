    ])
}

fn start_session_message(
    airplay_ip: &str,
    device_identifier: &str,
    public_key: &str,
    source_version: &str,
) -> Result<Message, String> {
    Ok(Message {
        id: START_SESSION,
        parameters: vec![
            Parameter::group(0, &[Parameter::string(0, airplay_ip)?])?,
            Parameter::u32(2, 7000),
            Parameter::string(3, device_identifier)?,
            Parameter::string(4, public_key)?,
            Parameter::string(5, source_version)?,
        ],
    })
}

fn baa_certificate_body() -> Result<Vec<Parameter>, String> {
    unsafe {
        if iPlayBAAPrepare() != 0 {
            return Err("DeviceIdentity BAA certificate is unavailable".into());
        }
        let mut needed = 0usize;
        let mut body = vec![0u8; 65_525];
        if iPlayBAACopyIap2Certificate(body.as_mut_ptr(), body.len(), &mut needed) != 0 || needed == 0 {
            return Err("could not copy BAA iAP2 certificate package".into());
        }
        body.truncate(needed);
        decode_parameters(&body)
    }
}

fn baa_sign(challenge: &[u8]) -> Result<Vec<u8>, String> {
    unsafe {
        let mut needed = 0usize;
        let mut signature = vec![0u8; 1024];
        if iPlayBAASignChallenge(
            challenge.as_ptr(),
            challenge.len(),
            signature.as_mut_ptr(),
            signature.len(),
            &mut needed,
        ) != 0 || needed == 0
        {
            return Err("BAA challenge signing failed".into());
        }
        signature.truncate(needed);
        Ok(signature)
    }
}

async fn run_control(
    stream: Box<dyn idevice::ReadWrite>,
    airplay_ip: &str,
    device_identifier: &str,
    public_key: &str,
    source_version: &str,
    logger: &Logger,
) -> Result<(), String> {
    let mut control = Control {
        stream,
        sent: 31,
        received: 0,
        max_frame: MAX_FRAME,
        csm_bytes: Vec::new(),
    };
    control.synchronize(logger).await?;

    let start_id = control.read_message().await?;
    if start_id.id != START_IDENTIFICATION {
        return Err(format!("expected 0x1d00, got 0x{:04x}", start_id.id));
    }
    logger.log("iPlay A→A: received StartIdentification");
    control.send_message(identity_message()?).await?;
    let accepted = control.read_message().await?;
    if accepted.id == IDENTIFICATION_REJECTED {
        return Err("iAP2 identification rejected".into());
    }
    if accepted.id != IDENTIFICATION_ACCEPTED {
        return Err(format!("expected 0x1d02, got 0x{:04x}", accepted.id));
    }
    logger.log("iPlay A→A: iAP2 identification accepted");

    let mut sent_certificate = false;
    let mut sent_signature = false;
    loop {
        let message = control.read_message().await?;
        match message.id {
            REQUEST_CERTIFICATE if !sent_certificate => {
                logger.log("iPlay A→A: phone requested BAA certificate");
                control
                    .send_message(Message {
                        id: CERTIFICATE,
                        parameters: baa_certificate_body()?,
                    })
                    .await?;
                sent_certificate = true;
            }
            REQUEST_SIGNATURE if sent_certificate && !sent_signature => {
                let challenge = message.one(0)?;
                if challenge.is_empty() || challenge.len() > 128 {
                    return Err(format!("invalid BAA challenge length {}", challenge.len()));
                }
                let signature = baa_sign(challenge)?;
                control
                    .send_message(Message {
                        id: SIGNATURE,
                        parameters: vec![Parameter::raw(0, signature)],
                    })
                    .await?;
                sent_signature = true;
            }
            AUTH_SUCCEEDED if sent_signature => {
                logger.log("iPlay A→A: MFi/BAA authentication accepted");
                break;
            }
            AUTH_FAILED => return Err("phone rejected MFi/BAA authentication".into()),
            other => return Err(format!("unexpected auth message 0x{other:04x}")),
        }
    }

    for message in power_and_subscriptions()? {
        control.send_message(message).await?;
    }
    logger.log("iPlay A→A: power + CarPlay subscriptions sent");

    let start = start_session_message(airplay_ip, device_identifier, public_key, source_version)?;
    let mut start_sent = false;
    loop {
        if STOP.load(Ordering::Relaxed) {
            return Ok(());
        }
        let message = control.read_message().await?;
        match message.id {
            AVAILABILITY => {
                logger.log("iPlay A→A: CarPlayAvailability received; sending local StartSession");
                control.send_message(start.clone()).await?;
                if !start_sent {
                    logger.log(format!(
                        "iPlay A→A: StartSession sent to local AirPlay endpoint [{}]:7000",
                        airplay_ip
                    ));
                }
                start_sent = true;
            }
            IDENTIFICATION_REJECTED | AUTH_FAILED => {
                return Err(format!("CarPlay control rejected 0x{:04x}", message.id));
            }
            _ => {
                if !start_sent {
                    logger.log(format!("iPlay A→A: pre-session message 0x{:04x}", message.id));
                }
            }
        }
    }
}

async fn async_run(
    pairing_path: String,
    airplay_ip: String,
    device_identifier: String,
    public_key: String,
    source_version: String,
    logger: &Logger,
) -> Result<(), String> {
    let pairing_bytes = std::fs::read(&pairing_path)
        .map_err(|e| format!("read pairing file {pairing_path}: {e}"))?;
    logger.log("iPlay A→A: connecting LocalDevVPN / Remote Pairing tunnel");
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;
    logger.log("iPlay A→A: opening com.apple.carkit.service over trusted RSD");
    let stream = tunnel
        .connect_service("com.apple.carkit.service", logger)
        .await?;
    logger.log("iPlay A→A: CarKit service open");
    run_control(
        stream,
        &airplay_ip,
        &device_identifier,
        &public_key,
        &source_version,
        logger,
    )
    .await
}

unsafe fn required_string(ptr: *const c_char, label: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{label} is null"));
    }
    CStr::from_ptr(ptr)
        .to_str()
        .map(|s| s.to_string())
        .map_err(|_| format!("{label} is not UTF-8"))
}

#[no_mangle]
pub unsafe extern "C" fn al_iplay_carkit_run(
    pairing_path: *const c_char,
    airplay_ip: *const c_char,
    device_identifier: *const c_char,
    public_key: *const c_char,
    source_version: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_error.is_null() {
        *out_error = ptr::null_mut();
    }
    STOP.store(false, Ordering::Relaxed);

    let result: Result<(), String> = (|| {
        let pairing_path = required_string(pairing_path, "pairing_path")?;
        let airplay_ip = required_string(airplay_ip, "airplay_ip")?;
        let device_identifier = required_string(device_identifier, "device_identifier")?;
        let public_key = required_string(public_key, "public_key")?;
        let source_version = required_string(source_version, "source_version")?;
        let logger = Logger { cb: log_cb, ctx };
        let nested = crate::ffi_util::run_with_large_stack("al_iplay_carkit_run", move || {
            idevice_ffi::run_sync_local(async_run(
                pairing_path,
                airplay_ip,
                device_identifier,
                public_key,
                source_version,
                &logger,
            ))
        })
        .map_err(|e| format!("A→A worker panic: {e}"))?;
        nested
    })();

    match result {
        Ok(()) => 0,
        Err(error) => {
            if !out_error.is_null() {
                *out_error = cstr(error);
            }
            1
        }
    }
}

#[no_mangle]
pub extern "C" fn al_iplay_carkit_stop() {
    STOP.store(true, Ordering::Relaxed);
}
