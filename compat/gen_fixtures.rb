# frozen_string_literal: true

# Recreates what rubyzip's test/gentestfiles.rb generates, without needing
# Info-ZIP's `zip` on the PATH: the archives are written with rubyzip itself
# (this script runs with rubyzip's lib on the load path, cwd = its checkout).

require 'fileutils'
require 'zip'
require 'gentestfiles'

raise "expected rubyzip, got #{Zip::VERSION} from #{Zip.method(:setup).source_location&.first}" unless
  defined?(Zip::OutputStream) && Zip.respond_to?(:setup)

FileUtils.rm_rf('test/data/generated')
FileUtils.mkdir_p('test/data/generated')

# TestFiles.create_test_files, minus the `touch` shell-out.
TestFiles::ASCII_TEST_FILES.each_with_index do |filename, index|
  File.binwrite(filename, (0...(1E4 * (index + 1))).map { rand(33..126).chr }.join)
end
TestFiles::BINARY_TEST_FILES.each_with_index do |filename, index|
  File.binwrite(filename, (0...(1E4 * (index + 1))).map { rand(255) }.pack('C*'))
end
File.binwrite(TestFiles::NULL_FILE, '')
FileUtils.mkdir_p(TestFiles::EMPTY_TEST_DIR)

# TestZipFile.create_test_zips.
File.binwrite('test/data/generated/empty.txt', '')
File.binwrite('test/data/generated/empty_chmod640.txt', '')
File.chmod(0o640, 'test/data/generated/empty_chmod640.txt')
File.binwrite('test/data/generated/short.txt', 'ABCDEF')

test_text = File.binread('test/data/file2.txt')
File.open('test/data/generated/longAscii.txt', 'wb') do |file|
  file << test_text while file.tell < 1E5
end

# Info-ZIP leaves an archive with no entries behind after `zip -d`.
Zip::OutputStream.open(TestZipFile::TEST_ZIP1.zip_name) {}

binary_pattern = File.binread(TestZipFile::TEST_ZIP1.zip_name) * 4
File.open('test/data/generated/longBinary.bin', 'wb') do |file|
  file << binary_pattern << rand << "\0" while file.tell < 6E5
end

def write_zip(test_zip)
  Zip::OutputStream.open(test_zip.zip_name) do |zos|
    zos.comment = test_zip.comment unless test_zip.comment.to_s.empty?
    test_zip.entry_names.each do |name|
      if File.directory?(name)
        zos.put_next_entry("#{name}/")
      else
        zos.put_next_entry(name)
        zos.write(File.binread(name))
      end
    end
  end
end

[TestZipFile::TEST_ZIP2, TestZipFile::TEST_ZIP3, TestZipFile::TEST_ZIP4].each { |z| write_zip(z) }

puts "generated fixtures with rubyzip #{Zip::VERSION}"
