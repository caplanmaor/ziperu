"""Python's tarfile as the oracle for fuzz/tar_differential.rb.

    python -I tar_oracle.py write   SPEC.json OUT.tar
    python -I tar_oracle.py extract IN.tar DEST OUT.json
    python -I tar_oracle.py read    IN.tar OUT.json

A spec is {"format": "gnu"|"pax"|"ustar", "compression": ""|"gz"|"bz2"|"xz",
"entries": [{"name", "type" ("file"|"dir"|"symlink"|"hardlink"|"fifo"|"chr"),
"data" (base64), "link", "mode", "mtime", "uid", "gid", "uname", "gname"}]}.

`extract` takes each member in turn through the "data" filter, the one
Python recommends for archives that are not trusted, and reports
{"filter": bool, "refused": [names]}: a member the filter refuses, or
that cannot be made, is left out and the rest go on.

`read` lists what an archive holds, as [{"name", "type", "size", "mode",
"mtime", "link", "uid", "gid", "uname", "gname", "sha256"}].
"""
import base64
import hashlib
import io
import json
import sys
import tarfile

FORMATS = {"gnu": tarfile.GNU_FORMAT, "pax": tarfile.PAX_FORMAT, "ustar": tarfile.USTAR_FORMAT}
TYPES = {
    "file": tarfile.REGTYPE,
    "dir": tarfile.DIRTYPE,
    "symlink": tarfile.SYMTYPE,
    "hardlink": tarfile.LNKTYPE,
    "fifo": tarfile.FIFOTYPE,
    "chr": tarfile.CHRTYPE,
}


def write(spec_path, out_path):
    with open(spec_path, encoding="utf-8") as f:
        spec = json.load(f)
    mode = "w:" + spec["compression"] if spec["compression"] else "w"
    with tarfile.open(out_path, mode, format=FORMATS[spec["format"]]) as tar:
        for e in spec["entries"]:
            info = tarfile.TarInfo(e["name"])
            info.type = TYPES[e["type"]]
            data = base64.b64decode(e.get("data", ""))
            info.size = len(data) if e["type"] == "file" else 0
            info.linkname = e.get("link", "")
            info.mode = e["mode"]
            info.mtime = e["mtime"]
            info.uid = e["uid"]
            info.gid = e["gid"]
            info.uname = e["uname"]
            info.gname = e["gname"]
            tar.addfile(info, io.BytesIO(data) if e["type"] == "file" else None)


def extract(in_path, dest, out_path):
    has_filter = hasattr(tarfile, "data_filter")
    refused = []
    with tarfile.open(in_path) as tar:
        for member in tar:
            try:
                if has_filter:
                    tar.extract(member, dest, filter="data")
                else:
                    tar.extract(member, dest)
            except Exception as error:  # the filter's refusal, or a link that cannot be made
                refused.append([member.name, type(error).__name__])
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"filter": has_filter, "refused": refused}, f)


def read(in_path, out_path):
    names = {v: k for k, v in TYPES.items()}
    names[tarfile.AREGTYPE] = "file"
    entries = []
    with tarfile.open(in_path) as tar:
        for member in tar:
            data = tar.extractfile(member).read() if member.isreg() else b""
            entries.append({
                "name": member.name,
                "type": names.get(member.type, "other"),
                "size": member.size,
                "mode": member.mode,
                "mtime": member.mtime,
                "link": member.linkname,
                "uid": member.uid,
                "gid": member.gid,
                "uname": member.uname,
                "gname": member.gname,
                "sha256": hashlib.sha256(data).hexdigest(),
            })
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(entries, f)


if __name__ == "__main__":
    if sys.argv[1] == "read":
        read(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "write":
        write(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "extract":
        extract(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit("usage: tar_oracle.py write|extract|read ...")
