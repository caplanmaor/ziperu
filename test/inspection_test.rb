# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/archive_scratch"

# Looking before acting: `verify(report: true)`, `extraction_plan`, and
# the named limit profiles.
class InspectionTest < Minitest::Test
  include TestHelper
  include ArchiveScratch

  PAYLOAD = "PAYLOAD-OF-THE-SECOND-ENTRY" * 10

  def test_a_verify_report_tells_verified_failed_and_skipped_apart
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("ok.txt")
      zos.write("fine")
      zos.put_next_entry(Ziperu::Entry.new("", "bad.txt", compression_method: Ziperu::Entry::STORED))
      zos.write(PAYLOAD)
      zos.put_next_entry("dir/")
    end
    bytes = File.binread(@path)
    bytes.setbyte(bytes.index(PAYLOAD), "!".ord)
    File.binwrite(@path, bytes)
    added = File.join(@dir, "added.txt")
    File.write(added, "new")

    Ziperu::File.open(@path) do |zf|
      zf.add("added.txt", added)
      report = zf.verify(report: true)
      assert_equal ["ok.txt"], report.verified.map(&:name)
      assert_equal ["bad.txt"], report.failed.keys.map(&:name)
      assert_equal({ "added.txt" => :not_written }, report.skipped.transform_keys(&:name))
      refute_predicate report, :ok?
      refute_predicate report, :no_failures?
      assert_equal "1 verified, 1 failed, 1 skipped", report.to_s
      assert_predicate report, :frozen?
      # The default return is as before: the failures alone.
      assert_equal ["bad.txt"], zf.verify.keys.map(&:name)
    end
  end

  def test_encrypted_entries_are_skipped_without_a_password_and_checked_with_one
    Ziperu::OutputStream.open(@path, encrypter: Ziperu::AESEncrypter.new("pw")) do |zos|
      zos.put_next_entry("secret.txt")
      zos.write("hidden")
    end
    Ziperu::File.open(@path) do |zf|
      report = zf.verify(report: true)
      assert_empty report.verified
      assert_equal [:encrypted], report.skipped.values
      refute_predicate report, :ok?, "nothing checked is not a pass"
      assert_predicate report, :no_failures?
      assert_empty zf.verify, "the default return still reads as clean"
    end
    Ziperu::File.open(@path, password: "pw") do |zf|
      assert_predicate zf.verify(report: true), :ok?
    end
  end

  def test_an_extraction_plan_says_what_extract_all_would_do
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("d/")
      { "d/a.txt" => "aaaaa", "../evil.txt" => "x", "n:1.txt" => "1", "n_1.txt" => "2", "here.txt" => "h" }
        .each do |name, data|
        zos.put_next_entry(name)
        zos.write(data)
      end
    end
    dest = File.join(@dir, "out")
    Dir.mkdir(dest)
    File.write(File.join(dest, "here.txt"), "already")

    plan = Ziperu::File.open(@path) { |zf| zf.extraction_plan(dest, sanitize: :windows) }
    by_name = plan.to_h { |item| [item.entry.name, item] }
    assert_equal "d/", plan.first.entry.name, "directories first, as extract_all goes"
    assert_equal :directory, by_name["d/"].kind
    assert_equal([:extract, 5, File.join(dest, "d/a.txt")], by_name["d/a.txt"].then { |i| [i.status, i.declared_size, i.path] })
    # Sanitizing turns `..` into `_`, which is safe; without it the entry
    # resolves outside.
    assert_equal ["_/evil.txt", :extract], [by_name["../evil.txt"].name, by_name["../evil.txt"].status]
    unsanitized = Ziperu::File.open(@path) { |zf| zf.extraction_plan(dest) }.find { |i| i.entry.name == "../evil.txt" }
    assert_equal :unsafe, unsanitized.status
    refute_predicate unsanitized, :extract?
    assert_equal "n_1.txt", by_name["n:1.txt"].name
    assert_equal by_name["n:1.txt"].entry, by_name["n_1.txt"].collides_with, "the same name once sanitized"
    assert by_name["here.txt"].exists
    refute by_name["d/a.txt"].exists
    assert_equal ["here.txt"], Dir.children(dest), "nothing was written"

    plan = Ziperu::File.open(@path) { |zf| zf.extraction_plan(dest, exclude: "*.txt", junk_paths: true) }
    assert_empty plan
    assert_raises(ArgumentError) { Ziperu::File.open(@path) { |zf| zf.extraction_plan(dest, sanitize: :mac) } }
  end

  def test_an_extraction_plan_sees_a_link_on_the_way
    dest = File.join(@dir, "out")
    outside = File.join(@dir, "outside")
    FileUtils.mkdir_p([dest, outside])
    if Gem.win_platform?
      ok = system("cmd", "/c", "mklink", "/J", File.join(dest, "linked").tr("/", "\\"), outside.tr("/", "\\"),
                  out: File::NULL)
      skip "mklink /J failed" unless ok
    else
      File.symlink(outside, File.join(dest, "linked"))
    end
    Ziperu::OutputStream.open(@path) do |zos|
      zos.put_next_entry("linked/x.txt")
      zos.write("x")
    end
    item = Ziperu::File.open(@path) { |zf| zf.extraction_plan(dest) }.first
    assert_equal :through_link, item.status
    assert_equal File.join(dest, "linked"), item.link
  end

  def test_limit_profiles_apply_per_archive_or_globally
    Ziperu::OutputStream.open(@path) do |zos|
      3.times do |i|
        zos.put_next_entry("f#{i}.txt")
        zos.write("x")
      end
    end
    assert_predicate Ziperu::Limits::UPLOAD, :frozen?
    Ziperu::File.open(@path, **Ziperu::Limits::UPLOAD) { |zf| assert_equal 3, zf.size }
    assert_raises(Ziperu::LimitError) do
      Ziperu::File.open(@path, **Ziperu::Limits::STRICT, max_entries: 2) { nil }
    end

    Ziperu::Limits.apply(Ziperu::Limits::STRICT)
    assert_equal 1_000, Ziperu.max_entries
    assert_equal 100, Ziperu.max_compression_ratio
    Ziperu::Limits.apply(Ziperu::Limits::NONE)
    assert_nil Ziperu.max_entries
    assert_raises(ArgumentError) { Ziperu::Limits.apply(max_entires: 5) }
  end
end
