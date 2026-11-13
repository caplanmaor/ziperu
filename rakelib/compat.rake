# frozen_string_literal: true

# Runs rubyzip's own test suite against this gem and reports how much of it
# passes. `rake compat` fetches rubyzip's source into tmp/, generates its
# fixtures with the real rubyzip, then runs each test file in a subprocess
# with `require "ziperu"` resolving to lib/ here. Results land in COMPAT.md.

require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "stringio"
require "timeout"
require "zlib"

RUBYZIP_VERSION = "3.7.0"
RUBYZIP_DIR = File.expand_path("../tmp/rubyzip", __dir__)
RUBYZIP_TARBALL = "https://github.com/rubyzip/rubyzip/archive/refs/tags/v#{RUBYZIP_VERSION}.tar.gz".freeze
COMPAT_DIR = File.expand_path("../compat", __dir__)
OUR_LIB = File.expand_path("../lib", __dir__)
COMPAT_REPORT = File.expand_path("../COMPAT.md", __dir__)
COMPAT_LOG_DIR = File.expand_path("../tmp/compat-logs", __dir__)
COMPAT_RESULTS = File.expand_path("../tmp/compat-results.json", __dir__)
PER_FILE_TIMEOUT = 300

namespace :compat do
  desc "Download rubyzip #{RUBYZIP_VERSION} into tmp/rubyzip"
  task :fetch do
    unless File.exist?(File.join(RUBYZIP_DIR, "test", "gentestfiles.rb"))
      require "net/http"

      puts "Fetching #{RUBYZIP_TARBALL}"
      FileUtils.mkdir_p(File.dirname(RUBYZIP_DIR))
      tarball = fetch_following_redirects(RUBYZIP_TARBALL)
      FileUtils.rm_rf(RUBYZIP_DIR)
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(tarball))) do |tar|
        tar.each do |entry|
          # Strip the leading "rubyzip-<version>/" directory.
          rel = entry.full_name.split("/", 2)[1]
          next if rel.nil? || rel.empty?

          dest = File.join(RUBYZIP_DIR, rel)
          if entry.directory?
            FileUtils.mkdir_p(dest)
          elsif entry.file?
            FileUtils.mkdir_p(File.dirname(dest))
            File.binwrite(dest, entry.read)
          end
        end
      end
    end

    # rubyzip's helper regenerates fixtures with Info-ZIP's `zip`; ours
    # skips that (see compat:fixtures) and otherwise does the same.
    FileUtils.cp(File.join(COMPAT_DIR, "test_helper.rb"), File.join(RUBYZIP_DIR, "test", "test_helper.rb"))
    # Archives rubyzip's file_test writes and deletes itself; a run that
    # died midway leaves them behind and fails the next run with EntryExists.
    FileUtils.rm_f(Dir[File.join(RUBYZIP_DIR, "test", "data", "{fast,default,best}_comp.zip")])
  end

  desc "Generate rubyzip's test fixtures using the real rubyzip"
  task fixtures: :fetch do
    run_unbundled(
      [Gem.ruby, "-I", File.join(RUBYZIP_DIR, "lib"), "-I", File.join(RUBYZIP_DIR, "test"),
       File.join(COMPAT_DIR, "gen_fixtures.rb")],
      chdir: RUBYZIP_DIR
    )
  end

  desc "Run rubyzip's tests against ziperu and write COMPAT.md"
  task run: :fixtures do
    files = Dir.glob("test/**/*_test.rb", base: RUBYZIP_DIR).sort
    only = ENV.fetch("ONLY", nil)
    files.select! { |f| only.split.any? { |sub| f.include?(sub) } } if only
    FileUtils.mkdir_p(COMPAT_LOG_DIR)

    results = files.map do |file|
      print format("%-55s", file)
      result = run_test_file(file)
      puts format_summary(result)
      result
    end

    # The committed COMPAT.md is the baseline: fewer passes than it
    # records is a regression (COMPAT_ACCEPT=1 to take a new, lower one).
    baseline = File.read(COMPAT_REPORT)[/\*\*(\d+) of \d+ tests pass/, 1]&.to_i if File.exist?(COMPAT_REPORT)
    write_report(results)
    totals = totals_for(results)
    puts
    puts "#{totals[:passed]}/#{totals[:runs]} rubyzip tests pass (#{percent(totals[:passed], totals[:runs])}%); " \
         "#{totals[:load_errors]} files failed to load. Report: COMPAT.md"
    if !only && baseline && totals[:passed] < baseline && !ENV["COMPAT_ACCEPT"]
      abort "rubyzip compatibility regressed: #{totals[:passed]} tests pass, COMPAT.md recorded #{baseline}"
    end
  end
end

desc "Run rubyzip's test suite against ziperu (alias for compat:run)"
task compat: "compat:run"

def fetch_following_redirects(url, limit = 5)
  raise "too many redirects" if limit.zero?

  uri = URI(url)
  res = Net::HTTP.get_response(uri)
  case res
  when Net::HTTPSuccess then res.body
  when Net::HTTPRedirection then fetch_following_redirects(res["location"], limit - 1)
  else raise "download failed: #{res.code} #{res.message}"
  end
end

def run_unbundled(cmd, chdir:, timeout: PER_FILE_TIMEOUT)
  Bundler.with_unbundled_env do
    out = +""
    status = nil
    Open3.popen2e(*cmd, chdir: chdir) do |stdin, io, wait|
      stdin.close
      begin
        Timeout.timeout(timeout) { out << io.read }
      rescue Timeout::Error
        Process.kill("KILL", wait.pid)
        out << "\n[killed after #{timeout}s]\n"
      end
      status = wait.value
    end
    [out, status]
  end
end

def run_test_file(file)
  cmd = [Gem.ruby, "-I", OUR_LIB, "-I", File.join(RUBYZIP_DIR, "test"), file]
  out, status = run_unbundled(cmd, chdir: RUBYZIP_DIR)
  File.write(File.join(COMPAT_LOG_DIR, "#{file.tr("/", "_")}.log"), out)

  if out.include?("COMPAT LEAK")
    return { file: file, load_error: true, exit: 99, failed_tests: [],
             reason: "rubyzip gem activated (uninstall it: results would be rubyzip's, not ours)" }
  end

  summary = out[/^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/]
  if summary.nil?
    return { file: file, load_error: true, exit: status&.exitstatus, failed_tests: [],
             reason: out.lines.grep(/Error|error/).first&.strip }
  end

  runs, _asserts, failures, errors, skips = summary.scan(/\d+/).map(&:to_i)
  failed = out.scan(/^\s*\d+\) (?:Failure|Error):\n(\S+)/).flatten
  { file: file, runs: runs, failures: failures, errors: errors, skips: skips,
    passed: runs - failures - errors - skips, failed_tests: failed }
end

def format_summary(r)
  return "LOAD ERROR  #{r[:reason]}" if r[:load_error]

  format("%3d/%-3d pass  (%d failures, %d errors, %d skips)", r[:passed], r[:runs], r[:failures], r[:errors], r[:skips])
end

def totals_for(results)
  ran = results.reject { |r| r[:load_error] }
  {
    runs:        ran.sum { |r| r[:runs] },
    passed:      ran.sum { |r| r[:passed] },
    failures:    ran.sum { |r| r[:failures] },
    errors:      ran.sum { |r| r[:errors] },
    skips:       ran.sum { |r| r[:skips] },
    load_errors: results.count { |r| r[:load_error] }
  }
end

def percent(num, den)
  den.zero? ? 0 : (100.0 * num / den).round(1)
end

def write_report(results)
  totals = totals_for(results)
  lines = []
  lines << "# rubyzip compatibility"
  lines << ""
  lines << "rubyzip #{RUBYZIP_VERSION}'s own test suite run against ziperu #{Ziperu::VERSION} " \
           "(`rake compat`, #{Time.now.utc.strftime("%Y-%m-%d")})."
  lines << ""
  lines << "**#{totals[:passed]} of #{totals[:runs]} tests pass (#{percent(totals[:passed], totals[:runs])}%)** " \
           "across the files that load; #{totals[:load_errors]} test files fail to load " \
           "(usually a missing class), so the true total is higher."
  lines << ""
  lines << "| File | Pass | Runs | Fail | Error | Skip |"
  lines << "|---|---:|---:|---:|---:|---:|"
  results.each do |r|
    lines << if r[:load_error]
               "| #{r[:file]} | — | load error | | | |"
             else
               "| #{r[:file]} | #{r[:passed]} | #{r[:runs]} | #{r[:failures]} | #{r[:errors]} | #{r[:skips]} |"
             end
  end
  lines << ""
  lines << "## Failing tests"
  lines << ""
  results.each do |r|
    next if r[:failed_tests].empty?

    lines << "**#{r[:file]}**"
    r[:failed_tests].uniq.sort.each { |t| lines << "- `#{t}`" }
    lines << ""
  end
  File.write(COMPAT_REPORT, "#{lines.join("\n")}\n", mode: "wb")
  File.write(COMPAT_RESULTS, JSON.pretty_generate(results))
end
