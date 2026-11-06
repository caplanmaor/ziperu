"""Python's zipfile as the oracle for fuzz/differential.rb.

    python -I oracle.py write SPEC.json OUT.zip
    python -I oracle.py read  IN.zip   OUT.json

A spec is {"comment": str, "streaming": bool, "zip64": bool,
"entries": [{"name", "data" (base64), "method" ("stored"|"deflated"|"bzip2"),
"comment", "dir", "mtime" ([y,m,d,H,M,S])}], "level": int or null}. A read result is
{"ok": bool, "error": str, "comment": str, "entries": [{"name", "size",
"compress_size", "crc", "method", "dir", "comment", "data" (base64) or
"error"}]}. Each entry is read on its own so one bad entry does not hide
the others.
"""
import base64
import io
import json
import sys
import zipfile

METHODS = {"stored": zipfile.ZIP_STORED, "deflated": zipfile.ZIP_DEFLATED, "bzip2": zipfile.ZIP_BZIP2}
METHOD_NAMES = {v: k for k, v in METHODS.items()}


class Unseekable(io.RawIOBase):
    """A write-only sink: makes zipfile emit data descriptors (bit 3)."""

    def __init__(self):
        self.buf = io.BytesIO()

    def write(self, b):
        return self.buf.write(b)

    def writable(self):
        return True

    def seekable(self):
        return False

    def tell(self):
        raise OSError("not seekable")

    def flush(self):
        pass


def write(spec_path, out_path):
    with open(spec_path, "rb") as f:
        spec = json.load(f)
    sink = Unseekable() if spec.get("streaming") else io.BytesIO()
    with zipfile.ZipFile(sink, "w", compresslevel=spec.get("level")) as zf:
        if spec.get("comment"):
            zf.comment = spec["comment"].encode("utf-8")
        for e in spec["entries"]:
            info = zipfile.ZipInfo(e["name"], date_time=tuple(e.get("mtime") or (2020, 1, 2, 3, 4, 6)))
            info.compress_type = METHODS[e.get("method", "deflated")]
            if e.get("comment"):
                info.comment = e["comment"].encode("utf-8")
            if e.get("dir"):
                info.external_attr = (0o40755 << 16) | 0x10
                zf.writestr(info, b"")
                continue
            info.external_attr = 0o644 << 16
            data = base64.b64decode(e["data"])
            with zf.open(info, "w", force_zip64=bool(spec.get("zip64"))) as w:
                w.write(data)
    data = sink.buf.getvalue() if isinstance(sink, Unseekable) else sink.getvalue()
    with open(out_path, "wb") as f:
        f.write(data)


def read(in_path, out_path):
    result = {"ok": True, "error": None, "comment": "", "entries": []}
    try:
        zf = zipfile.ZipFile(in_path)
    except Exception as exc:  # noqa: BLE001
        result.update(ok=False, error=f"{type(exc).__name__}: {exc}")
    else:
        with zf:
            result["comment"] = zf.comment.decode("utf-8", "surrogateescape")
            for info in zf.infolist():
                entry = {
                    "name": info.filename,
                    "size": info.file_size,
                    "compress_size": info.compress_size,
                    "crc": info.CRC,
                    "method": METHOD_NAMES.get(info.compress_type, str(info.compress_type)),
                    "dir": info.is_dir(),
                    "comment": info.comment.decode("utf-8", "surrogateescape"),
                }
                try:
                    entry["data"] = base64.b64encode(zf.read(info)).decode("ascii")
                except Exception as exc:  # noqa: BLE001
                    entry["error"] = f"{type(exc).__name__}: {exc}"
                result["entries"].append(entry)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=True)


if __name__ == "__main__":
    cmd, src, dst = sys.argv[1:4]
    {"write": write, "read": read}[cmd](src, dst)
