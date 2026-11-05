# rubyzip compatibility

rubyzip 3.7.0's own test suite run against ziperu 0.1.0 (`rake compat`, 2026-11-04).

**371 of 476 tests pass (77.9%)** across the files that load; 0 test files fail to load (usually a missing class), so the true total is higher.

| File | Pass | Runs | Fail | Error | Skip |
|---|---:|---:|---:|---:|---:|
| test/basic_zip_file_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/bzip2_support_test.rb | 0 | 1 | 1 | 0 | 0 |
| test/case_sensitivity_test.rb | 3 | 3 | 0 | 0 | 0 |
| test/central_directory_entry_test.rb | 0 | 5 | 2 | 3 | 0 |
| test/central_directory_test.rb | 0 | 11 | 2 | 8 | 1 |
| test/constants_test.rb | 1 | 1 | 0 | 0 | 0 |
| test/crypto/aes_encryption_test.rb | 0 | 13 | 0 | 13 | 0 |
| test/crypto/null_encryption_test.rb | 0 | 5 | 1 | 4 | 0 |
| test/crypto/traditional_encryption_test.rb | 0 | 9 | 0 | 9 | 0 |
| test/decompressor_test.rb | 0 | 1 | 0 | 1 | 0 |
| test/deflater_test.rb | 0 | 4 | 1 | 3 | 0 |
| test/dos_time_test.rb | 2 | 12 | 1 | 9 | 0 |
| test/encryption_test.rb | 8 | 12 | 3 | 1 | 0 |
| test/entry_set_test.rb | 15 | 15 | 0 | 0 | 0 |
| test/entry_test.rb | 16 | 20 | 4 | 0 | 0 |
| test/extra_field_test.rb | 11 | 11 | 0 | 0 | 0 |
| test/extra_field_unknown_test.rb | 4 | 4 | 0 | 0 | 0 |
| test/extra_field_ut_test.rb | 6 | 6 | 0 | 0 | 0 |
| test/file_add_recursive_test.rb | 8 | 9 | 0 | 0 | 1 |
| test/file_extract_all_test.rb | 6 | 6 | 0 | 0 | 0 |
| test/file_extract_directory_test.rb | 4 | 4 | 0 | 0 | 0 |
| test/file_extract_test.rb | 7 | 7 | 0 | 0 | 0 |
| test/file_options_test.rb | 7 | 7 | 0 | 0 | 0 |
| test/file_permissions_test.rb | 4 | 4 | 0 | 0 | 0 |
| test/file_split_test.rb | 0 | 3 | 1 | 2 | 0 |
| test/file_test.rb | 42 | 53 | 5 | 5 | 1 |
| test/filesystem/dir_test.rb | 7 | 7 | 0 | 0 | 0 |
| test/filesystem/directory_iterator_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/filesystem/file_mutating_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/filesystem/file_nonmutating_test.rb | 48 | 48 | 0 | 0 | 0 |
| test/filesystem/file_stat_test.rb | 12 | 12 | 0 | 0 | 0 |
| test/inflater_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/input_stream_test.rb | 28 | 30 | 2 | 0 | 0 |
| test/ioextras/abstract_input_stream_test.rb | 31 | 31 | 0 | 0 | 0 |
| test/ioextras/abstract_output_stream_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/ioextras/fake_io_test.rb | 24 | 24 | 0 | 0 | 0 |
| test/local_entry_test.rb | 0 | 12 | 1 | 11 | 0 |
| test/output_stream_test.rb | 27 | 28 | 1 | 0 | 0 |
| test/pass_thru_compressor_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/pass_thru_decompressor_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/path_traversal_test.rb | 15 | 15 | 0 | 0 | 0 |
| test/require_test.rb | 3 | 3 | 0 | 0 | 0 |
| test/samples/example_recursive_test.rb | 1 | 1 | 0 | 0 | 0 |
| test/settings_test.rb | 5 | 6 | 1 | 0 | 0 |
| test/stored_support_test.rb | 2 | 2 | 0 | 0 | 0 |
| test/unicode_file_names_and_comments_test.rb | 2 | 2 | 0 | 0 | 0 |
| test/version_test.rb | 1 | 1 | 0 | 0 | 0 |
| test/zip64_full_test.rb | 0 | 1 | 0 | 0 | 1 |
| test/zip64_support_test.rb | 1 | 1 | 0 | 0 | 0 |

## Failing tests

**test/bzip2_support_test.rb**
- `Bzip2SupportTest#test_read`

**test/central_directory_entry_test.rb**
- `ZipCentralDirectoryEntryTest#test_read_corrupted_entry_raises_error`
- `ZipCentralDirectoryEntryTest#test_read_corrupted_entry_returns_nil:`
- `ZipCentralDirectoryEntryTest#test_read_entry_from_truncated_zip_file_raises_error`
- `ZipCentralDirectoryEntryTest#test_read_entry_from_truncated_zip_file_returns_nil:`
- `ZipCentralDirectoryEntryTest#test_read_from_stream:`

**test/central_directory_test.rb**
- `ZipCentralDirectoryTest#test_count_entries:`
- `ZipCentralDirectoryTest#test_equality:`
- `ZipCentralDirectoryTest#test_error_file_with_too_high_number_of_entries_declared:`
- `ZipCentralDirectoryTest#test_read_eocd_with_wrong_cdir_offset_from_buffer`
- `ZipCentralDirectoryTest#test_read_eocd_with_wrong_cdir_offset_from_file`
- `ZipCentralDirectoryTest#test_read_file_with_cdir_headers_in_payload:`
- `ZipCentralDirectoryTest#test_read_from_invalid_stream:`
- `ZipCentralDirectoryTest#test_read_from_stream:`
- `ZipCentralDirectoryTest#test_warn_file_with_too_high_number_of_entries_declared:`
- `ZipCentralDirectoryTest#test_write_to_stream:`

**test/crypto/aes_encryption_test.rb**
- `AESDecrypterTest#test_decrypt_aes128:`
- `AESDecrypterTest#test_decrypt_aes256:`
- `AESDecrypterTest#test_gp_flags:`
- `AESDecrypterTest#test_header_bytesize:`
- `AESDecrypterTest#test_reset!:`
- `AESEncrypterTest#test_data_descriptor_and_crc_are_suppressed:`
- `AESEncrypterTest#test_decrypt_with_wrong_password_raises:`
- `AESEncrypterTest#test_encrypt_decrypt_round_trip:`
- `AESEncrypterTest#test_encrypt_decrypt_round_trip_in_chunks:`
- `AESEncrypterTest#test_gp_flags:`
- `AESEncrypterTest#test_header_bytesize:`
- `AESEncrypterTest#test_reset_generates_a_fresh_salt_each_time:`
- `AESEncrypterTest#test_tampered_ciphertext_fails_integrity_check:`

**test/crypto/null_encryption_test.rb**
- `NullEncrypterTest#test_encrypt:`
- `NullEncrypterTest#test_gp_flags:`
- `NullEncrypterTest#test_header:`
- `NullEncrypterTest#test_header_bytesize:`
- `NullEncrypterTest#test_reset!`

**test/crypto/traditional_encryption_test.rb**
- `TraditionalDecrypterTest#test_decrypt:`
- `TraditionalDecrypterTest#test_gp_flags:`
- `TraditionalDecrypterTest#test_header_bytesize:`
- `TraditionalDecrypterTest#test_reset!:`
- `TraditionalEncrypterTest#test_encrypt:`
- `TraditionalEncrypterTest#test_gp_flags:`
- `TraditionalEncrypterTest#test_header:`
- `TraditionalEncrypterTest#test_header_bytesize:`
- `TraditionalEncrypterTest#test_reset!:`

**test/decompressor_test.rb**
- `DecompressorTest#test_decompressor_registration:`

**test/deflater_test.rb**
- `DeflaterTest#test_data_error`
- `DeflaterTest#test_default_compression:`
- `DeflaterTest#test_deflate_strategy:`
- `DeflaterTest#test_output_operator:`

**test/dos_time_test.rb**
- `DOSTimeTest#test_at:`
- `DOSTimeTest#test_binary_dos_fields_are_clamped_to_the_representable_range`
- `DOSTimeTest#test_from_time:`
- `DOSTimeTest#test_gm:`
- `DOSTimeTest#test_local:`
- `DOSTimeTest#test_mktime:`
- `DOSTimeTest#test_new:`
- `DOSTimeTest#test_now:`
- `DOSTimeTest#test_parse_binary_dos_format:`
- `DOSTimeTest#test_utc:`

**test/encryption_test.rb**
- `EncryptionTest#test_aes_encrypt`
- `EncryptionTest#test_aes_encrypt_wrong_password`
- `EncryptionTest#test_decrypt_with_wrong_password`
- `EncryptionTest#test_encrypt:`

**test/entry_test.rb**
- `ZipEntryTest#test_compression_level_flags`
- `ZipEntryTest#test_constructor_and_getters`
- `ZipEntryTest#test_equality`
- `ZipEntryTest#test_incomplete?`

**test/file_split_test.rb**
- `ZipFileSplitTest#test_raise_error_on_open_split_zip:`
- `ZipFileSplitTest#test_split:`
- `ZipFileSplitTest#test_split_method_respond`

**test/file_test.rb**
- `ZipFileTest#test_add_different_compression:`
- `ZipFileTest#test_add_different_compression_as_default:`
- `ZipFileTest#test_add_directory`
- `ZipFileTest#test_add_stored`
- `ZipFileTest#test_compound2:`
- `ZipFileTest#test_error_count_entries_with_too_high_number_of_entries_declared`
- `ZipFileTest#test_get_input_stream_stored_with_gpflag_bit3`
- `ZipFileTest#test_get_output_stream:`
- `ZipFileTest#test_mkdir`
- `ZipFileTest#test_warn_count_entries_with_too_high_number_of_entries_declared:`

**test/inflater_test.rb**
- `InflaterTest#test_read_everything:`
- `InflaterTest#test_read_in_chunks:`

**test/input_stream_test.rb**
- `ZipInputStreamTest#test_open_file_with_gp3bit_set`
- `ZipInputStreamTest#test_open_file_with_gp3bit_set_created_by_osx_archive`

**test/local_entry_test.rb**
- `ZipLocalEntryTest#test_read64_local_offset:`
- `ZipLocalEntryTest#test_read_date_time:`
- `ZipLocalEntryTest#test_read_local_entry_from_non_zip_file:`
- `ZipLocalEntryTest#test_read_local_entry_from_truncated_zip_file_raises_error`
- `ZipLocalEntryTest#test_read_local_entry_from_truncated_zip_file_returns_nil:`
- `ZipLocalEntryTest#test_read_local_entry_header_of_first_test_zip_entry:`
- `ZipLocalEntryTest#test_read_local_offset:`
- `ZipLocalEntryTest#test_rewrite_local_header64:`
- `ZipLocalEntryTest#test_rewrite_local_header:`
- `ZipLocalEntryTest#test_write_64entry:`
- `ZipLocalEntryTest#test_write_entry:`
- `ZipLocalEntryTest#test_write_entry_with_zip64:`

**test/output_stream_test.rb**
- `ZipOutputStreamTest#test_put_next_entry_using_zip_entry_creates_entries_with_correct_timestamps`

**test/pass_thru_compressor_test.rb**
- `PassThruCompressorTest#test_crc:`
- `PassThruCompressorTest#test_size:`

**test/pass_thru_decompressor_test.rb**
- `PassThruDecompressorTest#test_read_everything:`
- `PassThruDecompressorTest#test_read_in_chunks:`

**test/settings_test.rb**
- `ZipSettingsTest#test_true_warn_invalid_date`

