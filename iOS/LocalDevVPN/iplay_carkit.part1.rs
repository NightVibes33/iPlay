use std::ffi::{c_char, c_void, CStr};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::exploit::{connect_tunnel, ALLogCallback, Logger};
use crate::ffi_util::cstr;

const DETECT: [u8; 6] = [0xff, 0x55, 0x02, 0x00, 0xee, 0x10];
const SYN: u8 = 0x80;
const ACK: u8 = 0x40;
const CONTROL_SESSION: u8 = 10;
const MAX_FRAME: usize = u16::MAX as usize;
const START_IDENTIFICATION: u16 = 0x1d00;
const IDENTIFICATION: u16 = 0x1d01;
const IDENTIFICATION_ACCEPTED: u16 = 0x1d02;
const IDENTIFICATION_REJECTED: u16 = 0x1d03;
const REQUEST_CERTIFICATE: u16 = 0xaa00;
const CERTIFICATE: u16 = 0xaa01;
const REQUEST_SIGNATURE: u16 = 0xaa02;
const SIGNATURE: u16 = 0xaa03;
const AUTH_FAILED: u16 = 0xaa04;
const AUTH_SUCCEEDED: u16 = 0xaa05;
const AVAILABILITY: u16 = 0x4300;
const START_SESSION: u16 = 0x4301;

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" {
    fn iPlayBAAPrepare() -> i32;
    fn iPlayBAACopyIap2Certificate(out: *mut u8, capacity: usize, out_len: *mut usize) -> i32;
    fn iPlayBAASignChallenge(
        challenge: *const u8,
        challenge_len: usize,
        out: *mut u8,
        capacity: usize,
        out_len: *mut usize,
    ) -> i32;
}

#[derive(Clone)]
struct Parameter {
    id: u16,
    value: Vec<u8>,
}

impl Parameter {
    fn raw(id: u16, value: impl Into<Vec<u8>>) -> Self {
        Self {
            id,
            value: value.into(),
        }
    }

    fn string(id: u16, value: &str) -> Result<Self, String> {
        if value.is_empty() || value.as_bytes().contains(&0) {
            return Err(format!("invalid NUL-terminated string for parameter {id}"));
        }
        let mut bytes = value.as_bytes().to_vec();
        bytes.push(0);
        Ok(Self::raw(id, bytes))
    }

    fn u8(id: u16, value: u8) -> Self {
        Self::raw(id, vec![value])
    }

    fn u16(id: u16, value: u16) -> Self {
        Self::raw(id, value.to_be_bytes().to_vec())
    }

    fn u32(id: u16, value: u32) -> Self {
        Self::raw(id, value.to_be_bytes().to_vec())
    }

    fn void(id: u16) -> Self {
        Self::raw(id, Vec::new())
    }

    fn group(id: u16, fields: &[Self]) -> Result<Self, String> {
        Ok(Self::raw(id, encode_parameters(fields)?))
    }

    fn u16_list(id: u16, values: &[u16]) -> Self {
        let mut bytes = Vec::with_capacity(values.len() * 2);
        for value in values {
            bytes.extend_from_slice(&value.to_be_bytes());
        }
        Self::raw(id, bytes)
    }
}

#[derive(Clone)]
struct Message {
    id: u16,
    parameters: Vec<Parameter>,
}

impl Message {
    fn empty(id: u16) -> Self {
        Self {
            id,
            parameters: Vec::new(),
        }
    }

    fn encode(&self) -> Result<Vec<u8>, String> {
        let body = encode_parameters(&self.parameters)?;
        let length = body
            .len()
            .checked_add(6)
            .ok_or_else(|| "CSM length overflow".to_string())?;
        if length > 65_525 {
            return Err("CSM message too large".into());
        }
        let mut out = Vec::with_capacity(length);
        out.extend_from_slice(&[0x40, 0x40]);
        out.extend_from_slice(&(length as u16).to_be_bytes());
        out.extend_from_slice(&self.id.to_be_bytes());
        out.extend_from_slice(&body);
        Ok(out)
    }

    fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() < 6 || bytes[..2] != [0x40, 0x40] {
            return Err("malformed CSM message".into());
        }
        let length = usize::from(u16::from_be_bytes([bytes[2], bytes[3]]));
        if length != bytes.len() {
            return Err("CSM length mismatch".into());
        }
        Ok(Self {
            id: u16::from_be_bytes([bytes[4], bytes[5]]),
            parameters: decode_parameters(&bytes[6..])?,
        })
    }

    fn one(&self, id: u16) -> Result<&[u8], String> {
        let mut found = self.parameters.iter().filter(|p| p.id == id);
        let value = found
            .next()
            .ok_or_else(|| format!("missing parameter {id}"))?;
        if found.next().is_some() {
            return Err(format!("duplicate parameter {id}"));
        }
        Ok(&value.value)
    }
}

fn encode_parameters(parameters: &[Parameter]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for p in parameters {
        let length = p
            .value
            .len()
            .checked_add(4)
            .ok_or_else(|| "parameter length overflow".to_string())?;
        if length > u16::MAX as usize {
            return Err("parameter too large".into());
        }
        out.extend_from_slice(&(length as u16).to_be_bytes());
        out.extend_from_slice(&p.id.to_be_bytes());
        out.extend_from_slice(&p.value);
    }
    Ok(out)
}

fn decode_parameters(mut bytes: &[u8]) -> Result<Vec<Parameter>, String> {
    let mut fields = Vec::new();
    while !bytes.is_empty() {
        if bytes.len() < 4 {
            return Err("truncated parameter".into());
        }
        let length = usize::from(u16::from_be_bytes([bytes[0], bytes[1]]));
        if length < 4 || length > bytes.len() {
            return Err("invalid parameter length".into());
        }
        fields.push(Parameter::raw(
            u16::from_be_bytes([bytes[2], bytes[3]]),
            bytes[4..length].to_vec(),
        ));
        bytes = &bytes[length..];
    }
    Ok(fields)
}

fn checksum(bytes: &[u8]) -> u8 {
    0u8.wrapping_sub(bytes.iter().copied().fold(0u8, u8::wrapping_add))
}

struct Frame {
    flags: u8,
    sequence: u8,
    acknowledgement: u8,
    session: u8,
    payload: Vec<u8>,
}

impl Frame {
    fn encode(&self) -> Result<Vec<u8>, String> {
        let length = 9 + self.payload.len() + usize::from(!self.payload.is_empty());
        if length > MAX_FRAME {
            return Err("iAP2 frame too large".into());
        }
        let mut out = Vec::with_capacity(length);
        out.extend_from_slice(&[0xff, 0x5a]);
        out.extend_from_slice(&(length as u16).to_be_bytes());
        out.extend_from_slice(&[
            self.flags,
            self.sequence,
            self.acknowledgement,
            self.session,
        ]);
        out.push(checksum(&out));
        if !self.payload.is_empty() {
            out.extend_from_slice(&self.payload);
            out.push(checksum(&self.payload));
        }
        Ok(out)
    }

    fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() < 9 || bytes[..2] != [0xff, 0x5a] {
            return Err("malformed iAP2 frame".into());
        }
        let length = usize::from(u16::from_be_bytes([bytes[2], bytes[3]]));
        if length != bytes.len() || checksum(&bytes[..9]) != 0 {
            return Err("invalid iAP2 header".into());
        }
        let payload = if bytes.len() == 9 {
            Vec::new()
        } else {
            if bytes.len() == 10 || checksum(&bytes[9..]) != 0 {
                return Err("invalid iAP2 payload checksum".into());
            }
            bytes[9..bytes.len() - 1].to_vec()
        };
        Ok(Self {
            flags: bytes[4],
            sequence: bytes[5],
            acknowledgement: bytes[6],
            session: bytes[7],
            payload,
        })
    }
}

struct Control {
    stream: Box<dyn idevice::ReadWrite>,
    sent: u8,
    received: u8,
    max_frame: usize,
    csm_bytes: Vec<u8>,
}

impl Control {
    async fn read_frame(&mut self) -> Result<Frame, String> {
        let mut prefix = [0u8; 2];
        tokio::time::timeout(Duration::from_secs(15), self.stream.read_exact(&mut prefix))
            .await
            .map_err(|_| "timed out reading iAP2 frame".to_string())?
            .map_err(|e| format!("read iAP2 prefix: {e}"))?;

        if prefix == DETECT[..2] {
            let mut rest = [0u8; 4];
            self.stream
                .read_exact(&mut rest)
                .await
                .map_err(|e| format!("read iAP2 detect marker: {e}"))?;
            if rest != DETECT[2..] {
                return Err("invalid iAP2 detect marker".into());
            }
            self.stream
                .read_exact(&mut prefix)
                .await
                .map_err(|e| format!("read iAP2 post-detect prefix: {e}"))?;
        }
