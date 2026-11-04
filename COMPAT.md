# rubyzip compatibility

rubyzip 3.7.0's own test suite run against ziperu 0.1.0 (`rake compat`, 2026-11-04).

**176 of 452 tests pass (38.9%)** across the files that load; 4 test files fail to load (usually a missing class), so the true total is higher.

| File | Pass | Runs | Fail | Error | Skip |
|---|---:|---:|---:|---:|---:|
| test/basic_zip_file_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/bzip2_support_test.rb | 0 | 1 | 1 | 0 | 0 |
| test/case_sensitivity_test.rb | 0 | 3 | 0 | 3 | 0 |
| test/central_directory_entry_test.rb | 0 | 5 | 2 | 3 | 0 |
| test/central_directory_test.rb | 0 | 11 | 2 | 8 | 1 |
| test/constants_test.rb | 1 | 1 | 0 | 0 | 0 |
| test/crypto/aes_encryption_test.rb | — | load error | | | |
| test/crypto/null_encryption_test.rb | 0 | 5 | 0 | 5 | 0 |
| test/crypto/traditional_encryption_test.rb | 0 | 9 | 0 | 9 | 0 |
| test/decompressor_test.rb | 0 | 1 | 0 | 1 | 0 |
| test/deflater_test.rb | — | load error | | | |
| test/dos_time_test.rb | 2 | 12 | 1 | 9 | 0 |
| test/encryption_test.rb | 1 | 12 | 1 | 10 | 0 |
| test/entry_set_test.rb | 0 | 15 | 0 | 15 | 0 |
| test/entry_test.rb | 12 | 20 | 5 | 3 | 0 |
| test/extra_field_test.rb | 9 | 11 | 2 | 0 | 0 |
| test/extra_field_unknown_test.rb | 4 | 4 | 0 | 0 | 0 |
| test/extra_field_ut_test.rb | 6 | 6 | 0 | 0 | 0 |
| test/file_add_recursive_test.rb | 0 | 9 | 0 | 8 | 1 |
| test/file_extract_all_test.rb | 0 | 6 | 0 | 6 | 0 |
| test/file_extract_directory_test.rb | 4 | 4 | 0 | 0 | 0 |
| test/file_extract_test.rb | 5 | 7 | 0 | 2 | 0 |
| test/file_options_test.rb | 1 | 7 | 0 | 6 | 0 |
| test/file_permissions_test.rb | 0 | 4 | 0 | 4 | 0 |
| test/file_split_test.rb | 0 | 3 | 1 | 2 | 0 |
| test/file_test.rb | 11 | 53 | 8 | 33 | 1 |
| test/filesystem/dir_test.rb | 0 | 7 | 5 | 2 | 0 |
| test/filesystem/directory_iterator_test.rb | 5 | 5 | 0 | 0 | 0 |
| test/filesystem/file_mutating_test.rb | 0 | 5 | 1 | 4 | 0 |
| test/filesystem/file_nonmutating_test.rb | 2 | 48 | 6 | 40 | 0 |
| test/filesystem/file_stat_test.rb | 0 | 12 | 0 | 12 | 0 |
| test/inflater_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/input_stream_test.rb | 28 | 30 | 2 | 0 | 0 |
| test/ioextras/abstract_input_stream_test.rb | 31 | 31 | 0 | 0 | 0 |
| test/ioextras/abstract_output_stream_test.rb | — | load error | | | |
| test/ioextras/fake_io_test.rb | 24 | 24 | 0 | 0 | 0 |
| test/local_entry_test.rb | 0 | 12 | 1 | 11 | 0 |
| test/output_stream_test.rb | 0 | 28 | 1 | 27 | 0 |
| test/pass_thru_compressor_test.rb | — | load error | | | |
| test/pass_thru_decompressor_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/path_traversal_test.rb | 15 | 15 | 0 | 0 | 0 |
| test/require_test.rb | 3 | 3 | 0 | 0 | 0 |
| test/samples/example_recursive_test.rb | 0 | 1 | 0 | 1 | 0 |
| test/settings_test.rb | 3 | 6 | 2 | 1 | 0 |
| test/stored_support_test.rb | 2 | 2 | 0 | 0 | 0 |
| test/unicode_file_names_and_comments_test.rb | 0 | 2 | 0 | 2 | 0 |
| test/version_test.rb | 1 | 1 | 0 | 0 | 0 |
| test/zip64_full_test.rb | 0 | 1 | 0 | 0 | 1 |
| test/zip64_support_test.rb | 1 | 1 | 0 | 0 | 0 |

## Failing tests

**test/bzip2_support_test.rb**
- `Bzip2SupportTest#test_read`

**test/case_sensitivity_test.rb**
- `ZipCaseSensitivityTest#test_add_case_insensitive:`
- `ZipCaseSensitivityTest#test_add_case_sensitive:`
- `ZipCaseSensitivityTest#test_add_case_sensitive_read_case_insensitive:`

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

**test/crypto/null_encryption_test.rb**
- `NullEncrypterTest#test_encrypt:`
- `NullEncrypterTest#test_gp_flags:`
- `NullEncrypterTest#test_header:`
- `NullEncrypterTest#test_header_bytesize:`
- `NullEncrypterTest#test_reset!:`

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
- `EncryptionTest#test_aes_128_decrypt:`
- `EncryptionTest#test_aes_256_decrypt:`
- `EncryptionTest#test_aes_256_entry_decrypt:`
- `EncryptionTest#test_aes_decrypt_keka:`
- `EncryptionTest#test_aes_encrypt:`
- `EncryptionTest#test_aes_encrypt_stored:`
- `EncryptionTest#test_aes_encrypt_via_entry:`
- `EncryptionTest#test_aes_encrypt_with_directory:`
- `EncryptionTest#test_aes_encrypt_wrong_password:`
- `EncryptionTest#test_decrypt_with_wrong_password`
- `EncryptionTest#test_encrypt:`

**test/entry_set_test.rb**
- `ZipEntrySetTest#test_add:`
- `ZipEntrySetTest#test_compound:`
- `ZipEntrySetTest#test_delete:`
- `ZipEntrySetTest#test_dup:`
- `ZipEntrySetTest#test_each:`
- `ZipEntrySetTest#test_entries:`
- `ZipEntrySetTest#test_entries_sorted_in_each:`
- `ZipEntrySetTest#test_entries_with_sort:`
- `ZipEntrySetTest#test_find_entry:`
- `ZipEntrySetTest#test_glob2:`
- `ZipEntrySetTest#test_glob3:`
- `ZipEntrySetTest#test_glob:`
- `ZipEntrySetTest#test_include:`
- `ZipEntrySetTest#test_parent:`
- `ZipEntrySetTest#test_size:`

**test/entry_test.rb**
- `ZipEntryTest#test_compression_level_flags`
- `ZipEntryTest#test_constructor_and_getters`
- `ZipEntryTest#test_ensure_entry_time_set_to_file_mtime:`
- `ZipEntryTest#test_equality`
- `ZipEntryTest#test_gather_fileinfo_from_srcpath`
- `ZipEntryTest#test_incomplete?`
- `ZipEntryTest#test_parent_as_string:`
- `ZipEntryTest#test_store_file_without_compression:`

**test/extra_field_test.rb**
- `ZipExtraFieldTest#test_load_unknown_extra_field`
- `ZipExtraFieldTest#test_read_local_extra_field`

**test/file_add_recursive_test.rb**
- `ZipFileAddRecursiveTest#test_add_recursive_adds_contents_not_the_directory_itself:`
- `ZipFileAddRecursiveTest#test_add_recursive_class_method:`
- `ZipFileAddRecursiveTest#test_add_recursive_conflict_overridable_via_block:`
- `ZipFileAddRecursiveTest#test_add_recursive_conflict_raises_by_default:`
- `ZipFileAddRecursiveTest#test_add_recursive_raises_for_missing_directory:`
- `ZipFileAddRecursiveTest#test_add_recursive_rejects_max_depth_below_one:`
- `ZipFileAddRecursiveTest#test_add_recursive_respects_max_depth:`
- `ZipFileAddRecursiveTest#test_add_recursive_with_entry_prefix:`

**test/file_extract_all_test.rb**
- `ZipFileExtractAllTest#test_extract_all_class_method:`
- `ZipFileExtractAllTest#test_extract_all_creates_missing_intermediate_directories:`
- `ZipFileExtractAllTest#test_extract_all_exists_overwrite_via_block:`
- `ZipFileExtractAllTest#test_extract_all_exists_raises_by_default:`
- `ZipFileExtractAllTest#test_extract_all_round_trips_a_tree:`
- `ZipFileExtractAllTest#test_extract_all_skips_symlinks:`

**test/file_extract_test.rb**
- `ZipFileExtractTest#test_extract_incorrect_size:`
- `ZipFileExtractTest#test_extract_incorrect_size_zip64:`

**test/file_options_test.rb**
- `FileOptionsTest#test_restore_permissions_as_default:`
- `FileOptionsTest#test_restore_permissions_false:`
- `FileOptionsTest#test_restore_permissions_true:`
- `FileOptionsTest#test_restore_times_false:`
- `FileOptionsTest#test_restore_times_true:`
- `FileOptionsTest#test_restore_times_true_as_default:`

**test/file_permissions_test.rb**
- `FilePermissionsTest#test_current_umask:`
- `FilePermissionsTest#test_umask_000:`
- `FilePermissionsTest#test_umask_027:`
- `FilePermissionsTest#test_umask_066:`

**test/file_split_test.rb**
- `ZipFileSplitTest#test_raise_error_on_open_split_zip:`
- `ZipFileSplitTest#test_split:`
- `ZipFileSplitTest#test_split_method_respond`

**test/file_test.rb**
- `ZipFileTest#test_add_different_compression:`
- `ZipFileTest#test_add_different_compression_as_default:`
- `ZipFileTest#test_add_directory:`
- `ZipFileTest#test_add_existing_entry_name`
- `ZipFileTest#test_add_existing_entry_name_replace:`
- `ZipFileTest#test_add_stored:`
- `ZipFileTest#test_change_comment:`
- `ZipFileTest#test_cleans_up_tempfiles_after_close:`
- `ZipFileTest#test_commit:`
- `ZipFileTest#test_commit_preserves_options:`
- `ZipFileTest#test_commit_use_zip_entry:`
- `ZipFileTest#test_compound1:`
- `ZipFileTest#test_compound2:`
- `ZipFileTest#test_count_entries:`
- `ZipFileTest#test_create_from_scratch:`
- `ZipFileTest#test_create_from_scratch_to_buffer:`
- `ZipFileTest#test_double_commit:`
- `ZipFileTest#test_double_commit_zip64:`
- `ZipFileTest#test_error_count_entries_with_too_high_number_of_entries_declared`
- `ZipFileTest#test_get_input_stream_stored_with_gpflag_bit3`
- `ZipFileTest#test_get_output_stream:`
- `ZipFileTest#test_get_output_stream_with_entry:`
- `ZipFileTest#test_mkdir:`
- `ZipFileTest#test_new_with_io_opened_non_binary_mode:`
- `ZipFileTest#test_nonexistant_zip`
- `ZipFileTest#test_open_buffer_close_does_not_change_file:`
- `ZipFileTest#test_open_buffer_with_io_and_block:`
- `ZipFileTest#test_open_buffer_without_block_write_buffer_does_nothing:`
- `ZipFileTest#test_preserve_file_order:`
- `ZipFileTest#test_remove:`
- `ZipFileTest#test_rename:`
- `ZipFileTest#test_rename_entry_to_existing_entry`
- `ZipFileTest#test_rename_non_entry`
- `ZipFileTest#test_rename_to_existing_entry`
- `ZipFileTest#test_rename_to_existing_entry_overwrite:`
- `ZipFileTest#test_rename_with_each:`
- `ZipFileTest#test_replace:`
- `ZipFileTest#test_replace_non_entry`
- `ZipFileTest#test_streaming:`
- `ZipFileTest#test_warn_count_entries_with_too_high_number_of_entries_declared:`
- `ZipFileTest#test_write_buffer:`

**test/filesystem/dir_test.rb**
- `DirectoryTest#test_chroot`
- `DirectoryTest#test_delete`
- `DirectoryTest#test_foreach`
- `DirectoryTest#test_glob:`
- `DirectoryTest#test_mkdir`
- `DirectoryTest#test_open_new`
- `DirectoryTest#test_pwd_chdir_entries:`

**test/filesystem/file_mutating_test.rb**
- `FileMutatingTest#test_chmod:`
- `FileMutatingTest#test_delete:`
- `FileMutatingTest#test_open_write:`
- `FileMutatingTest#test_rename`
- `FileMutatingTest#test_unlink:`

**test/filesystem/file_nonmutating_test.rb**
- `FileNonmutatingTest#test_atime:`
- `FileNonmutatingTest#test_basename:`
- `FileNonmutatingTest#test_blockdev?:`
- `FileNonmutatingTest#test_chardev?:`
- `FileNonmutatingTest#test_chown:`
- `FileNonmutatingTest#test_ctime:`
- `FileNonmutatingTest#test_directory?:`
- `FileNonmutatingTest#test_dirname:`
- `FileNonmutatingTest#test_executable?:`
- `FileNonmutatingTest#test_executable_real?:`
- `FileNonmutatingTest#test_exists?:`
- `FileNonmutatingTest#test_expand_path:`
- `FileNonmutatingTest#test_file?:`
- `FileNonmutatingTest#test_foreach:`
- `FileNonmutatingTest#test_ftype`
- `FileNonmutatingTest#test_grpowned?:`
- `FileNonmutatingTest#test_join:`
- `FileNonmutatingTest#test_link`
- `FileNonmutatingTest#test_lstat:`
- `FileNonmutatingTest#test_mtime:`
- `FileNonmutatingTest#test_new:`
- `FileNonmutatingTest#test_ntfs_time:`
- `FileNonmutatingTest#test_open_read:`
- `FileNonmutatingTest#test_owned?:`
- `FileNonmutatingTest#test_pipe`
- `FileNonmutatingTest#test_pipe?:`
- `FileNonmutatingTest#test_popen:`
- `FileNonmutatingTest#test_read:`
- `FileNonmutatingTest#test_readable?:`
- `FileNonmutatingTest#test_readable_real?:`
- `FileNonmutatingTest#test_readlines:`
- `FileNonmutatingTest#test_readlink`
- `FileNonmutatingTest#test_setgid?:`
- `FileNonmutatingTest#test_setuid?:`
- `FileNonmutatingTest#test_size`
- `FileNonmutatingTest#test_size?:`
- `FileNonmutatingTest#test_socket?:`
- `FileNonmutatingTest#test_split:`
- `FileNonmutatingTest#test_stat:`
- `FileNonmutatingTest#test_sticky?:`
- `FileNonmutatingTest#test_symlink`
- `FileNonmutatingTest#test_symlink?:`
- `FileNonmutatingTest#test_umask:`
- `FileNonmutatingTest#test_writable?:`
- `FileNonmutatingTest#test_writable_real?:`
- `FileNonmutatingTest#test_zero?:`

**test/filesystem/file_stat_test.rb**
- `FileStatTest#test_blksize:`
- `FileStatTest#test_blocks:`
- `FileStatTest#test_dev:`
- `FileStatTest#test_ftype:`
- `FileStatTest#test_gid:`
- `FileStatTest#test_ino:`
- `FileStatTest#test_mode:`
- `FileStatTest#test_nlink:`
- `FileStatTest#test_rdev:`
- `FileStatTest#test_rdev_major:`
- `FileStatTest#test_rdev_minor:`
- `FileStatTest#test_uid:`

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
- `ZipOutputStreamTest#test_cannot_open_file:`
- `ZipOutputStreamTest#test_chained_put_into_next_entry:`
- `ZipOutputStreamTest#test_new:`
- `ZipOutputStreamTest#test_only_zip64_not_ut_suppressed_with_large_size:`
- `ZipOutputStreamTest#test_only_zip64_not_ut_suppressed_with_large_size_file:`
- `ZipOutputStreamTest#test_only_zip64_suppressed:`
- `ZipOutputStreamTest#test_only_zip64_suppressed_file:`
- `ZipOutputStreamTest#test_open:`
- `ZipOutputStreamTest#test_open_without_block_forwards_options:`
- `ZipOutputStreamTest#test_print_deflated:`
- `ZipOutputStreamTest#test_printf_deflated:`
- `ZipOutputStreamTest#test_put_next_entry:`
- `ZipOutputStreamTest#test_put_next_entry_using_zip_entry_creates_entries_with_correct_timestamps:`
- `ZipOutputStreamTest#test_ut_but_not_zip64_suppressed_with_large_size:`
- `ZipOutputStreamTest#test_ut_but_not_zip64_suppressed_with_large_size_file:`
- `ZipOutputStreamTest#test_write_buffer:`
- `ZipOutputStreamTest#test_write_buffer_binmode:`
- `ZipOutputStreamTest#test_write_buffer_with_default_io:`
- `ZipOutputStreamTest#test_write_buffer_with_temp_file2:`
- `ZipOutputStreamTest#test_write_buffer_with_temp_file:`
- `ZipOutputStreamTest#test_write_deflated:`
- `ZipOutputStreamTest#test_writing_to_closed_stream`
- `ZipOutputStreamTest#test_zip64_and_ut_suppressed:`
- `ZipOutputStreamTest#test_zip64_and_ut_suppressed_file:`
- `ZipOutputStreamTest#test_zip64_default_usage:`
- `ZipOutputStreamTest#test_zip64_default_usage_file:`
- `ZipOutputStreamTest#test_zip64_off_by_default:`
- `ZipOutputStreamTest#test_zip64_off_by_default_file:`

**test/pass_thru_decompressor_test.rb**
- `PassThruDecompressorTest#test_read_everything:`
- `PassThruDecompressorTest#test_read_in_chunks:`

**test/samples/example_recursive_test.rb**
- `ExampleRecursiveTest#test_write:`

**test/settings_test.rb**
- `ZipSettingsTest#test_false_continue_on_exists_proc`
- `ZipSettingsTest#test_true_continue_on_exists_proc:`
- `ZipSettingsTest#test_true_warn_invalid_date`

**test/unicode_file_names_and_comments_test.rb**
- `ZipUnicodeFileNamesAndComments#test_unicode_comment:`
- `ZipUnicodeFileNamesAndComments#test_unicode_file_name:`

