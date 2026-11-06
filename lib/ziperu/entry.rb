# frozen_string_literal: true

require 'pathname'

module Ziperu
  # Ziperu::Entry represents an entry in a Zip archive. The public surface
  # (constructor, accessors, `time`, `ftype`, `==`) matches rubyzip's; entries
  # read from an archive are built from the Hash the native core returns and
  # consult the archive by index only for bytes.
  class Entry
    include Dirtyable

    # Constant used to specify that the entry is stored (i.e., not compressed).
    STORED   = ::Ziperu::COMPRESSION_METHOD_STORE

    # Constant used to specify that the entry is deflated (i.e., compressed).
    DEFLATED = ::Ziperu::COMPRESSION_METHOD_DEFLATE

    # Language encoding flag (EFS) bit
    EFS = 0b100000000000 # :nodoc:

    # Compression level flags (bits 1 and 2 of the gp flags).
    COMPRESSION_LEVEL_SUPERFAST_GPFLAG = 0b110 # :nodoc:
    COMPRESSION_LEVEL_FAST_GPFLAG = 0b100      # :nodoc:
    COMPRESSION_LEVEL_MAX_GPFLAG = 0b010       # :nodoc:

    attr_accessor :comment, :compressed_size, :follow_symlinks, :name,
                  :restore_ownership, :restore_permissions, :restore_times,
                  :unix_gid, :unix_perms, :unix_uid

    attr_accessor :crc, :external_file_attributes, :fstype, :gp_flags,
                  :internal_file_attributes, :local_header_offset # :nodoc:

    attr_reader :compression_level, :filepath # :nodoc:

    # The entry's extra fields. For an entry read from an archive, the
    # local header's fields (which is where Info-ZIP unix uid/gid and the
    # extended timestamp's atime/ctime live) are merged in on first use,
    # rather than by seeking to every local header when the archive opens.
    def extra
      if @archive && !@local_extra_merged
        @local_extra_merged = true
        @extra.merge(archive.local_extra(@index), local: true)
      end
      @extra
    end

    # The native archive this entry was read from, reopened if the owning
    # Ziperu::File has released it (rubyzip lets entries be read after `close`).
    def archive # :nodoc:
      if @archive&.closed? && @zipfile.kind_of?(::Ziperu::File)
        reopened = @zipfile.native_archive
        if reopened.entry_meta(@index)[:name] != @original_name.b
          raise Error, "entry '#{@original_name}' is no longer at index #{@index} of #{@zipfile.name}"
        end

        @archive = reopened
      end
      @archive
    end

    attr_writer :size # :nodoc:

    # Index of the entry in the archive's central directory, or nil for an
    # entry that is not (yet) in an archive.
    attr_reader :index # :nodoc:

    # The native archive the entry was read from, or nil.

    mark_dirty :comment=, :compressed_size=, :external_file_attributes=,
               :fstype=, :gp_flags=, :name=, :size=,
               :unix_gid=, :unix_perms=, :unix_uid=

    # Create a new Ziperu::Entry.
    def initialize(
      zipfile = '', name = '',
      comment: '', size: nil, compressed_size: 0, crc: 0,
      compression_method: DEFLATED,
      compression_level: ::Ziperu.default_compression,
      time: ::Ziperu::DOSTime.now, extra: ::Ziperu::ExtraField.new
    )
      super()
      @name = name
      check_name(@name)

      set_default_vars_values
      @fstype = ::Ziperu::RUNNING_ON_WINDOWS ? ::Ziperu::FSTYPE_FAT : ::Ziperu::FSTYPE_UNIX

      @zipfile            = zipfile
      @archive            = nil
      @index              = nil
      @original_name      = nil
      @comment            = comment || ''
      @compression_method = compression_method || DEFLATED
      @compression_level  = compression_level || ::Ziperu.default_compression
      @compressed_size    = compressed_size || 0
      @crc                = crc || 0
      @size               = size
      @time               = case time
                            when ::Ziperu::DOSTime
                              time
                            when Time
                              ::Ziperu::DOSTime.from_time(time)
                            else
                              ::Ziperu::DOSTime.now
                            end
      @extra              =
        extra.kind_of?(ExtraField) ? extra : ExtraField.new(extra.to_s)

      set_compression_level_flags
    end

    # Build an entry from the metadata Hash the native core produces for
    # one central-directory record.
    #
    # @api private
    def self.from_meta(archive, meta, zipfile = nil)
      entry = allocate
      entry.send(:init_from_meta, archive, meta, zipfile)
      entry
    end

    # Is this entry encrypted?
    def encrypted?
      gp_flags & 1 == 1
    end

    # Was this entry written in streaming mode with sizes still unknown?
    # Only informational here: reading goes through the central directory,
    # so an incomplete local header does not stop `get_input_stream`.
    def incomplete? # :nodoc:
      (gp_flags & 8 == 8) && (crc == 0 || size == 0 || compressed_size == 0)
    end

    # Was a size given, or is it still unknown (as for an entry that is
    # about to be streamed)? Decides whether a zip64 placeholder is needed.
    def size_known? # :nodoc:
      !@size.nil?
    end

    # The uncompressed size of the entry.
    def size
      @size || 0
    end

    # Get a timestamp component of this entry. Returns modification time by
    # default.
    def time(component: :mtime)
      time =
        if extra[:universaltime]
          extra[:universaltime].send(component)
        elsif extra[:ntfs]
          extra[:ntfs].send(component)
        end

      time || (@time if component == :mtime)
    end

    alias mtime time

    def atime
      time(component: :atime)
    end

    def ctime
      time(component: :ctime)
    end

    def time=(value, component: :mtime)
      @dirty = true
      unless extra.member?(:universaltime) || extra.member?(:ntfs)
        extra.create(:universaltime)
      end

      value = DOSTime.from_time(value)
      comp = "#{component}=" unless component.to_s.end_with?('=')
      (extra[:universaltime] || extra[:ntfs]).send(comp, value)
      @time = value if component == :mtime
    end

    alias mtime= time=

    def atime=(value)
      send(:time=, value, component: :atime)
    end

    def ctime=(value)
      send(:time=, value, component: :ctime)
    end

    # Does this entry return time fields with accurate timezone information?
    def absolute_time?
      extra.member?(:universaltime) || extra.member?(:ntfs)
    end

    # Returns STORED if the entry is a directory or the compression level is 0.
    def compression_method
      return STORED if ftype == :directory || @compression_level == 0

      @compression_method
    end

    def compression_method=(method)
      @dirty = true
      @compression_method = (ftype == :directory ? STORED : method)
    end

    def zip64?
      !extra[:zip64].nil?
    end

    def aes?
      !extra[:aes].nil?
    end

    def file_type_is?(type) # :nodoc:
      ftype == type
    end

    def ftype # :nodoc:
      @ftype ||= name_is_directory? ? :directory : :file
    end

    %w[directory file symlink].each do |k|
      define_method :"#{k}?" do
        file_type_is?(k.to_sym)
      end
    end

    def name_is_directory? # :nodoc:
      @name.end_with?('/')
    end

    # Is the name a relative path, free of `..` patterns that could lead to
    # path traversal attacks? This does NOT handle symlinks.
    def name_safe? # :nodoc:
      cleanpath = Pathname.new(@name).cleanpath
      return false unless cleanpath.relative?

      root = ::File::SEPARATOR
      naive = Regexp.escape(::File.join(root, cleanpath.to_s))
      ::File.absolute_path(cleanpath.to_s, root).match?(/([A-Z]:)?#{naive}/i)
    end

    alias header_offset local_header_offset

    # Offset of the entry's compressed bytes within the archive.
    attr_reader :data_offset # :nodoc:

    def to_s # :nodoc:
      @name
    end

    def ==(other) # :nodoc:
      return false unless other.class == self.class

      %w[compression_method crc compressed_size size name extra filepath time].all? do |k|
        other.__send__(k.to_sym) == __send__(k.to_sym)
      end
    end

    def <=>(other) # :nodoc:
      to_s <=> other.to_s
    end

    # Extracts this entry to a file at `entry_path`, with
    # `destination_directory` as the base location in the filesystem.
    #
    # NB: The caller is responsible for making sure `destination_directory` is
    # safe, if it is passed.
    #
    # `create_parent_directories`, if true, creates any missing intermediate
    # directories for a file entry before writing it. This defaults to
    # false: a missing intermediate directory usually means an earlier
    # entry (e.g. a symlink) was deliberately skipped as unsafe, and letting
    # a later entry silently succeed by re-creating that path as a plain
    # directory would mask that. `File#extract_all` opts into it.
    def extract(entry_path = @name, destination_directory: '.',
                create_parent_directories: false, &block)
      dest_dir = ::File.absolute_path(destination_directory || '.')
      extract_path = ::File.absolute_path(::File.join(dest_dir, entry_path))

      unless extract_path.start_with?(dest_dir + ::File::SEPARATOR) || dest_dir == ::File::SEPARATOR
        warn "WARNING: skipped extracting '#{@name}' to '#{extract_path}' as unsafe."
        return self
      end

      block ||= proc { ::Ziperu.on_exists_proc }

      raise "unknown file type #{inspect}" unless directory? || file? || symlink?

      ::FileUtils.mkdir_p(::File.dirname(extract_path)) if create_parent_directories && file?

      __send__(:"create_#{ftype}", extract_path, &block)
      self
    end

    # Returns an IO like object for the given ZipEntry.
    # Optional decrypter can be provided for an encrypted entry
    # Warning: may behave weird with symlinks.
    def get_input_stream(decrypter: nil, &block)
      return open_input_stream(decrypter: decrypter, &block) if @filepath.nil? || ftype == :directory

      # Not yet in an archive: the data is a file on disk.
      case ftype
      when :file
        ::File.open(@filepath, 'rb', &block)
      when :symlink
        stringio = ::StringIO.new(::File.readlink(@filepath))
        yield(stringio) if block
        stringio
      else
        raise "unknown @file_type #{ftype}"
      end
    end

    def gather_fileinfo_from_srcpath(src_path) # :nodoc:
      stat   = file_stat(src_path)
      @ftype = case stat.ftype
               when 'file'
                 if name_is_directory?
                   raise ArgumentError,
                         "entry name '#{@name}' indicates a directory entry, but " \
                         "'#{src_path}' is not a directory"
                 end
                 :file
               when 'directory'
                 @name += '/' unless name_is_directory?
                 :directory
               when 'link'
                 if name_is_directory?
                   raise ArgumentError,
                         "entry name '#{@name}' indicates a directory entry, but " \
                         "'#{src_path}' is not a directory"
                 end
                 :symlink
               else
                 raise "unknown file type: #{src_path.inspect} #{stat.inspect}"
               end

      @filepath = src_path
      @size = stat.size
      get_extra_attributes_from_path(@filepath)
    end

    # Writes this entry (header and data) to an OutputStream. Entries read
    # from an archive are copied without recompression.
    def write_to_zip_output_stream(zip_output_stream) # :nodoc:
      if ftype == :directory
        zip_output_stream.put_next_entry(self)
      elsif @filepath
        zip_output_stream.put_next_entry(self)
        get_input_stream do |is|
          ::Ziperu::IOExtras.copy_stream(zip_output_stream, is)
        end
      else
        new_name = (@name if @name != @original_name)
        zip_output_stream.copy_raw_entry(self, new_name, touch: dirty?)
      end
    end

    def parent_as_string # :nodoc:
      entry_name  = name.chomp('/')
      slash_index = entry_name.rindex('/')
      slash_index ? entry_name.slice(0, slash_index + 1) : nil
    end

    def clean_up # :nodoc:
      @dirty = false # Any changes are written at this point.
    end

    def file_stat(path) # :nodoc:
      if @follow_symlinks
        ::File.stat(path)
      else
        ::File.lstat(path)
      end
    end

    def get_extra_attributes_from_path(path) # :nodoc:
      stat = file_stat(path)
      @time = DOSTime.from_time(stat.mtime)
      return if ::Ziperu::RUNNING_ON_WINDOWS

      @unix_uid   = stat.uid
      @unix_gid   = stat.gid
      @unix_perms = stat.mode & 0o7777
    end

    # Decompressed contents as a binary String.
    def get_raw_input_string # :nodoc:
      return ''.b if ftype == :directory
      raise Error, "entry '#{@name}' is not in an archive" if @archive.nil?

      @archive.read_entry(@index)
    rescue Native::SizeLimitError
      raise EntrySizeError, self
    end

    def inspect
      "#<#{self.class.name}:#{name} size=#{size} crc=#{format('%08x', crc)}>"
    end

    private

    # Like get_input_stream, with `enforce_size: false` reading past a
    # declared size that is too small (what rubyzip does when
    # Ziperu.validate_entry_sizes is off) instead of stopping at it.
    def open_input_stream(decrypter: nil, enforce_size: true)
      if ftype == :directory
        yield ::Ziperu::NullInputStream if block_given?
        return ::Ziperu::NullInputStream
      end

      raise Error, "entry '#{@name}' is not in an archive" if @archive.nil?

      zis = ::Ziperu::InputStream.new(archive, offset: @local_header_offset, decrypter: decrypter,
                                            enforce_size: enforce_size)
      zis.get_next_stream_entry(self)
      return zis unless block_given?

      begin
        yield zis
      ensure
        zis.close
      end
    end

    def create_file(dest_path, _continue_on_exists_proc = proc { Ziperu.continue_on_exists_proc })
      if ::File.exist?(dest_path) && !yield(self, dest_path)
        raise DestinationExistsError, dest_path
      end

      ::File.open(dest_path, 'wb') do |os|
        open_input_stream(enforce_size: Ziperu.validate_entry_sizes) do |is|
          bytes_written = 0
          while (buf = is.sysread(IOExtras::CHUNK_SIZE))
            os << buf
            bytes_written += buf.bytesize
          end
          # With enforcement on, the native reader has already raised
          # EntrySizeError; without it, warn as rubyzip does.
          warn "WARNING: #{EntrySizeError.new(self).message}" if bytes_written > size
        end
      end

      set_extra_attributes_on_path(dest_path)
    end

    def create_directory(dest_path)
      return if ::File.directory?(dest_path)

      if ::File.exist?(dest_path)
        raise ::Ziperu::DestinationExistsError, dest_path unless block_given? && yield(self, dest_path)

        ::FileUtils.rm_f dest_path
      end

      ::FileUtils.mkdir_p(dest_path)
      set_extra_attributes_on_path(dest_path)
    end

    # Symlinks are never created on extraction: a link pointing outside the
    # destination would let a later entry write through it.
    def create_symlink(dest_path)
      warn "WARNING: skipped symlink '#{dest_path}'."
    end

    def set_unix_attributes_on_path(dest_path) # :nodoc:
      # Ignore setuid/setgid bits by default. Honour if @restore_ownership.
      unix_perms_mask = (@restore_ownership ? 0o7777 : 0o1777)
      if @restore_permissions && @unix_perms
        ::FileUtils.chmod(@unix_perms & unix_perms_mask, dest_path)
      end
      return unless @restore_ownership && @unix_uid && @unix_gid && ::Process.egid == 0

      ::FileUtils.chown(@unix_uid, @unix_gid, dest_path)
    end

    def set_extra_attributes_on_path(dest_path) # :nodoc:
      return unless file? || directory?

      set_unix_attributes_on_path(dest_path) if @fstype == ::Ziperu::FSTYPE_UNIX

      # Restore the timestamp on a file. This will either have come from the
      # original source file that was copied into the archive, or from the
      # creation date of the archive if there was no original source file.
      ::FileUtils.touch(dest_path, mtime: time) if @restore_times
    end

    def set_default_vars_values # :nodoc:
      @local_header_offset      = 0
      @data_offset              = nil
      @internal_file_attributes = 1
      @external_file_attributes = 0

      @version_needed_to_extract = VERSION_NEEDED_TO_EXTRACT
      @version                   = VERSION_MADE_BY

      @ftype           = nil
      @filepath        = nil
      @gp_flags        = 0
      if ::Ziperu.unicode_names
        @gp_flags |= EFS
        @version = 63
      end
      @follow_symlinks = false

      @restore_times       = DEFAULT_RESTORE_OPTIONS[:restore_times]
      @restore_permissions = DEFAULT_RESTORE_OPTIONS[:restore_permissions]
      @restore_ownership   = DEFAULT_RESTORE_OPTIONS[:restore_ownership]
      @unix_uid            = nil
      @unix_gid            = nil
      @unix_perms          = nil
    end

    def check_name(name) # :nodoc:
      raise EntryNameError, name if name.start_with?('/')
      raise EntryNameError if name.length > 65_535
    end

    def init_from_meta(archive, meta, zipfile)
      @dirty = false
      set_default_vars_values
      @zipfile = zipfile
      @archive = archive
      @index = meta[:index]
      @name = meta[:name].dup.force_encoding(Encoding::UTF_8)
      @original_name = @name.dup
      @size = meta[:size]
      @compressed_size = meta[:compressed_size]
      @crc = meta[:crc]
      @compression_method = meta[:compression_method]
      @compression_level = ::Ziperu.default_compression
      @gp_flags = meta[:flags]
      @fstype = meta[:fstype]
      @version = meta[:version_made_by]
      @external_file_attributes = meta[:external_attributes]
      @unix_perms = meta[:unix_mode] & 0o7777 if meta[:unix_mode]
      set_time(meta[:dos_date], meta[:dos_time])
      @comment = meta[:comment].dup.force_encoding(Encoding::UTF_8)
      @extra = ExtraField.new(meta[:extra])
      @local_extra_merged = false
      @local_header_offset = meta[:header_offset]
      @data_offset = meta[:data_offset]
      set_ftype_from_c_dir_entry
    end

    # Like rubyzip, an unparseable DOS timestamp is reported (when
    # `Ziperu.warn_invalid_date` is set) and the entry keeps "now".
    def set_time(binary_dos_date, binary_dos_time)
      @time = ::Ziperu::DOSTime.parse_binary_dos_format(binary_dos_date, binary_dos_time)
    rescue ArgumentError
      @time = ::Ziperu::DOSTime.now
      warn 'WARNING: invalid date/time in zip entry.' if ::Ziperu.warn_invalid_date
    end

    def set_compression_level_flags
      return unless compression_method == DEFLATED

      case @compression_level
      when 1
        @gp_flags |= COMPRESSION_LEVEL_SUPERFAST_GPFLAG
      when 2
        @gp_flags |= COMPRESSION_LEVEL_FAST_GPFLAG
      when 8, 9
        @gp_flags |= COMPRESSION_LEVEL_MAX_GPFLAG
      end
    end

    def set_ftype_from_c_dir_entry # :nodoc:
      @ftype = case @fstype
               when ::Ziperu::FSTYPE_UNIX
                 @unix_perms = (@external_file_attributes >> 16) & 0o7777
                 case (@external_file_attributes >> 28)
                 when ::Ziperu::FILE_TYPE_DIR
                   :directory
                 when ::Ziperu::FILE_TYPE_FILE
                   :file
                 when ::Ziperu::FILE_TYPE_SYMLINK
                   :symlink
                 else
                   name_is_directory? ? :directory : :file
                 end
               else
                 name_is_directory? ? :directory : :file
               end
    end
  end
end
