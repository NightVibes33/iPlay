        if prefix != [0xff, 0x5a] {
            return Err(format!("unexpected iAP2 frame prefix {:02x?}", prefix));
        }
        let mut header = [0u8; 9];
        header[..2].copy_from_slice(&prefix);
        self.stream
            .read_exact(&mut header[2..])
            .await
            .map_err(|e| format!("read iAP2 header: {e}"))?;
        let length = usize::from(u16::from_be_bytes([header[2], header[3]]));
        if length < 9 || length > MAX_FRAME || length == 10 {
            return Err(format!("invalid iAP2 frame length {length}"));
        }
        let mut bytes = Vec::with_capacity(length);
        bytes.extend_from_slice(&header);
        bytes.resize(length, 0);
        if length > 9 {
            self.stream
                .read_exact(&mut bytes[9..])
                .await
                .map_err(|e| format!("read iAP2 body: {e}"))?;
        }
        Frame::decode(&bytes)
    }

    async fn write_frame(&mut self, frame: &Frame) -> Result<(), String> {
        let bytes = frame.encode()?;
        if bytes.len() > self.max_frame {
            return Err("iAP2 frame exceeds peer maximum".into());
        }
        self.stream
            .write_all(&bytes)
            .await
            .map_err(|e| format!("write iAP2 frame: {e}"))?;
        self.stream
            .flush()
            .await
            .map_err(|e| format!("flush iAP2 frame: {e}"))?;
        Ok(())
    }

    async fn synchronize(&mut self, logger: &Logger) -> Result<(), String> {
        logger.log("iPlay A→A: opening wired iAP2 link over LocalDevVPN CarKit service");
        let mut sync = vec![1, 4];
        sync.extend_from_slice(&u16::MAX.to_be_bytes());
        sync.extend_from_slice(&0u16.to_be_bytes());
        sync.extend_from_slice(&0u16.to_be_bytes());
        sync.extend_from_slice(&[0, 0, CONTROL_SESSION, 0, 2]);

        self.stream
            .write_all(&DETECT)
            .await
            .map_err(|e| format!("write iAP2 detect: {e}"))?;
        self.write_frame(&Frame {
            flags: SYN,
            sequence: self.sent,
            acknowledgement: 0,
            session: 0,
            payload: sync,
        })
        .await?;

        let mut got_syn = false;
        for _ in 0..12 {
            let frame = self.read_frame().await?;
            if frame.session != 0 {
                return Err("peer sent non-link frame during synchronization".into());
            }
            if frame.flags & SYN != 0 {
                if frame.payload.len() < 13 || frame.payload[0] != 1 {
                    return Err("unsupported peer synchronization payload".into());
                }
                let max_frame = usize::from(u16::from_be_bytes([frame.payload[2], frame.payload[3]]));
                if max_frame < 64 {
                    return Err("peer max frame is too small".into());
                }
                let zero_ack = frame.payload[4..10].iter().all(|b| *b == 0);
                let has_control_v2 = frame.payload[10..]
                    .chunks_exact(3)
                    .any(|s| s == [CONTROL_SESSION, 0, 2]);
                if !zero_ack || !has_control_v2 {
                    return Err("peer did not negotiate wired control-v2 zero-ACK mode".into());
                }
                self.max_frame = max_frame;
                self.received = frame.sequence;
                got_syn = true;
                self.write_frame(&Frame {
                    flags: ACK,
                    sequence: self.sent,
                    acknowledgement: self.received,
                    session: 0,
                    payload: Vec::new(),
                })
                .await?;
            }
            if got_syn && frame.flags & ACK != 0 && frame.acknowledgement == self.sent {
                logger.log(format!("iPlay A→A: iAP2 synchronized maxFrame={}", self.max_frame));
                return Ok(());
            }
        }
        Err("iAP2 synchronization did not complete".into())
    }

    async fn send_message(&mut self, message: Message) -> Result<(), String> {
        let bytes = message.encode()?;
        let chunk_size = self.max_frame.saturating_sub(10).max(1);
        for chunk in bytes.chunks(chunk_size) {
            self.sent = self.sent.wrapping_add(1);
            self.write_frame(&Frame {
                flags: ACK,
                sequence: self.sent,
                acknowledgement: self.received,
                session: CONTROL_SESSION,
                payload: chunk.to_vec(),
            })
            .await?;
        }
        Ok(())
    }

    async fn read_message(&mut self) -> Result<Message, String> {
        loop {
            if self.csm_bytes.len() >= 6 {
                if self.csm_bytes[..2] != [0x40, 0x40] {
                    return Err("invalid CSM prefix".into());
                }
                let length = usize::from(u16::from_be_bytes([
                    self.csm_bytes[2],
                    self.csm_bytes[3],
                ]));
                if length < 6 || length > 65_525 {
                    return Err("invalid CSM length".into());
                }
                if self.csm_bytes.len() >= length {
                    let message = Message::decode(&self.csm_bytes[..length])?;
                    self.csm_bytes.drain(..length);
                    return Ok(message);
                }
            }

            if STOP.load(Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            let frame = self.read_frame().await?;
            if frame.flags & 0x10 != 0 {
                return Err("peer reset the iAP2 link".into());
            }
            if frame.flags & ACK == 0 {
                continue;
            }
            if frame.payload.is_empty() {
                continue;
            }
            if frame.session != CONTROL_SESSION {
                continue;
            }
            if frame.sequence == self.received {
                continue;
            }
            if frame.sequence != self.received.wrapping_add(1) {
                return Err("out-of-order iAP2 control frame".into());
            }
            self.received = frame.sequence;
            if self.csm_bytes.len() + frame.payload.len() > 65_525 {
                return Err("CSM receive buffer overflow".into());
            }
            self.csm_bytes.extend_from_slice(&frame.payload);
        }
    }
}

fn identity_message() -> Result<Message, String> {
    let mut fields = Vec::new();
    for (id, value) in [
        (0, "iPlay"),
        (1, "iPlay1,1"),
        (2, "NightVibes33"),
        (3, "iPlay-A2A-0001"),
        (4, "0.1"),
        (5, "1.0"),
    ] {
        fields.push(Parameter::string(id, value)?);
    }
    let sent: [u16; 14] = [
        0xaa01, 0xaa03, 0x5000, 0x5002, 0x5200, 0x5203, 0xae00, 0xae02, 0x4157,
        0x4159, 0x4154, 0x4156, 0xae03, START_SESSION,
    ];
    let received: [u16; 13] = [
        REQUEST_CERTIFICATE,
        REQUEST_SIGNATURE,
        AUTH_FAILED,
        AUTH_SUCCEEDED,
        0xea00,
        0xea01,
        0x5001,
        0x5201,
        0x5202,
        0xae01,
        0x4158,
        0x4155,
        AVAILABILITY,
    ];
    fields.push(Parameter::u16_list(6, &sent));
    fields.push(Parameter::u16_list(7, &received));
    fields.push(Parameter::u8(8, 2));
    fields.push(Parameter::u16(9, 20));
    fields.push(Parameter::group(
        10,
        &[
            Parameter::u8(0, 1),
            Parameter::string(1, "com.nightvibes33.iplay")?,
            Parameter::u8(2, 0),
        ],
    )?);
    fields.push(Parameter::string(12, "en")?);
    fields.push(Parameter::string(13, "en")?);
    fields.push(Parameter::group(
        16,
        &[
            Parameter::u16(0, 0),
            Parameter::string(1, "iPlay LocalDevVPN")?,
            Parameter::void(2),
            Parameter::u8(3, 0),
            Parameter::void(4),
        ],
    )?);
    Ok(Message {
        id: IDENTIFICATION,
        parameters: fields,
    })
}

fn power_and_subscriptions() -> Result<Vec<Message>, String> {
    Ok(vec![
        Message {
            id: 0xae03,
            parameters: vec![Parameter::u16(0, 2400), Parameter::u8(1, 1)],
        },
        Message {
            id: 0x5000,
            parameters: vec![
                Parameter::group(
                    0,
                    &[1, 4, 6, 12, 26]
                        .iter()
                        .map(|id| Parameter::void(*id))
                        .collect::<Vec<_>>(),
                )?,
                Parameter::group(
                    1,
                    &[0, 1, 7]
                        .iter()
                        .map(|id| Parameter::void(*id))
                        .collect::<Vec<_>>(),
                )?,
            ],
        },
        Message {
            id: 0x5200,
            parameters: vec![Parameter::u16(0, 42), Parameter::void(1), Parameter::void(2)],
        },
        Message {
            id: 0xae00,
            parameters: vec![Parameter::void(4), Parameter::void(5), Parameter::void(6)],
        },
        Message {
            id: 0x4157,
            parameters: vec![Parameter::void(0), Parameter::void(4), Parameter::void(5)],
        },
        Message {
            id: 0x4154,
            parameters: vec![
                Parameter::void(0),
                Parameter::void(1),
                Parameter::void(2),
                Parameter::void(3),
                Parameter::void(4),
                Parameter::void(11),
            ],
        },
