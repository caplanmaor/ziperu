# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# Extraction does not write through a link already on disk below the
# destination: a directory symlink (a junction on Windows, which needs no
# privilege), a file symlink at the entry's own path, or a chain of links
# an archive makes with `symlinks: :create`. Both the native extractor and
# the Ruby per-entry path are checked; a block on extract_all forces the
# latter.
class LinkContainmentTest < Minitest::Test
  PATHS = %i[native ruby].freeze

  def setup
    @root = Dir.mktmpdir
    @outside = File.join(@root, "outside")
    @dest = File.join(@root, "dest")
    FileUtils.mkdir_p([@outside, @dest])
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def test_a_directory_link_in_the_way_is_not_followed
    dir_link(File.join(@dest, "linked"), @outside)
    zip = archive("linked/evil.txt" => "x", "linked/deep/evil.txt" => "x", "fine.txt" => "ok")
    PATHS.each do |path|
      assert_output("", %r{skipped extracting 'linked/evil\.txt' through the link '.*/linked'}) do
        extract_all(zip, path, on_exists: :overwrite)
      end
      assert_empty Dir.children(@outside), "#{path}: nothing written outside"
      assert_equal "ok", File.read(File.join(@dest, "fine.txt"))
    end
  end

  def test_a_link_deeper_down_is_not_followed
    FileUtils.mkdir_p(File.join(@dest, "a"))
    dir_link(File.join(@dest, "a", "l"), @outside)
    zip = archive("a/" => nil, "a/ok.txt" => "ok", "a/l/b/c.txt" => "x")
    PATHS.each do |path|
      assert_output("", %r{through the link '.*a/l'}) { extract_all(zip, path, on_exists: :overwrite) }
      assert_empty Dir.children(@outside), path.to_s
      assert_equal "ok", File.read(File.join(@dest, "a", "ok.txt"))
    end
  end

  def test_a_directory_entry_at_a_link_is_skipped
    dir_link(File.join(@dest, "linked"), @outside)
    zip = archive("linked/" => nil)
    PATHS.each do |path|
      assert_output("", /through the link/) { extract_all(zip, path, on_exists: :overwrite) }
      assert File.symlink?(File.join(@dest, "linked")), "#{path}: the link is left alone"
    end
  end

  def test_entry_extract_refuses_a_link_in_the_way
    dir_link(File.join(@dest, "linked"), @outside)
    zip = archive("linked/evil.txt" => "x")
    Ziperu::File.open(zip) do |zf|
      assert_output("", /through the link/) do
        zf.get_entry("linked/evil.txt").extract(destination_directory: @dest, create_parent_directories: true)
      end
    end
    assert_empty Dir.children(@outside)
  end

  def test_a_file_link_at_the_entry_path_is_not_written_through
    victim = File.join(@outside, "victim.txt")
    File.write(victim, "original")
    file_link(File.join(@dest, "file_link.txt"), victim)
    zip = archive("file_link.txt" => "pwned")
    PATHS.each do |path|
      %i[overwrite raise skip].each do |policy|
        assert_output("", /through the link/) { extract_all(zip, path, on_exists: policy) }
        assert_equal "original", File.read(victim), "#{path}, #{policy}"
      end
    end
  end

  def test_a_dangling_link_is_not_followed
    file_link(File.join(@dest, "dangling.txt"), File.join(@outside, "created.txt"))
    zip = archive("dangling.txt" => "x")
    PATHS.each do |path|
      assert_output("", /through the link/) { extract_all(zip, path) }
      refute File.exist?(File.join(@outside, "created.txt")), path.to_s
    end
  end

  def test_the_destination_itself_may_be_a_link
    real = File.join(@root, "real")
    Dir.mkdir(real)
    via = File.join(@root, "via")
    dir_link(via, real)
    zip = archive("d/f.txt" => "ok")
    PATHS.each do |path|
      assert_silent { extract_all(zip, path, on_exists: :overwrite, dest: via) }
      assert_equal "ok", File.read(File.join(real, "d", "f.txt"))
    end
  end

  def test_chained_symlink_entries_cannot_climb_out
    zip = File.join(@root, "chain.zip")
    src = File.join(@root, "src")
    Dir.mkdir(src)
    file_link(File.join(src, "b"), ".")
    file_link(File.join(src, "c"), "b/..")
    Ziperu::File.open(zip, create: true) do |zf|
      zf.add("b", File.join(src, "b"))
      zf.add("c", File.join(src, "c"))
    end
    assert_output("", %r{skipped symlink 'c' to 'b/\.\.'}) do
      Ziperu::File.open(zip) { |zf| zf.extract_all(@dest, symlinks: :create) }
    end
    assert File.symlink?(File.join(@dest, "b"))
    refute File.symlink?(File.join(@dest, "c"))
  end

  def test_leading_dot_dots_in_a_link_target_still_work
    zip = File.join(@root, "up.zip")
    src = File.join(@root, "src")
    FileUtils.mkdir_p(File.join(src, "lib"))
    File.write(File.join(src, "real.txt"), "r")
    file_link(File.join(src, "lib", "up.txt"), "../real.txt")
    Ziperu::File.open(zip, create: true) do |zf|
      zf.add("real.txt", File.join(src, "real.txt"))
      zf.add("lib/", File.join(src, "lib"))
      zf.add("lib/up.txt", File.join(src, "lib", "up.txt"))
    end
    assert_silent { Ziperu::File.open(zip) { |zf| zf.extract_all(@dest, symlinks: :create) } }
    assert_equal "r", File.read(File.join(@dest, "lib", "up.txt"))
  end

  private

  def archive(entries)
    path = File.join(@root, "a#{entries.hash.abs}.zip")
    Ziperu::OutputStream.open(path) do |zos|
      entries.each do |name, data|
        zos.put_next_entry(name)
        zos.write(data) if data
      end
    end
    path
  end

  def extract_all(zip, path, on_exists: :raise, dest: @dest)
    Ziperu::File.open(zip) do |zf|
      if path == :native
        zf.extract_all(dest, on_exists: on_exists)
      else
        # A block takes the per-entry Ruby path; it answers as the policy.
        zf.extract_all(dest) { Ziperu::Entry.on_exists_block(on_exists).call }
      end
    end
  rescue Ziperu::DestinationExistsError
    nil
  end

  # A directory link: a junction on Windows (no privilege needed), a
  # symlink elsewhere.
  def dir_link(link, target)
    if Gem.win_platform?
      out = IO.popen(["cmd", "/c", "mklink", "/J", link.tr("/", "\\"), target.tr("/", "\\")], err: %i[child out], &:read)
      skip "mklink /J failed: #{out}" unless $?.success?
    else
      File.symlink(target, link)
    end
  end

  def file_link(link, target)
    File.symlink(target, link)
  rescue NotImplementedError, Errno::EPERM, Errno::EACCES
    skip "needs symlink support"
  end
end
