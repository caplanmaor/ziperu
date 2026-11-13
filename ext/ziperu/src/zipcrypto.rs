//! ZipCrypto ("traditional" PKWARE) encryption, for writing.
//!
//! The crate decrypts this cipher but keeps its encrypter private, on the
//! grounds that it is broken (it is: a few bytes of known plaintext
//! recover the keys). It is still what Windows Explorer and other tools
//! that lack AES can open, and what rubyzip's `TraditionalEncrypter`
//! produces, so the writer supports it: an encrypted entry is written to
//! the crate as a Stored entry holding the 12-byte header and the
//! encrypted (optionally deflated) data, and `Writer::finish` patches the
//! method, flags, CRC and size afterwards.
//!
//! Reference: APPNOTE.TXT section 6.1, and the crate's own `zipcrypto.rs`.
//!
//! The second half of this file is that writing side: the entry in
//! progress (`Pending`), the header fields to fix afterwards (`Patch`),
//! and `apply_patches`, which fixes them.

use std::io::{self, Write};
use std::num::Wrapping;

use zip::result::{ZipError, ZipResult};
use zip::ZipArchive;

use crate::sink::Sink;
use crate::stream_stats::EntryStats;

/// Size of the random header that precedes the data.
const HEADER_SIZE: usize = 12;

const fn crc_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut j = 0;
        while j < 8 {
            crc = if crc & 1 != 0 {
                0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >> 1
            };
            j += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

static CRC_TABLE: [u32; 256] = crc_table();

/// The three rolling keys; one per entry, seeded from the password.
struct Keys {
    key_0: Wrapping<u32>,
    key_1: Wrapping<u32>,
    key_2: Wrapping<u32>,
}

impl Keys {
    fn new(password: &[u8]) -> Self {
        let mut keys = Self {
            key_0: Wrapping(0x1234_5678),
            key_1: Wrapping(0x2345_6789),
            key_2: Wrapping(0x3456_7890),
        };
        for &byte in password {
            keys.update(byte);
        }
        keys
    }

    fn crc32(crc: Wrapping<u32>, input: u8) -> Wrapping<u32> {
        Wrapping(CRC_TABLE[((crc.0 ^ u32::from(input)) & 0xff) as usize] ^ (crc.0 >> 8))
    }

    fn update(&mut self, input: u8) {
        self.key_0 = Self::crc32(self.key_0, input);
        self.key_1 =
            (self.key_1 + (self.key_0 & Wrapping(0xff))) * Wrapping(0x0808_8405) + Wrapping(1);
        self.key_2 = Self::crc32(self.key_2, (self.key_1 >> 24).0 as u8);
    }

    fn stream_byte(&self) -> u8 {
        let temp = (self.key_2.0 as u16) | 2;
        (temp.wrapping_mul(temp ^ 1) >> 8) as u8
    }

    /// Encrypts `buf` in place, advancing the keys with the plaintext.
    fn encrypt(&mut self, buf: &mut [u8]) {
        for byte in buf {
            let plain = *byte;
            *byte = plain ^ self.stream_byte();
            self.update(plain);
        }
    }

    /// The encrypted 12-byte header that opens an entry: 11 random bytes
    /// and a check byte (`check` is the high byte of the DOS time, which
    /// is what readers compare against when general purpose bit 3 is set).
    fn header(&mut self, check: u8) -> io::Result<[u8; HEADER_SIZE]> {
        let mut header = [0u8; HEADER_SIZE];
        getrandom::fill(&mut header[..HEADER_SIZE - 1]).map_err(|e| {
            io::Error::other(format!("no randomness for the ZipCrypto header: {e}"))
        })?;
        header[HEADER_SIZE - 1] = check;
        self.encrypt(&mut header);
        Ok(header)
    }
}

/// General purpose flag bit 0: the entry is encrypted.
pub(crate) const ENCRYPTED_FLAG: u16 = 1;
/// General purpose flag bit 3: sizes may follow the data, and (what
/// matters here) a ZipCrypto check byte comes from the DOS time.
pub(crate) const DATA_DESCRIPTOR_FLAG: u16 = 8;
/// "PK\x07\x08", the optional signature that opens a data descriptor.
pub(crate) const DATA_DESCRIPTOR_SIGNATURE: u32 = 0x0807_4b50;
/// General purpose flag bit 11: the name and comment are UTF-8.
pub(crate) const LANGUAGE_ENCODING_FLAG: u16 = 1 << 11;

/// The method, CRC and sizes a ZipCrypto entry really has, to be written
/// over what the crate put in its headers.
#[derive(Clone, Copy)]
pub(crate) struct Fields {
    pub method: u16,
    pub crc: u32,
    pub size: u64,
    pub csize: u64,
}

/// What the crate wrote for an entry is not quite right for ZipCrypto,
/// which it cannot write, and `Writer::finish` corrects it in both
/// headers afterwards: such an entry goes to the crate as a Stored entry
/// whose content is the ciphertext (and, when bit 3 is set, the data
/// descriptor), so its method, CRC, sizes and flags describe the real
/// entry only after the patch.
pub(crate) struct Patch {
    pub index: usize,
    /// General purpose flag bits to set.
    pub flags: u16,
    /// `None` for a raw copy, whose headers already hold the right values.
    pub fields: Option<Fields>,
}

/// A ZipCrypto entry in progress: the data is deflated here (if at all),
/// encrypted, and handed to the crate as the content of a Stored entry.
pub(crate) struct Pending {
    index: usize,
    keys: Keys,
    method: u16,
    /// Flag bits to set besides the cipher's own.
    extra_flags: u16,
    deflate: Option<flate2::write::DeflateEncoder<Vec<u8>>>,
    crc: crc32fast::Hasher,
    size: u64,
    /// Encryption header and ciphertext written so far.
    csize: u64,
}

impl Pending {
    /// Starts entry `index`: returns the encrypted header to write first,
    /// and the entry to feed. `check` is the check byte (the high byte of
    /// the DOS time in the header, which is what bit 3 declares).
    pub(crate) fn begin(
        index: usize,
        password: &[u8],
        method: u16,
        level: flate2::Compression,
        check: u8,
        extra_flags: u16,
    ) -> io::Result<([u8; HEADER_SIZE], Self)> {
        let mut keys = Keys::new(password);
        let header = keys.header(check)?;
        let deflate = (method == 8).then(|| flate2::write::DeflateEncoder::new(Vec::new(), level));
        let pending = Self {
            index,
            keys,
            method,
            extra_flags,
            deflate,
            crc: crc32fast::Hasher::new(),
            size: 0,
            csize: HEADER_SIZE as u64,
        };
        Ok((header, pending))
    }

    /// Takes in plaintext and returns the ciphertext to write.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> io::Result<Vec<u8>> {
        self.crc.update(bytes);
        self.size += bytes.len() as u64;
        let mut out = match self.deflate.as_mut() {
            Some(encoder) => {
                encoder.write_all(bytes)?;
                std::mem::take(encoder.get_mut())
            }
            None => bytes.to_vec(),
        };
        self.keys.encrypt(&mut out);
        self.csize += out.len() as u64;
        Ok(out)
    }

    /// Flushes the compressor; returns the last ciphertext, followed by
    /// the data descriptor, and the patch.
    pub(crate) fn seal(mut self) -> io::Result<(Vec<u8>, Patch)> {
        let mut out = match self.deflate.take() {
            Some(encoder) => encoder.finish()?,
            None => Vec::new(),
        };
        self.keys.encrypt(&mut out);
        self.csize += out.len() as u64;
        let crc = self.crc.finalize();
        out.extend_from_slice(&data_descriptor(crc, self.csize, self.size)?);
        let patch = Patch {
            index: self.index,
            // Encrypted, and (bit 3) the check byte is the DOS time's.
            flags: ENCRYPTED_FLAG | DATA_DESCRIPTOR_FLAG | self.extra_flags,
            fields: Some(Fields {
                method: self.method,
                crc,
                size: self.size,
                csize: self.csize,
            }),
        };
        Ok((out, patch))
    }
}

/// The data descriptor that follows an entry whose header has bit 3 set.
/// The check byte of a ZipCrypto entry written in one pass has to come
/// from the DOS time, which is what bit 3 declares, and readers that
/// take the flag at its word (Info-ZIP's overlap check, for one) expect
/// the descriptor after the data. ZipCrypto entries stay below 4 GiB,
/// so the sizes are 32-bit.
pub(crate) fn data_descriptor(crc: u32, csize: u64, size: u64) -> io::Result<[u8; 16]> {
    let (Ok(csize), Ok(size)) = (u32::try_from(csize), u32::try_from(size)) else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "ZipCrypto entries of 4 GiB or more are not supported",
        ));
    };
    let mut out = [0u8; 16];
    out[..4].copy_from_slice(&DATA_DESCRIPTOR_SIGNATURE.to_le_bytes());
    out[4..8].copy_from_slice(&crc.to_le_bytes());
    out[8..12].copy_from_slice(&csize.to_le_bytes());
    out[12..].copy_from_slice(&size.to_le_bytes());
    Ok(out)
}

/// Corrects the headers the crate wrote for ZipCrypto entries (see
/// `Patch`), and the stats to match.
pub(crate) fn apply_patches(
    sink: Sink,
    patches: &[Patch],
    stats: &mut EntryStats,
) -> ZipResult<Sink> {
    // The writer's own view has no central record offsets (it never read
    // them); parse what was just written to get them.
    let reread = ZipArchive::new(sink)?;
    let targets = {
        let meta = reread.metadata();
        patches
            .iter()
            .map(|p| {
                let e = meta.entry(p.index)?;
                Ok((e.header_start(), e.central_header_start()))
            })
            .collect::<ZipResult<Vec<_>>>()?
    };
    let mut sink = reread.into_inner();
    for (patch, (local, central)) in patches.iter().zip(targets) {
        apply(&mut sink, patch, local, central).map_err(ZipError::Io)?;
        if let (Some(f), Some(stat)) = (patch.fields, stats.get_mut(patch.index)) {
            stat.size = f.size;
            stat.csize = f.csize;
            stat.crc = f.crc;
        }
    }
    Ok(sink)
}

/// Applies a header patch to the local header at `local` and the central
/// record at `central`.
fn apply(sink: &mut Sink, patch: &Patch, local: u64, central: u64) -> io::Result<()> {
    sink.set_u16_bit(local + 6, patch.flags)?;
    sink.set_u16_bit(central + 8, patch.flags)?;
    if let Some(f) = patch.fields {
        let size = u32::try_from(f.size).unwrap_or(u32::MAX);
        let csize = u32::try_from(f.csize).unwrap_or(u32::MAX);
        sink.write_at(local + 8, &f.method.to_le_bytes())?;
        sink.write_at(local + 14, &f.crc.to_le_bytes())?;
        sink.write_at(local + 18, &csize.to_le_bytes())?;
        sink.write_at(local + 22, &size.to_le_bytes())?;
        sink.write_at(central + 10, &f.method.to_le_bytes())?;
        sink.write_at(central + 16, &f.crc.to_le_bytes())?;
        sink.write_at(central + 20, &csize.to_le_bytes())?;
        sink.write_at(central + 24, &size.to_le_bytes())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypting_changes_the_bytes_and_decrypting_restores_them() {
        let mut keys = Keys::new(b"test");
        let mut data = [0u8; 4];
        keys.encrypt(&mut data);
        assert_ne!(data, [0u8; 4]);
        let mut keys = Keys::new(b"pw");
        let mut cipher = *b"hello world";
        keys.encrypt(&mut cipher);
        let mut keys = Keys::new(b"pw");
        let mut plain = cipher;
        for byte in plain.iter_mut() {
            let decrypted = *byte ^ keys.stream_byte();
            keys.update(decrypted);
            *byte = decrypted;
        }
        assert_eq!(&plain, b"hello world");
    }

    fn decrypt(keys: &mut Keys, buf: &mut [u8]) {
        for byte in buf {
            let plain = *byte ^ keys.stream_byte();
            keys.update(plain);
            *byte = plain;
        }
    }

    #[test]
    fn property_any_data_and_password_round_trip_in_any_chunks() {
        let mut rng = crate::test_rng::Rng::new(3);
        for case in 0..crate::test_rng::CASES {
            let password = rng.bytes(16);
            let data = rng.bytes(300);
            let check = rng.next() as u8;
            let mut keys = Keys::new(&password);
            let mut header = keys.header(check).expect("randomness");
            let mut cipher = data.clone();
            // Encrypting in pieces is the same as in one go.
            let mut at = 0;
            while at < cipher.len() {
                let end = (at + 1 + rng.below(40)).min(cipher.len());
                keys.encrypt(&mut cipher[at..end]);
                at = end;
            }
            let mut keys = Keys::new(&password);
            decrypt(&mut keys, &mut header);
            assert_eq!(header[HEADER_SIZE - 1], check, "case {case}: check byte");
            decrypt(&mut keys, &mut cipher);
            assert_eq!(cipher, data, "case {case}");
        }
    }
}
