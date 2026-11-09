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

    # Two more methods the native writer can produce. rubyzip cannot read
    # either, nor can Windows Explorer or Java; 7-Zip, Info-ZIP and
    # libarchive can.
    BZIP2 = ::Ziperu::COMPRESSION_METHOD_BZIP2
    ZSTD = ::Ziperu::COMPRESSION_METHOD_ZSTD

    # Language encoding flag (EFS) bit
    EFS = 0b100000000000 # :nodoc:

    # Compression level flags (bits 1 and 2 of the gp flags).
    COMPRESSION_LEVEL_SUPERFAST_GPFLAG = 0b110 # :nodoc:
    COMPRESSION_LEVEL_FAST_GPFLAG = 0b100      # :nodoc:
    COMPRESSION_LEVEL_MAX_GPFLAG = 0b010       # :nodoc:

    attr_accessor :compressed_size, :follow_symlinks,
                  :restore_ownership, :restore_permissions, :restore_times,
                  :unix_gid, :unix_perms, :unix_uid
    attr_reader :comment, :name

    attr_accessor :crc, :external_file_attributes, :fstype, :gp_flags,
                  :internal_file_attributes, :local_header_offset # :nodoc:

    attr_reader :compression_level, :filepath, :source_io # :nodoc:

    # Whether the data is still outside the archive: a file on disk or an
    # IO given to `add`, to be streamed in when the archive is written.
    # Until then the entry reads and extracts from that source.
    def pending_data? # :nodoc:
      !@filepath.nil? || !@source_io.nil?
    end

    # Whether the entry's bytes are those of the native archive `native`:
    # it was read from it and its data was not replaced since.
    def backed_by?(native) # :nodoc:
      return false if pending_data?

      # `archive`, not `@archive`: it reopens the archive the owning
      # Ziperu::File released on close, as rubyzip lets entries be read then.
      current = archive
      !current.nil? && current.equal?(native)
    end

    # The entry's extra fields. For an entry read from an archive, the
    # local header's fields (which is where Info-ZIP unix uid/gid and the
    # extended timestamp's atime/ctime live) are merged in on first use,
    # rather than by seeking to every local header when the archive opens.
    def extra
      if @archive && !@local_extra_merged
        @local_extra_merged = true
        local = @index ? archive.local_extra(@index) : archive.local_extra_at(@local_header_offset)
        parsed_extra.merge(local, local: true)
        # Edits made through this object (`extra.merge`, `extra.delete`)
        # leave no other trace; the bytes are compared at commit.
        @extra_snapshot = extra_bytes
      end
      parsed_extra
    end

    # The central directory's extra fields, parsed on first use: most
    # entries of a large archive are only ever listed.
    def parsed_extra
      @extra ||= ExtraField.new(@extra_raw)
    end
    private :parsed_extra

    # Whether the extra fields differ from what the archive holds. Such an
    # edit is written whenever the archive is next committed, but does not
    # call for a commit by itself, as in rubyzip: `FileSystem#chown` edits
    # them in place and rubyzip's own tests count on `close` leaving the
    # archive alone after it.
    def extra_changed? # :nodoc:
      !@extra_snapshot.nil? && @extra_snapshot != extra_bytes
    end

    def extra_bytes # :nodoc:
      [parsed_extra.to_local_bin.b, parsed_extra.to_c_dir_bin.b]
    end

    # The native archive this entry was read from, reopened if the owning
    # Ziperu::File has released it (rubyzip lets entries be read after `close`).
    def archive # :nodoc:
      if @archive&.closed? && @zipfile.kind_of?(::Ziperu::File)
        reopened = @zipfile.native_archive
        unless still_at_place?(reopened)
          where = @index ? "at index #{@index} of" : 'in'
          raise Error, "entry '#{@original_name}' is no longer #{where} #{@zipfile.name}"
        end

        @archive = reopened
      end
      @archive
    end

    attr_writer :size # :nodoc:

    # Index of the entry in the archive's central directory, or nil for an
    # entry that is not (yet) in an archive, or that the native core cannot
    # address by index: one of several records under the same name, which
    # is read from its local header offset instead.
    attr_reader :index # :nodoc:

    # Validated here rather than when the archive is written, so a bad
    # value fails at the call site (rubyzip writes a corrupt header).
    def name=(name)
      name = name.to_s
      check_name(name)
      @name = name
    end

    def comment=(comment)
      comment = comment.to_s
      if comment.bytesize > 0xFFFF
        raise Error, "entry comment is #{comment.bytesize} bytes; the limit is 65535"
      end

      @comment = comment
    end

    mark_dirty :comment=, :compressed_size=, :external_file_attributes=,
               :fstype=, :gp_flags=, :name=, :size=,
               :unix_gid=, :unix_perms=, :unix_uid=

    # Create a new Ziperu::Entry.
    def initialize(
      zipfile = '', name = '', *legacy,
      comment: '', size: nil, compressed_size: 0, crc: 0,
      compression_method: DEFLATED,
      compression_level: ::Ziperu.default_compression,
      time: nil, extra: ::Ziperu::ExtraField.new
    )
      super()
      # rubyzip 2.x's positional form.
      given = Compat.positional(
        legacy, %i[comment extra compressed_size crc compression_method size time],
        comment: comment, extra: extra, compressed_size: compressed_size, crc: crc,
        compression_method: compression_method, size: size, time: time
      )
      comment, extra, compressed_size, crc, compression_method, size, time =
        given.values_at(:comment, :extra, :compressed_size, :crc, :compression_method, :size, :time)
      @name = name
      check_name(@name)

      set_default_vars_values
      @fstype = ::Ziperu::RUNNING_ON_WINDOWS && !::Ziperu.source_date_epoch ? ::Ziperu::FSTYPE_FAT : ::Ziperu::FSTYPE_UNIX

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
                              ::Ziperu.default_entry_time
                            end
      @extra              =
        extra.kind_of?(ExtraField) ? extra : ExtraField.new(extra.to_s)

      set_compression_level_flags
    end

    # Build an entry from the metadata Hash the native core produces for
    # one central-directory record.
    #
    # @api private
    def self.from_meta(archive, meta, zipfile = nil, metadata_encoding: nil)
      entry = allocate
      entry.send(:init_from_meta, archive, meta, zipfile, metadata_encoding)
      entry
    end

    # Is this entry encrypted?
    def encrypted?
      gp_flags & 1 == 1
    end

    # Encrypted with the traditional PKWARE cipher (anything but AES).
    def zipcrypto? # :nodoc:
      encrypted? && !aes?
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

      time || (stored_time if component == :mtime)
    end

    # The DOS timestamp from the central directory, parsed on first use.
    # Like rubyzip, an unparseable one is reported (when
    # `Ziperu.warn_invalid_date` is set) and the entry keeps "now".
    def stored_time
      return @time if @time || @dos_date.nil?

      @time = ::Ziperu::DOSTime.parse_binary_dos_format(@dos_date, @dos_time)
    rescue ArgumentError
      warn 'WARNING: invalid date/time in zip entry.' if ::Ziperu.warn_invalid_date
      @time = ::Ziperu::DOSTime.now
    end
    private :stored_time

    alias mtime time

    def atime
      time(component: :atime)
    end

    def ctime
      time(component: :ctime)
    end

    def time=(value, component: :mtime)
      mark_dirty!(:time=)
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

    # What the entry came to once written: the stream's `close` fills these
    # in so that a manifest built from the entries just written is right.
    def written_as(header_offset, size, compressed_size, crc) # :nodoc:
      @local_header_offset = header_offset
      @size = size
      @compressed_size = compressed_size
      @crc = crc
    end

    # Entries serialize without their archive handle; a loaded one can be
    # inspected but not read.
    def marshal_dump # :nodoc:
      instance_variables.each_with_object({}) do |ivar, h|
        next if ivar == :@archive
        next if ivar == :@zipfile && @zipfile.kind_of?(::Ziperu::File)

        h[ivar] = instance_variable_get(ivar)
      end
    end

    def marshal_load(ivars) # :nodoc:
      ivars.each { |ivar, value| instance_variable_set(ivar, value) }
      @archive = nil
      @zipfile = nil unless instance_variable_defined?(:@zipfile)
    end

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
    #
    # A symlink entry is skipped with a warning unless `symlinks: :create`,
    # which creates it only when its target resolves to a path inside
    # `destination_directory`.
    #
    # `on_exists:` says what to do with a file already at the path:
    # `:raise` (`Ziperu::DestinationExistsError`), `:overwrite` or `:skip`.
    # Without it the block decides, as in rubyzip (true to overwrite), and
    # without a block `Ziperu.on_exists_proc` does.
    def extract(entry_path = @name, destination_directory: '.',
                create_parent_directories: false, symlinks: :skip, on_exists: nil, &block)
      dest_dir = ::File.absolute_path(destination_directory || '.')
      extract_path = ::File.absolute_path(::File.join(dest_dir, entry_path))

      unless extract_path.start_with?(dest_dir + ::File::SEPARATOR) || dest_dir == ::File::SEPARATOR
        warn "WARNING: skipped extracting '#{@name}' to '#{extract_path}' as unsafe."
        return self
      end

      block ||= Entry.on_exists_block(on_exists)

      raise "unknown file type #{inspect}" unless directory? || file? || symlink?

      ::FileUtils.mkdir_p(::File.dirname(extract_path)) if create_parent_directories && !directory?

      if symlink?
        create_symlink(extract_path, dest_dir, symlinks, &block)
      else
        __send__(:"create_#{ftype}", extract_path, &block)
      end
      self
    end

    # The block `extract` consults about a path already taken, for an
    # `on_exists:` policy: it returns true to overwrite, false to raise,
    # `:skip` to leave the path alone.
    def self.on_exists_block(policy) # :nodoc:
      case policy
      when nil then proc { ::Ziperu.on_exists_proc }
      when :raise then proc { false }
      when :overwrite then proc { true }
      when :skip then proc { :skip }
      else raise ArgumentError, "on_exists: takes :raise, :overwrite or :skip, not #{policy.inspect}"
      end
    end

    # The native extractor's code for the policy; nil when a block decides.
    def self.on_exists_code(policy) # :nodoc:
      { raise: 0, overwrite: 1, skip: 2 }.fetch(policy) do
        raise ArgumentError, "on_exists: takes :raise, :overwrite or :skip, not #{policy.inspect}"
      end
    end

    # Where a symlink entry points: the link on disk for one being added,
    # the stored content for one read from an archive.
    def symlink_target # :nodoc:
      return ::File.readlink(@filepath) if @filepath

      get_raw_input_string
    end

    # Returns an IO like object for the given ZipEntry.
    # Optional decrypter can be provided for an encrypted entry
    # Warning: may behave weird with symlinks.
    def get_input_stream(decrypter: nil, &block)
      return open_pending_data(&block) if pending_data? && ftype != :directory

      open_input_stream(decrypter: decrypter || default_decrypter, &block)
    end

    # An IO over the data of an entry not yet in the archive (see
    # `pending_data?`): the file on disk, the link's target, or the IO
    # given to `add`, read from the top (a pipe or socket cannot be
    # rewound and is read once).
    def open_pending_data(&block)
      io =
        if @source_io
          @source_io.rewind if ::Ziperu::IOExtras.seekable?(@source_io)
          @source_io
        elsif ftype == :symlink
          ::StringIO.new(::File.readlink(@filepath))
        else
          return ::File.open(@filepath, 'rb', &block)
        end
      block ? yield(io) : io
    end
    private :open_pending_data

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

    # `add` from an IO rather than a path: the data is streamed from the
    # object when the archive is written, so it stays open until then.
    def gather_fileinfo_from_io(io) # :nodoc:
      if name_is_directory?
        raise ArgumentError, "entry name '#{@name}' indicates a directory entry, but an IO was given"
      end

      @ftype = :file
      @source_io = io
      @size = io.size if io.respond_to?(:size) && !io.size.nil?
      @time = ::Ziperu.default_entry_time
    end

    # The decrypter for this entry when the owning `Ziperu::File` was
    # opened with a password; nil otherwise, or for a plain entry.
    def default_decrypter # :nodoc:
      return unless encrypted? && @zipfile.kind_of?(::Ziperu::File) && (pw = @zipfile.password)

      aes? ? AESDecrypter.new(pw) : TraditionalDecrypter.new(pw)
    end

    # Writes this entry (header and data) to an OutputStream. An entry read
    # from an archive is copied without recompression when it is unchanged,
    # or when its only change is one the native raw copy can carry: a new
    # name, or new permissions. Any other edit (comment, time, extra
    # fields, several at once) is written by re-streaming the data under a
    # fresh header, as rubyzip's rewrite of every header would. Entries
    # that cannot be re-streamed (encrypted, or in a method the writer
    # lacks) fall back to the raw copy, so only the rename or the
    # permissions persist for them.
    def write_to_zip_output_stream(zip_output_stream) # :nodoc:
      case write_plan
      when :header
        # No data to stream: a symlink's target goes into the header call.
        zip_output_stream.put_next_entry(self)
      when :restream
        zip_output_stream.put_next_entry(self)
        get_input_stream do |is|
          ::Ziperu::IOExtras.copy_stream(zip_output_stream, is)
        end
      when :copy_encrypted
        zip_output_stream.copy_encrypted_entry(self)
      else
        renamed = @name.b != @original_name.b.tr('\\', '/')
        zip_output_stream.copy_raw_entry(self, (@name if renamed), touch: dirty? && !renamed)
      end
    end

    # How the entry reaches an output stream: `:header` for a directory or
    # a symlink (nothing to stream), `:restream` to decompress and write
    # afresh (a new entry, or one edited beyond what a raw copy carries),
    # `:copy_encrypted` for a ZipCrypto entry copied byte for byte under
    # its own headers, `:copy_raw` otherwise. Raises, with the reason, for
    # an entry that would have to be restreamed but cannot be (encrypted,
    # or a compression method the writer lacks).
    def write_plan # :nodoc:
      # A symlink's target goes into the header call, whether the link is
      # new or a copy that has to be written afresh (an edit, or extra
      # fields the raw copy would lose).
      return :header if ftype == :directory || (ftype == :symlink && (@filepath || needs_restream?))
      return :restream if pending_data?

      if changed? || @index.nil? || loses_fields_on_raw_copy?
        check_restreamable!
        return :restream
      end
      zipcrypto? ? :copy_encrypted : :copy_raw
    end

    # What `FileSystem#chmod` sets, and what a touch on the raw copy writes.
    PERMISSION_FIELDS = %i[unix_perms= external_file_attributes= fstype=].freeze # :nodoc:

    # Extra fields the native raw copy does not carry over intact: it
    # re-emits the central directory's form of each field in both headers,
    # which drops the extended timestamp and NTFS fields and leaves the
    # Info-ZIP unix fields without their uid/gid.
    RAW_COPY_LOSES = %i[universaltime ntfs oldunix iunix].freeze # :nodoc:

    def raw_copy_carries_changes? # :nodoc:
      dirty_fields == [:name=] || (dirty_fields - PERMISSION_FIELDS).empty?
    end

    # Whether the entry has to be decompressed and written afresh rather
    # than copied byte for byte: it was edited beyond what a raw copy
    # carries, or the raw copy would lose extra fields it has.
    def needs_restream? # :nodoc:
      changed? || loses_fields_on_raw_copy?
    end

    # Edited beyond a rename or chmod (which the raw copy carries).
    def changed? # :nodoc:
      (dirty? && !raw_copy_carries_changes?) || extra_changed?
    end

    def loses_fields_on_raw_copy? # :nodoc:
      restreamable? && (extra.keys & RAW_COPY_LOSES).any?
    end

    # Whether the writer can decompress and rewrite the entry: it is not
    # encrypted and its compression method is one the writer has.
    def restreamable? # :nodoc:
      !encrypted? && ::Ziperu::WRITABLE_COMPRESSION_METHODS.include?(compression_method)
    end

    # Raises unless the entry can be restreamed, saying why it must be:
    # edits to an encrypted entry (or one in a method the writer lacks)
    # beyond a rename or chmod raise rather than vanish on commit, and a
    # record the native core cannot address by index (one of several
    # under the same name) has no raw copy to fall back on.
    def check_restreamable!
      return if restreamable?

      kind = encrypted? ? 'an encrypted' : "a #{COMPRESSION_METHODS[compression_method]}"
      if changed?
        changed = dirty_fields.map { |f| f.to_s.chomp('=') }
        changed << 'extra' if extra_changed?
        raise Error, "cannot change #{changed.uniq.join(', ')} of entry '#{@name}': #{kind} entry " \
                     'can only be copied as is (a rename or chmod is fine)'
      end
      raise Error, "cannot write entry '#{@name}': #{kind} entry that shares its name with " \
                   'another record can only be read'
    end
    private :check_restreamable!

    # Whether the reopened archive still holds this entry where it was.
    def still_at_place?(reopened) # :nodoc:
      name = @original_name.b
      return @index < reopened.entry_count && reopened.entry_meta(@index)[:name] == name if @index

      reopened.entries.any? do |meta|
        meta[:index].nil? && meta[:header_offset] == @local_header_offset && meta[:name] == name
      end
    end

    def parent_as_string # :nodoc:
      entry_name  = name.chomp('/')
      slash_index = entry_name.rindex('/')
      slash_index ? entry_name.slice(0, slash_index + 1) : nil
    end

    # Raises unless `owner` (the archive or zipfile this operation needs)
    # is there.
    def check_in_archive!(owner) # :nodoc:
      raise Error, "entry '#{@name}' is not in an archive" if owner.nil?
    end

    def clean_up # :nodoc:
      @dirty = false # Any changes are written at this point.
      @dirty_fields = []
      @extra_snapshot = extra_bytes if @extra_snapshot
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
      @time = ::Ziperu.default_entry_time(stat.mtime)
      return if ::Ziperu::RUNNING_ON_WINDOWS

      @unix_uid   = stat.uid
      @unix_gid   = stat.gid
      @unix_perms = stat.mode & 0o7777
    end

    # Decompressed contents as a binary String, in one native call.
    # Yields (or returns) an IO over the whole archive this entry is in,
    # as rubyzip does: a fresh File for an archive on disk, the buffer
    # itself (rewound) for one in memory.
    def get_raw_input_stream(&block)
      check_in_archive!(@zipfile)

      io = @zipfile.kind_of?(::Ziperu::File) ? @zipfile.name : @zipfile
      return ::File.open(io, 'rb', &block) if io.kind_of?(::String)

      io.rewind if io.respond_to?(:rewind)
      block ? yield(io) : io
    end

    # The size of the entry's local header, so that
    # `local_header_offset + calculate_local_header_size` is where its data
    # starts. rubyzip's internal name; roo seeks to the raw data of an
    # encrypted OpenDocument entry with it. For an entry in an archive the
    # header's own name and extra lengths are used, not the central
    # directory's, which may differ.
    def calculate_local_header_size # :nodoc:
      LOCAL_ENTRY_STATIC_HEADER_LENGTH + name_size + extra_size
    end

    def local_entry_offset # :nodoc:
      local_header_offset + calculate_local_header_size
    end

    def name_size # :nodoc:
      (@original_name || @name).to_s.bytesize
    end

    def extra_size # :nodoc:
      return extra.local_size if @archive.nil? || pending_data?

      (@index ? archive.local_extra(@index) : archive.local_extra_at(@local_header_offset)).bytesize
    end

    def get_raw_input_string # :nodoc:
      return ''.b if ftype == :directory
      check_in_archive!(archive)
      # A record without an index is read through the stream.
      return open_input_stream(enforce_size: true, &:read) if @index.nil?

      archive.read_entry(@index)
    rescue Native::SizeLimitError
      raise EntrySizeError, self
    end

    # The whole entry as a binary String, the way `Ziperu::File#read` reads
    # one: in a single native call when the entry is in an archive and its
    # declared size is to be trusted, through a stream otherwise.
    def read_all # :nodoc:
      if !pending_data? && @archive && !encrypted? && ::Ziperu.validate_entry_sizes
        get_raw_input_string
      else
        get_input_stream(&:read)
      end
    end

    def inspect
      "#<#{self.class.name}:#{name} size=#{size} crc=#{format('%08x', crc)}>"
    end

    private

    # Like get_input_stream, with `enforce_size: false` reading past a
    # declared size that is too small (what rubyzip does when
    # Ziperu.validate_entry_sizes is off) instead of stopping at it.
    def open_input_stream(decrypter: nil, enforce_size: ::Ziperu.validate_entry_sizes)
      if ftype == :directory
        return yield(::Ziperu::NullInputStream) if block_given?

        return ::Ziperu::NullInputStream
      end

      check_in_archive!(@archive)

      # No offset: get_next_stream_entry positions by index, and resolving
      # an offset would walk the whole central directory on every read.
      zis = ::Ziperu::InputStream.new(archive, decrypter: decrypter, enforce_size: enforce_size)
      zis.get_next_stream_entry(self)
      return zis unless block_given?

      begin
        yield zis
      ensure
        zis.close
      end
    end

    def create_file(dest_path, _continue_on_exists_proc = proc { Ziperu.continue_on_exists_proc })
      if ::File.exist?(dest_path)
        decision = yield(self, dest_path)
        return if decision == :skip
        raise DestinationExistsError, dest_path unless decision
      end

      ::File.open(dest_path, 'wb') do |os|
        if pending_data?
          # Added or replaced from disk or an IO and not yet committed:
          # the data is that source's, not the archive's.
          get_input_stream { |is| ::IO.copy_stream(is, os) }
        else
          open_input_stream(enforce_size: Ziperu.validate_entry_sizes, decrypter: default_decrypter) do |is|
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
      end

      set_extra_attributes_on_path(dest_path)
    end

    def create_directory(dest_path)
      return if ::File.directory?(dest_path)

      if ::File.exist?(dest_path)
        decision = block_given? && yield(self, dest_path)
        return if decision == :skip
        raise ::Ziperu::DestinationExistsError, dest_path unless decision

        ::FileUtils.rm_f dest_path
      end

      ::FileUtils.mkdir_p(dest_path)
      set_extra_attributes_on_path(dest_path)
    end

    # Symlinks are never created on extraction: a link pointing outside the
    # destination would let a later entry write through it.
    def create_symlink(dest_path, dest_dir, mode)
      unless mode == :create
        warn "WARNING: skipped symlink '#{dest_path}'."
        return
      end

      target = symlink_target
      resolved = ::File.expand_path(target, ::File.dirname(dest_path))
      unless resolved.start_with?(dest_dir + ::File::SEPARATOR) || resolved == dest_dir
        warn "WARNING: skipped symlink '#{@name}' to '#{target}' as it points outside the destination."
        return
      end

      if ::File.symlink?(dest_path) || ::File.exist?(dest_path)
        decision = yield(self, dest_path)
        return if decision == :skip
        raise DestinationExistsError, dest_path unless decision

        ::File.unlink(dest_path)
      end
      ::File.symlink(target, dest_path)
    rescue NotImplementedError, Errno::EACCES, Errno::EPERM => e
      warn "WARNING: could not create symlink '#{dest_path}': #{e.message}"
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
      @internal_file_attributes = 1
      @external_file_attributes = 0

      @version_needed_to_extract = VERSION_NEEDED_TO_EXTRACT
      @version                   = VERSION_MADE_BY

      @ftype           = nil
      @filepath        = nil
      @source_io       = nil
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

    def init_from_meta(archive, meta, zipfile, metadata_encoding = nil)
      @dirty = false
      set_default_vars_values
      @zipfile = zipfile
      @archive = archive
      @index = meta[:index]
      # Names and comments are the stored bytes. They become UTF-8 when the
      # entry's language-encoding flag says so (rubyzip leaves them binary),
      # or whatever `Ziperu.force_entry_names_encoding` names; otherwise
      # they stay binary. A lookup finds a name in any encoding with the
      # same bytes. The raw name, before separators are normalised, is what
      # the archive knows the entry by.
      @gp_flags = meta[:flags]
      @original_name = meta[:name]
      @name = decode_stored_text(@original_name.dup, metadata_encoding, meta[:extra])
      @name.tr!('\\', '/')
      @size = meta[:size]
      @compressed_size = meta[:compressed_size]
      @crc = meta[:crc]
      @compression_method = meta[:compression_method]
      @compression_level = ::Ziperu.default_compression
      @fstype = meta[:fstype]
      @version = meta[:version_made_by]
      @external_file_attributes = meta[:external_attributes]
      set_time(meta[:dos_date], meta[:dos_time])
      # Most entries have no comment and many no extra fields: those share
      # one empty String rather than carrying their own.
      comment = meta[:comment]
      @comment = comment.empty? ? '' : decode_stored_text(comment, metadata_encoding)
      @extra = nil
      extra = meta[:extra]
      @extra_raw = extra.empty? ? '' : extra
      @local_extra_merged = false
      @local_header_offset = meta[:header_offset]
      set_ftype_from_c_dir_entry
    end

    # Stored bytes as a String in the encoding the entry declares.
    # `encoding` is the archive's `metadata_encoding:`, for a name or
    # comment stored without the language encoding flag: the bytes are
    # read in it and transcoded to UTF-8 (left as bytes when they do not
    # decode). `raw_extra`, for a name, is checked for Info-ZIP's Unicode
    # Path field first, which carries the UTF-8 name outright.
    def decode_stored_text(text, encoding = nil, raw_extra = nil) # :nodoc:
      forced = ::Ziperu.force_entry_names_encoding
      if forced
        text.force_encoding(forced)
      elsif (@gp_flags & EFS).nonzero?
        text.force_encoding(::Encoding::UTF_8)
        text.force_encoding(::Encoding::BINARY) unless text.valid_encoding?
      elsif raw_extra && (utf8 = unicode_path_name(raw_extra, text))
        return utf8
      elsif encoding
        return transcode(text, encoding)
      end
      text
    end

    # The name the Unicode Path extra field carries for `stored`, if there
    # is one and it is for this name (its CRC matches).
    def unicode_path_name(raw_extra, stored)
      return unless raw_extra.include?(ExtraField::UnicodePath::HEADER_ID)

      field = parsed_extra_from(raw_extra)[:unicodepath]
      field.name.dup if field&.for?(stored)
    end

    # Parses the central directory's extra fields now rather than on first
    # use (the parse is needed for the name).
    def parsed_extra_from(raw_extra)
      @extra ||= ExtraField.new(raw_extra)
    end

    def transcode(text, encoding)
      text.force_encoding(encoding).encode(::Encoding::UTF_8)
    rescue ::EncodingError, ::ArgumentError
      text.force_encoding(::Encoding::BINARY)
    end

    # Keeps the DOS timestamp as read; `stored_time` parses it when asked.
    # With `Ziperu.warn_invalid_date` set, a timestamp whose fields are out
    # of range is parsed here instead, so that the warning comes when the
    # archive is opened, as rubyzip's does.
    def set_time(binary_dos_date, binary_dos_time)
      @time = nil
      @dos_date = binary_dos_date
      @dos_time = binary_dos_time
      return unless ::Ziperu.warn_invalid_date

      stored_time unless dos_fields_in_range?(binary_dos_date, binary_dos_time)
    end

    # The cheap check: every field within the range `Time.local` accepts.
    # (A day past the month's end is accepted and rolled over, as rubyzip
    # does.)
    def dos_fields_in_range?(date, time)
      ((date >> 5) & 0xF).between?(1, 12) && (date & 0x1F) >= 1 &&
        (time >> 11) <= 23 && ((time >> 5) & 0x3F) <= 59 && (time & 0x1F) <= 29
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
                 # Not a Unix host, so rubyzip ignores the high attribute
                 # bits. The native writer stamps the host of the machine it
                 # runs on, so archives written here on Windows would lose
                 # their permissions on reread; a non-zero mode is kept.
                 perms = (@external_file_attributes >> 16) & 0o7777
                 @unix_perms = perms unless perms.zero?
                 name_is_directory? ? :directory : :file
               end
    end
  end
end
