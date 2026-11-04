# frozen_string_literal: true

require 'pathname'

module Zip
  # Zip::Entry represents an entry in a Zip archive. The public surface
  # (constructor, accessors, `time`, `ftype`, `==`) matches rubyzip's; entries
  # read from an archive are built from the Hash the native core returns and
  # consult the archive by index only for bytes.
  class Entry
    include Dirtyable

    # Constant used to specify that the entry is stored (i.e., not compressed).
    STORED   = ::Zip::COMPRESSION_METHOD_STORE

    # Constant used to specify that the entry is deflated (i.e., compressed).
    DEFLATED = ::Zip::COMPRESSION_METHOD_DEFLATE

    # Language encoding flag (EFS) bit
    EFS = 0b100000000000 # :nodoc:

    attr_accessor :comment, :compressed_size, :follow_symlinks, :name,
                  :restore_ownership, :restore_permissions, :restore_times,
                  :unix_gid, :unix_perms, :unix_uid

    attr_accessor :crc, :external_file_attributes, :fstype, :gp_flags,
                  :internal_file_attributes, :local_header_offset # :nodoc:

    attr_reader :extra, :compression_level, :filepath # :nodoc:

    attr_writer :size # :nodoc:

    # Index of the entry in the archive's central directory, or nil for an
    # entry that is not (yet) in an archive.
    attr_reader :index # :nodoc:

    mark_dirty :comment=, :compressed_size=, :external_file_attributes=,
               :fstype=, :gp_flags=, :name=, :size=,
               :unix_gid=, :unix_perms=, :unix_uid=

    # Create a new Zip::Entry.
    def initialize(
      zipfile = '', name = '',
      comment: '', size: nil, compressed_size: 0, crc: 0,
      compression_method: DEFLATED,
      compression_level: ::Zip.default_compression,
      time: ::Zip::DOSTime.now, extra: ::Zip::ExtraField.new
    )
      super()
      @name = name
      check_name(@name)

      set_default_vars_values
      @fstype = ::Zip::RUNNING_ON_WINDOWS ? ::Zip::FSTYPE_FAT : ::Zip::FSTYPE_UNIX

      @zipfile            = zipfile
      @archive            = nil
      @index              = nil
      @comment            = comment || ''
      @compression_method = compression_method || DEFLATED
      @compression_level  = compression_level || ::Zip.default_compression
      @compressed_size    = compressed_size || 0
      @crc                = crc || 0
      @size               = size
      @time               = case time
                            when ::Zip::DOSTime
                              time
                            when Time
                              ::Zip::DOSTime.from_time(time)
                            else
                              ::Zip::DOSTime.now
                            end
      @extra              =
        extra.kind_of?(ExtraField) ? extra : ExtraField.new(extra.to_s)
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

    # Always false for entries read by this gem: sizes come from the central
    # directory, so reading never depends on the local header.
    def incomplete? # :nodoc:
      false
    end

    # The uncompressed size of the entry.
    def size
      @size || 0
    end

    # Get a timestamp component of this entry. Returns modification time by
    # default.
    def time(component: :mtime)
      time =
        if @extra[:universaltime]
          @extra[:universaltime].send(component)
        elsif @extra[:ntfs]
          @extra[:ntfs].send(component)
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
      unless @extra.member?(:universaltime) || @extra.member?(:ntfs)
        @extra.create(:universaltime)
      end

      value = DOSTime.from_time(value)
      comp = "#{component}=" unless component.to_s.end_with?('=')
      (@extra[:universaltime] || @extra[:ntfs]).send(comp, value)
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
      @extra.member?(:universaltime) || @extra.member?(:ntfs)
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
      !@extra[:zip64].nil?
    end

    def aes?
      !@extra[:aes].nil?
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

    # Returns an IO like object for the given ZipEntry.
    # Optional decrypter can be provided for an encrypted entry
    def get_input_stream(decrypter: nil, &block)
      if ftype == :directory
        yield ::Zip::NullInputStream if block
        return ::Zip::NullInputStream
      end

      raise Error, "entry '#{@name}' is not in an archive" if @archive.nil?

      zis = ::Zip::InputStream.new(@archive, offset: @local_header_offset, decrypter: decrypter)
      zis.get_next_stream_entry(self)
      return zis unless block

      begin
        yield zis
      ensure
        zis.close
      end
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
      if ::Zip.unicode_names
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
      @size = meta[:size]
      @compressed_size = meta[:compressed_size]
      @crc = meta[:crc]
      @compression_method = meta[:compression_method]
      @compression_level = ::Zip.default_compression
      @gp_flags = meta[:flags]
      @fstype = meta[:fstype]
      @version = meta[:version_made_by]
      @external_file_attributes = meta[:external_attributes]
      @unix_perms = meta[:unix_mode] & 0o7777 if meta[:unix_mode]
      @time = DOSTime.parse_binary_dos_format(meta[:dos_date], meta[:dos_time])
      @comment = meta[:comment].dup.force_encoding(Encoding::UTF_8)
      @extra = ExtraField.new(meta[:extra])
      @local_header_offset = meta[:header_offset]
      @data_offset = meta[:data_offset]
      set_ftype_from_c_dir_entry
    end

    def set_ftype_from_c_dir_entry # :nodoc:
      @ftype = case @fstype
               when ::Zip::FSTYPE_UNIX
                 @unix_perms = (@external_file_attributes >> 16) & 0o7777
                 case (@external_file_attributes >> 28)
                 when ::Zip::FILE_TYPE_DIR
                   :directory
                 when ::Zip::FILE_TYPE_FILE
                   :file
                 when ::Zip::FILE_TYPE_SYMLINK
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
