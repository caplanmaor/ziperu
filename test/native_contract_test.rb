# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# The shapes the native core and the Ruby side agree on, checked so that
# neither can change alone.
class NativeContractTest < Minitest::Test
  def test_entry_rows_are_laid_out_as_ruby_expects
    assert_equal Ziperu::Native::Archive::ROW_FIELDS, Ziperu::Entry::ROW_FIELDS
    assert_predicate Ziperu::Native::Archive::ROW_FIELDS, :frozen?
  end

  def test_rows_and_hashes_carry_the_same_facts
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.zip")
      Ziperu::OutputStream.open(path) do |zos|
        zos.put_next_entry("with_comment.txt", "a comment")
        zos.write("x")
        zos.put_next_entry("plain.txt")
        zos.write("y")
      end
      native = Ziperu::Native::Archive.open_path(path)
      hashes = native.entries
      rows = []
      native.each_entry_row { |row| rows << row }
      assert_equal 2, rows.size
      hashes.zip(rows).each do |hash, row|
        assert_equal Ziperu::Entry::ROW_FIELDS, hash.keys
        assert_equal Ziperu::Entry::ROW_FIELDS.size, row.size
        # A row has nil where a Hash has an empty comment or extra field.
        assert_equal(hash.values, row.map.with_index { |v, i| v.nil? && i.between?(12, 13) ? "" : v })
      end
    end
  end
end
