//! Per-entry settings, as `Ziperu::OutputStream` passes them to the native
//! writer in a symbol-keyed Hash, and their translation to the crate's
//! `FileOptions`.

use magnus::{Error, RHash, RString, Ruby};
use zip::write::FullFileOptions;
use zip::{AesMode, CompressionMethod, DateTime, System};

use crate::errors::{IntoRuby, ERROR};
use crate::rb::{bytes_of, field};

pub(crate) struct EntryOptions {
    pub method: u16,
    pub level: Option<i64>,
    pub dos_date: u16,
    pub dos_time: u16,
    pub unix_perms: Option<u32>,
    /// The "made by" host system byte (rubyzip's fstype), kept from the
    /// entry rather than defaulting to the platform the writer runs on.
    pub fstype: Option<u8>,
    pub large_file: bool,
    pub comment: Option<String>,
    /// Concatenated local-format extra fields: id, len, data.
    pub extra: Vec<u8>,
    /// The central-directory forms; fields present only here are written
    /// only there (rubyzip keeps unknown fields it was handed that way).
    pub central_extra: Vec<u8>,
    pub password: Option<Vec<u8>>,
    pub aes_mode: Option<u8>,
    /// For `copy_zipcrypto`: the source entry was written in one pass
    /// (bit 3), so a data descriptor follows its data.
    pub descriptor: bool,
    /// Encrypt with ZipCrypto (using `password`) rather than AES.
    pub zipcrypto: bool,
    /// Set general purpose bit 11 (the name and comment are UTF-8). The
    /// crate offers no way to ask for it, so the headers are patched once
    /// the archive is written; a stream cannot be, and drops it.
    pub efs: bool,
}

impl EntryOptions {
    pub(crate) fn from_hash(ruby: &Ruby, h: RHash) -> Result<Self, Error> {
        let text = |key: &str, what: &str| -> Result<Option<String>, Error> {
            field::<RString>(ruby, h, key)?
                .map(|s| utf8_text(ruby, what, s))
                .transpose()
        };
        let bytes = |key: &str| -> Result<Option<Vec<u8>>, Error> {
            Ok(field::<RString>(ruby, h, key)?.map(bytes_of))
        };
        Ok(Self {
            method: field(ruby, h, "method")?.unwrap_or(8),
            level: field(ruby, h, "level")?,
            dos_date: field(ruby, h, "dos_date")?.unwrap_or(0),
            dos_time: field(ruby, h, "dos_time")?.unwrap_or(0),
            unix_perms: field(ruby, h, "unix_perms")?,
            fstype: field(ruby, h, "fstype")?,
            large_file: field(ruby, h, "large_file")?.unwrap_or(false),
            comment: text("comment", "entry comment")?,
            extra: bytes("extra")?.unwrap_or_default(),
            central_extra: bytes("central_extra")?.unwrap_or_default(),
            password: bytes("password")?,
            aes_mode: field(ruby, h, "aes_mode")?,
            zipcrypto: field(ruby, h, "zipcrypto")?.unwrap_or(false),
            descriptor: field(ruby, h, "descriptor")?.unwrap_or(false),
            efs: field(ruby, h, "efs")?.unwrap_or(false),
        })
    }

    /// The modification time the headers carry: the entry's DOS time, or
    /// the crate's default when that pair is not a valid date.
    pub(crate) fn last_modified(&self) -> DateTime {
        DateTime::try_from_msdos(self.dos_date, self.dos_time)
            .unwrap_or_else(|_| DateTime::default_for_write())
    }

    /// The deflate level for data this writer compresses itself.
    pub(crate) fn flate_level(&self) -> flate2::Compression {
        match self.level {
            Some(level @ 0..=9) => flate2::Compression::new(level as u32),
            _ => flate2::Compression::default(),
        }
    }

    /// The crate's compression method for `method`, for the methods the
    /// writer offers.
    fn compression(&self, ruby: &Ruby) -> Result<CompressionMethod, Error> {
        Ok(match self.method {
            0 => CompressionMethod::Stored,
            8 => CompressionMethod::Deflated,
            12 => CompressionMethod::Bzip2,
            93 => CompressionMethod::Zstd,
            other => {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    format!("unsupported compression method for writing: {other}"),
                ))
            }
        })
    }

    fn aes_mode(&self) -> AesMode {
        match self.aes_mode {
            Some(1) => AesMode::Aes128,
            Some(2) => AesMode::Aes192,
            _ => AesMode::Aes256,
        }
    }

    pub(crate) fn to_file_options(
        &self,
        ruby: &Ruby,
    ) -> Result<FullFileOptions<'_, 'static>, Error> {
        // A ZipCrypto entry reaches the crate as Stored ciphertext whose
        // 32-bit header fields are patched later, so no zip64 fields; the
        // real method is this writer's business (see `zipcrypto::Pending`).
        let (method, large_file) = if self.zipcrypto {
            (CompressionMethod::Stored, false)
        } else {
            (self.compression(ruby)?, self.large_file)
        };
        let mut options = FullFileOptions::default()
            .compression_method(method)
            .compression_level(self.level)
            .large_file(large_file)
            .last_modified_time(self.last_modified());
        if let Some(perms) = self.unix_perms {
            options = options.unix_permissions(perms);
        }
        if let Some(fstype) = self.fstype {
            options = options.system(System::from(fstype));
        }
        if let Some(comment) = &self.comment {
            options = options.with_file_comment(comment.as_str());
        }
        if let (Some(password), false) = (&self.password, self.zipcrypto) {
            options = options.with_aes_encryption_bytes(self.aes_mode(), password);
        }
        let mut local_ids = Vec::new();
        for (id, data) in extra_fields(&self.extra) {
            local_ids.push(id);
            options.add_extra_field(id, data, false).rb(ruby)?;
        }
        for (id, data) in extra_fields(&self.central_extra) {
            if !local_ids.contains(&id) {
                options.add_extra_field(id, data, true).rb(ruby)?;
            }
        }
        Ok(options)
    }
}

/// Walks concatenated extra fields (id, length, data) as `(id, data)`.
fn extra_fields(bytes: &[u8]) -> impl Iterator<Item = (u16, &[u8])> {
    let mut i = 0;
    std::iter::from_fn(move || {
        if i + 4 > bytes.len() {
            return None;
        }
        let id = u16::from_le_bytes([bytes[i], bytes[i + 1]]);
        let len = u16::from_le_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        let data = bytes.get(i + 4..i + 4 + len).unwrap_or(&[]);
        i += 4 + len;
        Some((id, data))
    })
}

/// The crate takes directory names, rename targets, symlink targets and
/// entry comments as `str` (file names are raw bytes), so this limit is
/// stated plainly rather than surfacing as a conversion error.
pub(crate) fn utf8_name(ruby: &Ruby, name: RString) -> Result<String, Error> {
    utf8_text(ruby, "entry name", name)
}

pub(crate) fn utf8_text(ruby: &Ruby, what: &str, text: RString) -> Result<String, Error> {
    let bytes = bytes_of(text);
    String::from_utf8(bytes).map_err(|e| {
        Error::new(
            ruby.get_inner(&ERROR),
            format!(
                "{what} {:?} is not valid UTF-8, which the native writer needs here",
                String::from_utf8_lossy(e.as_bytes())
            ),
        )
    })
}
