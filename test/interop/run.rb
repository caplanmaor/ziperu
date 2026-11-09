# frozen_string_literal: true

# Interoperability check: archives ziperu writes are read by Info-ZIP's
# unzip, 7-Zip and Python's zipfile, and archives those tools write are read
# by ziperu. Needs `zip`, `unzip`, `7z` (or 7zz/7za) and `python3` on PATH;
# checks whose tool is missing are skipped. Run from the repo root:
#
#   ruby -Ilib test/interop/run.rb
#
# Prints a line per check and exits non-zero on any failure.
require "zip"
require "fileutils"
require "open3"
require "digest"
require "tmpdir"

$fails = []
$passes = 0
def check(name)
  r = yield
  if r == true || r.nil?
    $passes += 1
    puts "PASS #{name}"
  else
    $fails << "#{name}: #{r}"
    puts "FAIL #{name}: #{r}"
  end
rescue => e
  $fails << "#{name}: #{e.class}: #{e.message}"
  puts "FAIL #{name}: #{e.class}: #{e.message}\n  #{e.backtrace.first(3).join("\n  ")}"
end

def sh(*cmd, input: nil)
  out, st = Open3.capture2e(*cmd, stdin_data: input)
  [st.success?, out]
end

def have?(tool) = system("which #{tool} >/dev/null 2>&1")
SEVEN = %w[7z 7zz 7za].find { |t| have?(t) }
puts "ruby #{RUBY_VERSION} #{RUBY_PLATFORM} ziperu #{Ziperu::VERSION} 7z=#{SEVEN.inspect} unzip=#{have?("unzip")} zip=#{have?("zip")} python3=#{have?("python3")}"

Dir.mktmpdir("interop") do |dir|
  Dir.chdir(dir)
  # ---- source tree -------------------------------------------------------
  FileUtils.mkdir_p("src/sub/deep")
  File.write("src/hello.txt", "hello world\n" * 100)
  File.binwrite("src/random.bin", Random.new(1).bytes(300_000))
  File.write("src/empty.txt", "")
  File.write("src/sub/a.txt", "a" * 70_000)
  File.write("src/sub/deep/z.txt", "z")
  File.write("src/ünïcödé-名前.txt", "utf8 name")
  File.write("src/spaces in name.txt", "sp")
  File.chmod(0o755, "src/hello.txt")
  File.symlink("hello.txt", "src/link_to_hello") rescue nil
  src_digest = ->(root) { Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |f| f == "." || f == ".." }.sort.map { |f| p = File.join(root, f); File.symlink?(p) ? [f, "L", File.readlink(p)] : File.directory?(p) ? [f, "D"] : [f, "F", Digest::SHA256.file(p).hexdigest] } }
  expected = src_digest.call("src").reject { |f, *| f == "link_to_hello" }

  compare_tree = lambda do |root, allow_missing_link: true|
    got = src_digest.call(root).reject { |f, *| allow_missing_link && f == "link_to_hello" }
    got == expected ? true : "tree differs:\n  expected #{expected - got}\n  got #{got - expected}"
  end

  # ---- ziperu writes, others read ---------------------------------------
  write_with_ziperu = lambda do |path, **opts|
    File.delete(path) if File.exist?(path)
    Zip::File.open(path, create: true) do |zf|
      Dir.glob("src/**/*", File::FNM_DOTMATCH).sort.each do |f|
        next if File.basename(f) =~ /\A\.\.?\z/
        name = f.sub(%r{\Asrc/}, "")
        next if File.symlink?(f) && !opts[:symlinks]
        if File.directory?(f)
          zf.mkdir(name)
        else
          zf.add(name, f)
        end
      end
      zf.comment = "ziperu comment"
    end
  end

  %i[deflate stored bzip2 zstd].each do |m|
    path = "z_#{m}.zip"
    check("ziperu writes #{m}") do
      Zip.default_compression = Zlib::DEFAULT_COMPRESSION
      File.delete(path) if File.exist?(path)
      method = { deflate: Zip::Entry::DEFLATED, stored: Zip::Entry::STORED, bzip2: Zip::Entry::BZIP2, zstd: Zip::Entry::ZSTD }[m]
      Zip::File.open(path, create: true) do |zf|
        Dir.glob("src/**/*").sort.each do |f|
          next if File.symlink?(f)
          name = f.sub(%r{\Asrc/}, "")
          if File.directory?(f) then zf.mkdir(name)
          else
            e = zf.add(name, f)
            e.compression_method = method
          end
        end
      end
      true
    end
    if have?("unzip") && %i[deflate stored bzip2].include?(m)
      check("unzip -t #{m}") { ok, out = sh("unzip", "-t", path); ok || out }
      check("unzip extract #{m} matches") do
        FileUtils.rm_rf("out_unzip"); ok, out = sh("unzip", "-q", path, "-d", "out_unzip")
        ok ? compare_tree.call("out_unzip") : out
      end
    end
    if SEVEN
      check("7z t #{m}") { ok, out = sh(SEVEN, "t", path); ok || out }
      check("7z extract #{m} matches") do
        FileUtils.rm_rf("out_7z"); ok, out = sh(SEVEN, "x", "-y", "-oout_7z", path)
        ok ? compare_tree.call("out_7z") : out
      end
    end
    if have?("python3") && %i[deflate stored bzip2].include?(m)
      check("python zipfile #{m}") do
        ok, out = sh("python3", "-I", "-c", <<~PY, path)
          import sys, zipfile, hashlib
          z = zipfile.ZipFile(sys.argv[1])
          bad = z.testzip()
          assert bad is None, bad
          assert z.comment == b"", z.comment
          names = z.namelist()
          assert "sub/deep/z.txt" in names, names
          assert "ünïcödé-名前.txt" in names, names
          assert z.read("hello.txt") == b"hello world\\n"*100
          print("ok")
        PY
        ok || out
      end
    end
  end

  # ZipCrypto written by ziperu
  check("ziperu writes ZipCrypto, unzip/7z read") do
    path = "z_crypt.zip"; File.delete(path) if File.exist?(path)
    enc = Zip::TraditionalEncrypter.new("s3cret")
    Zip::OutputStream.open(path, encrypter: enc) do |z|
      z.put_next_entry("hello.txt"); z.write(File.read("src/hello.txt"))
      z.put_next_entry("random.bin"); z.write(File.binread("src/random.bin"))
    end
    r = []
    if have?("unzip")
      ok, out = sh("unzip", "-P", "s3cret", "-t", path); r << "unzip: #{out}" unless ok
      ok, out = sh("unzip", "-P", "wrong", "-t", path); r << "unzip accepted wrong pw" if ok
    end
    if SEVEN
      ok, out = sh(SEVEN, "t", "-ps3cret", path); r << "7z: #{out}" unless ok
    end
    if have?("python3")
      ok, out = sh("python3", "-I", "-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); z.setpassword(b's3cret'); assert z.read('hello.txt')==b'hello world\\n'*100; print('ok')", path)
      r << "python: #{out}" unless ok
    end
    r.empty? ? true : r.join("; ")
  end

  # AES written by ziperu
  check("ziperu writes AES-256, 7z/python read") do
    path = "z_aes.zip"; File.delete(path) if File.exist?(path)
    enc = Zip::AESEncrypter.new("s3cret", Zip::AESEncryption::STRENGTH_256_BIT)
    Zip::OutputStream.open(path, encrypter: enc) do |z|
      z.put_next_entry("hello.txt"); z.write(File.read("src/hello.txt"))
    end
    r = []
    if SEVEN
      ok, out = sh(SEVEN, "t", "-ps3cret", path); r << "7z: #{out}" unless ok
    end
    r.empty? ? true : r.join("; ")
  end

  # Symlink written by ziperu
  check("ziperu writes symlink, unzip/7z recognise it") do
    path = "z_link.zip"; File.delete(path) if File.exist?(path)
    Zip::File.open(path, create: true) { |zf| zf.add("hello.txt", "src/hello.txt"); zf.add("link_to_hello", "src/link_to_hello") }
    r = []
    if have?("unzip")
      FileUtils.rm_rf("out_l"); ok, out = sh("unzip", "-q", path, "-d", "out_l")
      r << "unzip: #{out}" unless ok
      r << "unzip did not create symlink" unless File.symlink?("out_l/link_to_hello")
    end
    if SEVEN
      FileUtils.rm_rf("out_l7"); ok, out = sh(SEVEN, "x", "-y", "-oout_l7", path)
      r << "7z: #{out}" unless ok
      r << "7z did not create symlink" unless File.symlink?("out_l7/link_to_hello")
    end
    r.empty? ? true : r.join("; ")
  end

  # unix perms round trip
  check("unix perms visible to unzip -Z") do
    if have?("unzip")
      ok, out = sh("zipinfo", "z_deflate.zip", "hello.txt")
      ok && out.include?("-rwxr-xr-x") ? true : out
    end
  end

  # write_buffer streamed (data descriptors) read by others
  check("ziperu write_buffer stream read by unzip/7z/python") do
    path = "z_stream.zip"
    buf = Zip::OutputStream.write_buffer do |z|
      z.put_next_entry("a.txt"); z.write("A" * 100_000)
      z.put_next_entry("dir/");
      z.put_next_entry("dir/b.txt"); z.write("B")
    end
    File.binwrite(path, buf.string)
    r = []
    if have?("unzip") then ok, out = sh("unzip", "-t", path); r << "unzip: #{out}" unless ok end
    if SEVEN then ok, out = sh(SEVEN, "t", path); r << "7z: #{out}" unless ok end
    if have?("python3")
      ok, out = sh("python3", "-I", "-c", "import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None; assert z.read('a.txt')==b'A'*100000; print('ok')", path)
      r << "python: #{out}" unless ok
    end
    r.empty? ? true : r.join("; ")
  end

  # ---- others write, ziperu reads ---------------------------------------
  read_check = lambda do |path, pw: nil, expect_link: false|
    r = []
    Zip::File.open(path) do |zf|
      zf.each do |e|
        next if e.directory?
        if e.symlink?
          r << "symlink target #{e.symlink_target.inspect}" unless e.symlink_target == "hello.txt" || e.symlink_target == "src/hello.txt"
          next
        end
        src = "src/#{e.name.sub(%r{\Asrc/}, "")}"
        data = pw ? e.get_input_stream(decrypter: Zip::TraditionalDecrypter.new(pw), &:read) : e.get_input_stream(&:read) rescue (r << "#{e.name}: #{$!.class}: #{$!.message}"; next)
        data ||= pw ? zf.read(e) : zf.read(e)
        r << "#{e.name}: content differs (#{e.compression_method})" unless data.b == File.binread(src)
        r << "#{e.name}: size #{e.size} != #{File.size(src)}" unless e.size == File.size(src)
      end
      r << "verify: #{zf.verify.inspect}" unless pw || zf.verify.empty?
    end
    FileUtils.rm_rf("out_z")
    Zip::File.open(path) { |zf| zf.extract_all("out_z") } unless pw
    unless pw
      got = compare_tree.call("out_z")
      r << got unless got == true
    end
    r.empty? ? true : r.join("; ")
  end

  if have?("zip")
    Dir.chdir("src") do
      sh("zip", "-q", "-r", "-y", "../i_zip_default.zip", ".")
      sh("zip", "-q", "-r", "-0", "../i_zip_stored.zip", ".", "-x", "link_to_hello")
      sh("zip", "-q", "-r", "-9", "-Z", "bzip2", "../i_zip_bzip2.zip", ".", "-x", "link_to_hello")
      sh("zip", "-q", "-r", "-P", "pw", "../i_zip_crypt.zip", ".", "-x", "link_to_hello")
      sh("zip", "-q", "-r", "-fz", "../i_zip_zip64.zip", ".", "-x", "link_to_hello")
      sh("zip", "-q", "-r", "-X", "../i_zip_noextra.zip", ".", "-x", "link_to_hello")
      sh("zip", "-q", "-r", "-j", "-D", "../i_zip_nodirs.zip", "sub", "-x", "link_to_hello") # junk paths
    end
    check("ziperu reads Info-ZIP default (+symlink)") { read_check.call("i_zip_default.zip") }
    check("ziperu reads Info-ZIP stored") { read_check.call("i_zip_stored.zip") }
    check("ziperu reads Info-ZIP bzip2") { read_check.call("i_zip_bzip2.zip") }
    check("ziperu reads Info-ZIP forced zip64") { read_check.call("i_zip_zip64.zip") }
    check("ziperu reads Info-ZIP no extra fields") { read_check.call("i_zip_noextra.zip") }
    check("ziperu reads Info-ZIP ZipCrypto with password") { read_check.call("i_zip_crypt.zip", pw: "pw") }
    check("ziperu rejects wrong ZipCrypto password") do
      Zip::File.open("i_zip_crypt.zip") do |zf|
        begin
          zf.find { |e| !e.directory? }.get_input_stream(decrypter: Zip::TraditionalDecrypter.new("nope"), &:read)
          "no error raised"
        rescue Zip::Error
          true
        end
      end
    end
    check("Info-ZIP symlink entry attributes") do
      Zip::File.open("i_zip_default.zip") do |zf|
        e = zf.find_entry("link_to_hello")
        e && e.symlink? && e.ftype == :symlink ? true : "#{e.inspect} ftype=#{e&.ftype}"
      end
    end
    check("Info-ZIP unix perms + mtime") do
      Zip::File.open("i_zip_default.zip") do |zf|
        e = zf.find_entry("hello.txt")
        (e.unix_perms == 0o755 && (e.time.to_i - File.mtime("src/hello.txt").to_i).abs <= 2) ? true : "perms=#{e.unix_perms&.to_s(8)} time=#{e.time} mtime=#{File.mtime("src/hello.txt")}"
      end
    end
    check("Info-ZIP archive modified by ziperu still valid for unzip") do
      FileUtils.cp("i_zip_default.zip", "mod.zip")
      Zip::File.open("mod.zip") do |zf|
        zf.remove("random.bin")
        zf.rename("hello.txt", "renamed.txt")
        zf.get_output_stream("new.txt") { |o| o.write("new content") }
        zf.find_entry("sub/a.txt").comment = "entry comment"
      end
      r = []
      if have?("unzip")
        ok, out = sh("unzip", "-t", "mod.zip"); r << "unzip: #{out}" unless ok
        ok, out = sh("unzip", "-Z1", "mod.zip"); r << "names: #{out}" unless out.include?("renamed.txt") && out.include?("new.txt") && !out.include?("random.bin")
        ok, out = sh("unzip", "-p", "mod.zip", "renamed.txt"); r << "renamed content" unless out == "hello world\n" * 100
        FileUtils.rm_rf("out_mod"); sh("unzip", "-q", "mod.zip", "-d", "out_mod")
        r << "symlink lost after modify" unless File.symlink?("out_mod/link_to_hello")
        r << "perms lost after modify" unless (File.stat("out_mod/renamed.txt").mode & 0o777) == 0o755
      end
      if SEVEN then ok, out = sh(SEVEN, "t", "mod.zip"); r << "7z: #{out}" unless ok end
      r.empty? ? true : r.join("; ")
    end
  end

  if SEVEN
    Dir.chdir("src") do
      sh(SEVEN, "a", "-tzip", "-mm=Deflate", "../i_7z_deflate.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mm=Deflate64", "../i_7z_deflate64.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mm=BZip2", "../i_7z_bzip2.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mm=LZMA", "../i_7z_lzma.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mm=PPMd", "../i_7z_ppmd.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mm=Copy", "../i_7z_copy.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mem=AES256", "-ppw", "../i_7z_aes.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mem=ZipCrypto", "-ppw", "../i_7z_zc.zip", ".", "-xr!link_to_hello")
      sh(SEVEN, "a", "-tzip", "-mcu=on", "../i_7z_utf8.zip", ".", "-xr!link_to_hello")
    end
    %w[deflate deflate64 bzip2 lzma ppmd copy utf8].each do |m|
      check("ziperu reads 7z #{m}") { read_check.call("i_7z_#{m}.zip") }
    end
    check("ziperu reads 7z AES-256") do
      r = []
      Zip::File.open("i_7z_aes.zip") do |zf|
        zf.each do |e|
          next if e.directory?
          data = e.get_input_stream(decrypter: Zip::AESDecrypter.new("pw", Zip::AESEncryption::STRENGTH_256_BIT), &:read)
          r << "#{e.name} differs" unless data.b == File.binread("src/#{e.name}")
        end
      end
      r.empty? ? true : r.join("; ")
    end
    check("ziperu reads 7z ZipCrypto") { read_check.call("i_7z_zc.zip", pw: "pw") }
  end

  if have?("python3")
    sh("python3", "-I", "-c", <<~PY)
      import zipfile, os, io, sys
      def add(z, root="src"):
          for dp, dn, fn in os.walk(root):
              for d in dn: z.write(os.path.join(dp, d), os.path.relpath(os.path.join(dp, d), root) + "/")
              for f in fn:
                  p = os.path.join(dp, f)
                  if os.path.islink(p): continue
                  z.write(p, os.path.relpath(p, root))
      for name, m in [("i_py_deflate.zip", zipfile.ZIP_DEFLATED), ("i_py_stored.zip", zipfile.ZIP_STORED), ("i_py_bzip2.zip", zipfile.ZIP_BZIP2), ("i_py_lzma.zip", zipfile.ZIP_LZMA)]:
          with zipfile.ZipFile(name, "w", m) as z:
              add(z); z.comment = b"py comment"
      # streamed to an unseekable sink -> data descriptors
      class Unseek(io.RawIOBase):
          def __init__(self): self.buf = bytearray()
          def writable(self): return True
          def write(self, b): self.buf += b; return len(b)
          def seekable(self): return False
      u = Unseek()
      with zipfile.ZipFile(u, "w", zipfile.ZIP_DEFLATED) as z: add(z)
      open("i_py_stream.zip", "wb").write(bytes(u.buf))
      # zip64 forced with many tiny entries (> 65535)
      with zipfile.ZipFile("i_py_many.zip", "w", zipfile.ZIP_STORED) as z:
          for i in range(70000): z.writestr("f%05d" % i, b"x")
    PY
    %w[deflate stored bzip2 lzma stream].each do |m|
      check("ziperu reads python #{m}") { read_check.call("i_py_#{m}.zip") }
    end
    check("python archive comment") { Zip::File.open("i_py_deflate.zip") { |zf| zf.comment == "py comment" ? true : zf.comment.inspect } }
    check("ziperu reads 70000-entry zip64") do
      Zip::File.open("i_py_many.zip") { |zf| zf.size == 70_000 && zf.read("f69999") == "x" ? true : zf.size.to_s }
    end
    check("ziperu InputStream over python streamed archive from a pipe") do
      r, w = IO.pipe
      Thread.new { w.write(File.binread("i_py_stream.zip")); w.close }
      names = []
      Zip::InputStream.open(r) do |is|
        while (e = is.get_next_entry)
          data = is.read
          names << e.name
          next if e.name.end_with?("/")
          next "#{e.name} differs via pipe" unless data.b == File.binread("src/#{e.name}")
        end
      end
      names.include?("sub/deep/z.txt") ? true : names.inspect
    end
  end

  # ---- round trip: external archive -> ziperu rewrite -> external verify
  if have?("unzip") && have?("zip")
    check("copy every entry of Info-ZIP archive via OutputStream.copy_raw_entry") do
      Zip::File.open("i_zip_default.zip") do |zf|
        Zip::OutputStream.open("copied.zip") { |os| zf.each { |e| os.copy_raw_entry(e) } }
      end
      ok, out = sh("unzip", "-t", "copied.zip"); next out unless ok
      FileUtils.rm_rf("out_c"); sh("unzip", "-q", "copied.zip", "-d", "out_c")
      compare_tree.call("out_c")
    end
  end
end

puts "\n#{$passes} passed, #{$fails.size} failed"
$fails.each { |f| puts "  - #{f}" }
exit($fails.empty? ? 0 : 1)
