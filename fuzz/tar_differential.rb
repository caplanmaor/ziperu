# frozen_string_literal: true

# Differential fuzzing of ziperu's tar reader and extractor against
# Python's tarfile:
#
#   ruby fuzz/tar_differential.rb [--seed N] [--iterations N] [--time SECONDS]
#
# Every iteration draws a random archive spec, has Python write it (GNU,
# PAX or ustar; plain, gzip, bzip2 or xz) and runs one of four cases:
#
#   read     ziperu reads the archive (from a path, a File or a StringIO,
#            in pieces of any size) and must give back the spec exactly
#   extract  an archive with hostile entries among the ordinary ones
#            (names that climb out, links that point out, devices) is
#            extracted by ziperu and by Python's "data" filter; the files
#            and directories that result must be the same, and nothing of
#            ziperu's may be outside the destination or lead there
#   write    ziperu writes the spec's entries itself, at some compression
#            and level; Python and ziperu's own reader must both read
#            back what was asked for
#   mutate   an archive's bytes are corrupted; ziperu must read and
#            extract it or fail with one of its own error classes, and
#            still nothing may land outside the destination
#
# A failing case is saved under tmp/fuzz/failures/ with its spec, and the
# run exits non-zero. Reproduce one with the printed --seed.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ziperu"
require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "stringio"
require "tmpdir"

module TarFuzz
  ROOT = File.expand_path("..", __dir__)
  OUT = File.join(ROOT, "tmp", "fuzz")
  WINDOWS = Ziperu::RUNNING_ON_WINDOWS

  # Errors ziperu is allowed to raise on hostile input. Anything else (a
  # NoMethodError, a TypeError, a RangeError) is a bug.
  ACCEPTABLE = [Ziperu::Error, IOError, SystemCallError].freeze

  TYPES = { "file" => :file, "dir" => :directory, "symlink" => :symlink, "hardlink" => :hardlink,
            "fifo" => :fifo, "chr" => :character_device }.freeze

  class Failure < StandardError; end

  # Draws archive specs.
  class Generator
    WORDS = %w[a b report data src lib main index notes img x y z].freeze
    ODD = ["with space", "ünï", "名前", "tab-le", "dot.ted", "UPPER", "q" * 40].freeze

    def initialize(rng)
      @rng = rng
    end

    def chance(p) = @rng.rand < p
    def pick(list) = list[@rng.rand(list.size)]

    def spec(hostile: false)
      format = pick(%w[gnu pax ustar])
      @plain = format == "ustar"
      @serial = 0
      dirs = [""]
      @rng.rand(0..5).times { dirs << "#{pick(dirs)}#{component}/" }
      entries = []
      dirs.drop(1).each { |dir| entries << entry(dir.chomp("/"), "dir", format) if chance(0.8) }
      files = []
      @rng.rand(0..12).times do
        name = "#{pick(dirs)}#{component}"
        files << name
        entries << entry(name, "file", format).merge("data" => Base64.strict_encode64(data))
      end
      links(entries, dirs, files, format, forward: !hostile)
      # A name given twice: the later one is what a reader ends with.
      twice = files.select { chance(0.1) }
      twice.each { |name| entries << entry(name, "file", format).merge("data" => Base64.strict_encode64(data)) }
      entries.concat(hostile_entries(files, format)) if hostile
      # Python extracts in archive order and so has no file yet for a hard
      # link that comes before its target: only the read case has those.
      entries.shuffle!(random: @rng) if chance(0.3) && twice.empty? && !hostile
      { "format" => format, "compression" => pick(["", "", "gz", "bz2", "xz"]), "entries" => entries,
        "twice" => twice }
    end

    private

    # A name no other entry of the spec has, in any case (Windows).
    def component
      @serial += 1
      word = @plain || chance(0.7) ? pick(WORDS) : pick(ODD)
      # (Ruby on Windows cannot remove a path over 260 characters.)
      word = "#{word}#{"n" * @rng.rand(60..200)}" if !@plain && !WINDOWS && chance(0.05)
      "#{word}#{@serial}"
    end

    def data
      case @rng.rand(10)
      when 0 then ""
      when 1 then @rng.bytes(512 * @rng.rand(1..4))
      when 2 then "line of text\n" * @rng.rand(1..20_000)
      else @rng.bytes(@rng.rand(1..3000))
      end
    end

    def entry(name, type, format)
      big = format != "ustar" && chance(0.05)
      mtime = @rng.rand(0..2_000_000_000)
      mtime += @rng.rand(1000) / 1000.0 if format == "pax" && chance(0.5)
      mtime = 2**36 if big && !WINDOWS
      { "name" => name, "type" => type, "link" => "",
        "mode" => pick([0o644, 0o755, 0o600, 0o444, 0o4755, 0o2750, 0o1777, 0o700]),
        "mtime" => mtime, "uid" => big ? 3_000_000_000 : @rng.rand(0..70_000), "gid" => @rng.rand(0..70_000),
        "uname" => format == "pax" && chance(0.2) ? "üser" : pick(["root", "deploy", ""]),
        "gname" => pick(["staff", "wheel", ""]) }
    end

    # Links that stay inside: a symlink to a sibling, a hard link to a
    # file of the archive (before or after it).
    def links(entries, dirs, files, format, forward:)
      @rng.rand(0..3).times do
        dir = pick(dirs)
        entries << entry("#{dir}#{component}", "symlink", format).merge("link" => pick(WORDS))
      end
      return if files.empty?

      @rng.rand(0..3).times do
        link = entry("#{pick(dirs)}#{component}", "hardlink", format).merge("link" => pick(files))
        forward && chance(0.2) ? entries.unshift(link) : entries.push(link)
      end
    end

    def hostile_entries(files, format)
      made = []
      @rng.rand(1..6).times do
        n = (@serial += 1)
        made << case @rng.rand(9)
                when 0 then entry("../evil#{n}", "file", format).merge("data" => Base64.strict_encode64("evil"))
                when 1 then entry("up#{n}/../../evil#{n}", "file", format).merge("data" => Base64.strict_encode64("evil"))
                when 2 then entry("/abs#{n}", "file", format).merge("data" => Base64.strict_encode64("absolute"))
                when 3 then entry("climb#{n}", "symlink", format).merge("link" => "../..")
                when 4 then entry("etc#{n}", "symlink", format).merge("link" => "/etc")
                when 5 then entry("steal#{n}", "hardlink", format).merge("link" => "../secret")
                when 6 then entry("gone#{n}", "hardlink", format).merge("link" => "no-such-file")
                when 7 then entry("pipe#{n}", "fifo", format)
                else entry("dev#{n}", "chr", format)
                end
      end
      if files.any? && chance(0.3)
        made << entry("../outlink#{@serial += 1}", "hardlink", format).merge("link" => files.first)
      end
      made
    end
  end

  # Runs cases and keeps count.
  class Runner
    CASES = %i[read extract write mutate].freeze
    # What the write case picks from: Python reads these everywhere.
    LEVELS = { none: [nil], gzip: [nil, 1, 9], bzip2: [nil, 1, 9], xz: [nil, 0, 6] }.freeze
    attr_reader :stats

    def initialize(seed:, python:, dir:)
      @seed = seed
      @rng = Random.new(seed)
      @gen = Generator.new(@rng)
      @dir = dir
      @python = [*python, "-I", File.join(ROOT, "fuzz", "tar_oracle.py")]
      @stats = Hash.new(0)
      @failures = []
      @corpus = []
    end

    def run_one(iteration, only: nil)
      kind = only || (iteration < 4 ? CASES[iteration] : CASES.sample(random: @rng))
      kind = :read if kind == :mutate && @corpus.empty?
      @current = { "case" => kind.to_s }
      send("case_#{kind}")
      @stats[kind] += 1
    rescue StandardError => e
      record_failure(iteration, kind, e)
    end

    def failures?
      !@failures.empty?
    end

    private

    def fail!(message)
      raise Failure, message
    end

    def python(*args)
      out, status = Open3.capture2e(*@python, *args)
      fail!("the oracle failed: #{out}") unless status.success?
    end

    # The archive Python writes for `spec`, at a path.
    def written(spec)
      spec_path = File.join(@dir, "spec.json")
      path = File.join(@dir, "in.tar")
      File.write(spec_path, JSON.generate(spec))
      python("write", spec_path, path)
      @current["spec"] = spec
      path
    end

    def fresh(name)
      path = File.join(@dir, name)
      FileUtils.chmod_R(0o755, path, force: true) if File.exist?(path)
      FileUtils.rm_rf(path)
      path
    end

    # ---- read ----------------------------------------------------------

    def case_read
      spec = @gen.spec
      path = written(spec)
      bytes = File.binread(path)
      remember(bytes)
      seen = read_all(path, bytes)
      expected = spec["entries"]
      fail!("#{seen.size} entries read, #{expected.size} written") unless seen.size == expected.size

      expected.zip(seen).each { |want, got| compare_entry(want, got, spec["format"]) }
    end

    # Every entry as [entry, data or nil when it was skipped], read from
    # one of the sources ziperu takes, in pieces of one of several sizes.
    def read_all(path, bytes)
      case @rng.rand(3)
      when 0 then read_each(path)
      when 1 then read_each(StringIO.new(bytes))
      else File.open(path, "rb") { |file| read_each(file) }
      end
    end

    def read_each(source)
      seen = []
      Ziperu::Tar.foreach(source) do |entry|
        data = case @rng.rand(4)
               when 0 then nil
               when 1 then entry.read
               when 2 then entry.each_chunk(@rng.rand(1..5000)).to_a.join
               else [entry.read(@rng.rand(1..600)), entry.read].compact.join
               end
        seen << [entry, data]
      end
      seen
    end

    def compare_entry(want, (got, data), format)
      name = want["name"] + (want["type"] == "dir" ? "/" : "")
      same = lambda do |what, expected, actual|
        fail!("#{name}: #{what} is #{actual.inspect}, not #{expected.inspect}") unless expected == actual
      end
      same.call("name", name, got.name)
      same.call("type", TYPES.fetch(want["type"]), got.type)
      same.call("mode", want["mode"], got.mode)
      same.call("uid", want["uid"], got.uid)
      same.call("gid", want["gid"], got.gid)
      same.call("uname", want["uname"], got.uname)
      same.call("gname", want["gname"], got.gname)
      same.call("link", want["link"].empty? ? nil : want["link"], got.link_target)
      mtime = format == "pax" ? want["mtime"] : want["mtime"].to_i
      fail!("#{name}: mtime is #{got.mtime.to_f}, not #{mtime}") unless (got.mtime.to_r - mtime.to_r).abs < 1e-6
      content = Base64.decode64(want.fetch("data", ""))
      same.call("size", content.bytesize, got.size)
      same.call("data", Digest::SHA256.hexdigest(content), Digest::SHA256.hexdigest(data)) if data
    end

    # ---- write ---------------------------------------------------------

    def case_write
      spec = @gen.spec
      @current["spec"] = spec
      compression = LEVELS.keys.sample(random: @rng)
      level = LEVELS[compression].sample(random: @rng)
      @current["compression"] = [compression, level]
      path = File.join(@dir, "ours.tar")
      target = @rng.rand < 0.5 ? path : File.open(path, "wb")
      begin
        Ziperu::Tar.create(target, compression: compression, level: level) { |tar| write_entries(tar, spec) }
      ensure
        target.close if target.respond_to?(:close)
      end
      remember(File.binread(path))

      report = File.join(@dir, "read.json")
      python("read", path, report)
      theirs = JSON.parse(File.read(report))
      ours = []
      Ziperu::Tar.foreach(path) do |entry|
        ours << { "name" => entry.name.chomp("/"), "type" => TYPES.key(entry.type), "size" => entry.size,
                  "mode" => entry.mode, "mtime" => entry.mtime.to_i, "link" => entry.link_target.to_s,
                  "uid" => entry.uid, "gid" => entry.gid, "uname" => entry.uname, "gname" => entry.gname,
                  "sha256" => Digest::SHA256.hexdigest(entry.read) }
      end
      expected = spec["entries"].map { |want| asked_for(want) }
      compare_lists("python", expected, theirs)
      compare_lists("ziperu", expected, ours)
    end

    def write_entries(tar, spec)
      spec["entries"].each do |e|
        mtime = Time.at(e["mtime"])
        data = Base64.decode64(e.fetch("data", ""))
        case e["type"]
        when "dir" then tar.mkdir(e["name"], mode: e["mode"], mtime: mtime)
        when "symlink" then tar.symlink(e["name"], e["link"], mtime: mtime)
        when "hardlink" then tar.link(e["name"], e["link"], mode: e["mode"], mtime: mtime)
        else write_file(tar, e, data, mtime)
        end
      end
    end

    # A file's data, by one of the ways a writer takes it.
    def write_file(tar, entry, data, mtime)
      case @rng.rand(3)
      when 0 then tar.add_data(entry["name"], data, mode: entry["mode"], mtime: mtime)
      when 1 then tar.add(entry["name"], StringIO.new(data), mode: entry["mode"], mtime: mtime)
      else
        source = File.join(@dir, "source.bin")
        File.binwrite(source, data)
        tar.add(entry["name"], source, mode: entry["mode"], mtime: mtime)
      end
    end

    # What an entry of the spec should read back as: ziperu records no
    # owner, whole seconds, and 0777 for a link.
    def asked_for(want)
      data = Base64.decode64(want.fetch("data", ""))
      { "name" => want["name"], "type" => want["type"], "size" => data.bytesize,
        "mode" => want["type"] == "symlink" ? 0o777 : want["mode"], "mtime" => want["mtime"].floor,
        "link" => want["link"], "uid" => 0, "gid" => 0, "uname" => "", "gname" => "",
        "sha256" => Digest::SHA256.hexdigest(data) }
    end

    def compare_lists(reader, expected, got)
      fail!("#{reader} read #{got.size} entries, #{expected.size} were written") unless got.size == expected.size

      expected.zip(got).each do |want, have|
        want.each do |key, value|
          next if have[key] == value

          fail!("#{reader} has #{key} of #{want["name"]} as #{have[key].inspect}, not #{value.inspect}")
        end
      end
    end

    # ---- extract -------------------------------------------------------

    def case_extract
      spec = @gen.spec(hostile: true)
      path = written(spec)
      remember(File.binread(path))

      room = fresh("ours")
      dest = File.join(room, "dest")
      FileUtils.mkdir_p(room)
      File.write(File.join(room, "secret"), "secret")
      quietly { Ziperu::Tar.extract_all(path, dest, symlinks: :create) }
      check_contained(room, dest)

      theirs = File.join(fresh("theirs"), "dest")
      report = File.join(@dir, "extract.json")
      python("extract", path, theirs, report)
      @current["python"] = JSON.parse(File.read(report))
      return unless @current["python"]["filter"]

      # A hard link shares its file's time, and the two set it at
      # different moments: the time is compared where there is one name.
      shared = spec["entries"].select { |e| e["type"] == "hardlink" }.flat_map { |e| [e["name"], e["link"]] }
      ours = files_of(dest, shared)
      expected = files_of(theirs, shared)
      fail!("only ziperu has #{(ours.keys - expected.keys).inspect}") unless (ours.keys - expected.keys).empty?
      fail!("only python has #{(expected.keys - ours.keys).inspect}") unless (expected.keys - ours.keys).empty?
      expected.each do |name, theirs_is|
        fail!("#{name} is #{ours[name].inspect}, python has #{theirs_is.inspect}") unless ours[name] == theirs_is
      end
    end

    # The directories and regular files under `root`: a file by its
    # contents and time. Links are left out: which ones may be made is
    # where the two differ by design.
    def files_of(root, shared)
      return {} unless File.directory?(root)

      found = {}
      Dir.glob("**/*", File::FNM_DOTMATCH, base: root).each do |name|
        next if name.end_with?("/.") || name == "."

        path = File.join(root, name)
        stat = File.lstat(path)
        if stat.directory?
          found[name] = :directory
        elsif stat.file?
          found[name] = [Digest::SHA256.file(path).hexdigest, (stat.mtime.to_i unless shared.include?(name))]
        end
      end
      found
    end

    # Nothing but the destination was made beside it, the file beside it
    # is as it was, and no link under it leads out.
    def check_contained(room, dest)
      extra = Dir.children(room) - %w[dest secret]
      fail!("written outside the destination: #{extra.inspect}") unless extra.empty?
      fail!("the file beside the destination was changed") unless File.read(File.join(room, "secret")) == "secret"
      if !WINDOWS && File.stat(File.join(room, "secret")).nlink != 1
        fail!("the file beside the destination was linked to")
      end
      return unless File.directory?(dest)

      Dir.glob("**/*", File::FNM_DOTMATCH, base: dest).each do |name|
        path = File.join(dest, name)
        next unless File.symlink?(path)

        target = File.expand_path(File.readlink(path), File.dirname(path))
        fail!("the link #{name} leads out, to #{target}") unless target == dest || target.start_with?("#{dest}/")
      end
    end

    # ---- mutate --------------------------------------------------------

    def case_mutate
      bytes = mutate(@corpus.sample(random: @rng).dup)
      path = File.join(@dir, "mutated.tar")
      File.binwrite(path, bytes)

      acceptably do
        Ziperu::Tar.foreach(StringIO.new(bytes)) do |entry|
          entry.read if @rng.rand < 0.7
          entry.mtime
          entry.inspect
        end
      end
      room = fresh("ours")
      dest = File.join(room, "dest")
      FileUtils.mkdir_p(room)
      File.write(File.join(room, "secret"), "secret")
      acceptably { quietly { Ziperu::Tar.extract_all(path, dest, symlinks: :create, on_exists: :overwrite) } }
      check_contained(room, dest)
    end

    def acceptably
      yield
    rescue *ACCEPTABLE
      nil
    rescue ArgumentError => e
      # A NUL in a name is what Ruby's own File calls refuse this way.
      raise unless e.message.include?("null byte") || e.message.include?("\\0")
    end

    def mutate(bytes)
      @rng.rand(1..4).times do
        next if bytes.empty?

        at = @rng.rand(bytes.bytesize)
        case @rng.rand(7)
        when 0 then bytes.setbyte(at, @rng.rand(256))
        when 1 then bytes.setbyte(at, bytes.getbyte(at) ^ (1 << @rng.rand(8)))
        when 2 then bytes = bytes.byteslice(0, at)
        when 3 then bytes[at - (at % 512), 512] = "\0".b * 512
        when 4 then bytes = bytes.byteslice(0, at) + bytes.byteslice(at - (at % 512), 512).to_s + bytes.byteslice(at..)
        when 5 then bytes[at, @rng.rand(1..12)] = @rng.bytes(@rng.rand(1..12))
        else bytes[at, 4] = ["../", "/../", "\xff\xff\xff\xff".b, "7777"].sample(random: @rng).b
        end
      end
      bytes
    end

    # ---- bookkeeping ---------------------------------------------------

    def quietly
      saved = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = saved
    end

    def remember(bytes)
      @corpus << bytes
      @corpus.shift if @corpus.size > 64
    end

    def record_failure(iteration, kind, error)
      @failures << [iteration, kind, error]
      dir = File.join(OUT, "failures")
      FileUtils.mkdir_p(dir)
      base = File.join(dir, "tar-seed#{@seed}-iter#{iteration}-#{kind}")
      %w[in.tar mutated.tar ours.tar].each do |f|
        src = File.join(@dir, f)
        FileUtils.cp(src, "#{base}-#{f}") if File.exist?(src)
      end
      File.write("#{base}.json", JSON.pretty_generate((@current || {}).merge(
                                                        "error"     => "#{error.class}: #{error.message}".force_encoding(Encoding::UTF_8).scrub,
                                                        "backtrace" => error.backtrace&.first(8)
                                                      )))
      warn "FAIL iteration #{iteration} (#{kind}): #{error.class}: #{error.message.lines.first&.chomp}"
      warn "     saved to #{base}.*; rerun with --seed #{@seed} --iterations #{iteration + 1}"
    end
  end

  def self.find_python
    [ENV.fetch("PYTHON", nil), "python3", "python"].compact.each do |candidate|
      out, status = Open3.capture2e(candidate, "-c", "import tarfile, sys; print(sys.version_info[:2])")
      return [candidate] if status.success? && out.include?("(3")
    rescue Errno::ENOENT
      next
    end
    abort "python 3 is needed as the oracle (set PYTHON=...)"
  end

  def self.main(argv)
    options = { seed: Random.new_seed % (2**31), iterations: nil, time: nil, only: nil }
    OptionParser.new do |o|
      o.on("--seed N", Integer) { |v| options[:seed] = v }
      o.on("--iterations N", Integer) { |v| options[:iterations] = v }
      o.on("--time SECONDS", Float) { |v| options[:time] = v }
      o.on("--only CASE", %w[read extract write mutate]) { |v| options[:only] = v.to_sym }
    end.parse!(argv)
    options[:iterations] ||= 200 unless options[:time]
    puts "seed #{options[:seed]}; oracle: python tarfile"

    FileUtils.mkdir_p(OUT)
    Dir.mktmpdir("ziperu-tar-fuzz", OUT) do |dir|
      runner = Runner.new(seed: options[:seed], python: find_python, dir: dir)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      i = 0
      loop do
        break if options[:iterations] && i >= options[:iterations]
        break if options[:time] && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > options[:time]

        runner.run_one(i, only: options[:only])
        i += 1
        $stderr.print "." if (i % 10).zero?
      end
      $stderr.puts
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      puts "#{i} iterations in #{elapsed.round(1)}s: #{runner.stats.sort.map { |k, v| "#{k}=#{v}" }.join(" ")}"
      if runner.failures?
        puts "FAILED"
        exit 1
      end
      puts "ok"
      FileUtils.chmod_R(0o755, dir, force: true)
    end
  end
end

TarFuzz.main(ARGV) if $PROGRAM_NAME == __FILE__
