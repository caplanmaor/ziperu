#!/bin/sh
# Rebuilds the tar fixtures in this directory with the tools whose output
# ziperu has to read: GNU tar, bsdtar (libarchive) and Python's tarfile.
# Needs GNU tar, bsdtar, python3, gzip, zstd, xz and bzip2; run it on
# Linux, from anywhere:
#
#   sh test/data/tar/make.sh
#
# The archives are small and checked in, so the tests need none of these.
set -eu
out=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

long=$(printf 'n%.0s' $(seq 1 150))
mkdir -p tree/dir "tree/$long"
printf 'hello\n' > tree/hello.txt
printf 'nested\n' > tree/dir/nested.txt
: > tree/empty
printf 'deep\n' > "tree/$long/$long.txt"
printf 'unicode\n' > 'tree/héllo.txt'
head -c 70000 /dev/zero | tr '\0' 'z' > tree/big.txt
ln -s hello.txt tree/link
ln tree/hello.txt tree/hard
chmod 644 tree/*.txt tree/empty tree/dir/nested.txt
chmod 755 tree tree/dir "tree/$long"
chmod 600 tree/dir/nested.txt

stamp='2024-01-02 03:04:05.123456789 UTC'
common="--sort=name --owner=0 --group=0 --numeric-owner"
# shellcheck disable=SC2086
{
  tar $common --mtime="$stamp" --format=gnu -cf "$out/gnu.tar" tree
  tar $common --mtime="$stamp" --format=pax -cf "$out/pax.tar" tree
  # ustar holds no name over 255 bytes, v7 none over 99 and no links to
  # speak of: the long directory is left out of both.
  tar $common --mtime="$stamp" --format=ustar --exclude="$long" -cf "$out/ustar.tar" tree
  tar $common --mtime="$stamp" --format=v7 --exclude="$long" -cf "$out/v7.tar" tree
}

gzip -9nc "$out/gnu.tar" > "$out/gnu.tar.gz"
zstd -q -19 -c "$out/gnu.tar" > "$out/gnu.tar.zst"
xz -9c "$out/gnu.tar" > "$out/gnu.tar.xz"
bzip2 -9c "$out/gnu.tar" > "$out/gnu.tar.bz2"
# Two gzip members end to end, as `cat a.gz b.gz` makes: one stream.
head -c 4096 "$out/gnu.tar" | gzip -9nc > "$work/a.gz"
tail -c +4097 "$out/gnu.tar" | gzip -9nc > "$work/b.gz"
cat "$work/a.gz" "$work/b.gz" > "$out/gnu-two-members.tar.gz"

bsdtar --format=pax --uid 0 --gid 0 -cf "$out/bsdtar.tar" tree

python3 - "$out/python.tar" <<'EOF'
import sys, tarfile
with tarfile.open(sys.argv[1], "w", format=tarfile.PAX_FORMAT) as tar:
    tar.add("tree", filter=lambda info: info.replace(uid=0, gid=0, uname="", gname="", mtime=1704164645.5, deep=False))
EOF

# A file with a hole, stored sparse: refused, not misread.
truncate -s 1M sparse.bin
printf 'end' >> sparse.bin
tar --sparse --format=gnu -cf "$out/sparse.tar" sparse.bin
tar --sparse --format=pax -cf "$out/sparse-pax.tar" sparse.bin

# A global extended header ahead of the entries, as `git archive` writes.
tar $common --mtime="$stamp" --format=pax --pax-option=comment=fixture,globexthdr.name=global \
  -cf "$out/global-header.tar" tree/hello.txt

ls -l "$out"
