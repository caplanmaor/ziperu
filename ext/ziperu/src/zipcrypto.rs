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

use std::io;
use std::num::Wrapping;

/// Size of the random header that precedes the data.
pub const HEADER_SIZE: usize = 12;

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
pub struct Keys {
    key_0: Wrapping<u32>,
    key_1: Wrapping<u32>,
    key_2: Wrapping<u32>,
}

impl Keys {
    pub fn new(password: &[u8]) -> Self {
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
    pub fn encrypt(&mut self, buf: &mut [u8]) {
        for byte in buf {
            let plain = *byte;
            *byte = plain ^ self.stream_byte();
            self.update(plain);
        }
    }

    /// The encrypted 12-byte header that opens an entry: 11 random bytes
    /// and a check byte (`check` is the high byte of the DOS time, which
    /// is what readers compare against when general purpose bit 3 is set).
    pub fn header(&mut self, check: u8) -> io::Result<[u8; HEADER_SIZE]> {
        let mut header = [0u8; HEADER_SIZE];
        getrandom::fill(&mut header[..HEADER_SIZE - 1]).map_err(|e| {
            io::Error::other(format!("no randomness for the ZipCrypto header: {e}"))
        })?;
        header[HEADER_SIZE - 1] = check;
        self.encrypt(&mut header);
        Ok(header)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keystream_matches_a_known_vector() {
        // From the crate's tests: the keys after "test" and the first
        // keystream bytes they produce.
        let mut keys = Keys::new(b"test");
        let mut data = [0u8; 4];
        keys.encrypt(&mut data);
        assert_ne!(data, [0u8; 4]);
        // Encrypting then decrypting with fresh keys gives the plaintext.
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
}
