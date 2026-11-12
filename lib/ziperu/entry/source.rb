# frozen_string_literal: true

module Ziperu
  class Entry
    # Where an entry's data is. An entry has exactly one source at a time:
    #
    #   None     no data of its own: an entry made with `Entry.new`, whose
    #            data is written to the output stream after its header
    #   Archive  a record of an archive that is open (or can be reopened)
    #   Path     a file, directory or link on disk, given to `add`
    #   IO       an IO given to `add`
    #
    # Path and IO are "pending": the data is still outside the archive and
    # is streamed in when the archive is written. A pending source that
    # replaced an archive record keeps it as `stored`, since the entry's
    # header fields still come from there until the commit.
    #
    # Every source answers the same questions, so `Entry` asks instead of
    # branching on which instance variables happen to be set. A new kind of
    # source (a remote object, say) is one more class here.
    module Source # :nodoc: all
      # What a source without the thing asked for answers.
      module Defaults
        def pending?
          false
        end

        # The archive record behind the entry, or nil.
        def stored
          nil
        end

        def stored?
          !stored.nil?
        end

        def path
          nil
        end

        def io
          nil
        end

        # The record's index in the central directory, or nil.
        def index
          stored&.index
        end

        # The native archive holding the record, or nil.
        def native(offset)
          stored&.native(offset)
        end

        # The record's local-header extra fields, as stored.
        def local_extra(offset)
          stored.local_extra(offset)
        end

        # The source as it survives Marshal: without handles.
        def detached
          self
        end
      end

      class None
        include Defaults
      end

      NONE = None.new.freeze

      # A record of `native`, the archive `owner` (a Ziperu::File, or nil
      # for an entry read through an InputStream) has open. `index` is nil
      # for a record the native core cannot address by index (one of
      # several under the same name), which is found by its offset.
      class Archive
        include Defaults

        attr_reader :index

        def initialize(native, owner, index, raw_name)
          @native = native
          @owner = owner
          @index = index
          @raw_name = raw_name
        end

        def stored
          self
        end

        # The native archive, reopened if the owning Ziperu::File released
        # it on close: rubyzip lets entries be read after `close`.
        def native(offset)
          if @native.closed? && @owner.kind_of?(::Ziperu::File)
            reopened = @owner.native_archive
            unless still_at_place?(reopened, offset)
              where = @index ? "at index #{@index} of" : 'in'
              raise EntryMovedError, "entry '#{@raw_name}' is no longer #{where} #{@owner.name}"
            end

            @native = reopened
          end
          @native
        end

        def local_extra(offset)
          archive = native(offset)
          @index ? archive.local_extra(@index) : archive.local_extra_at(offset)
        end

        # Moves the record to `native`, which holds it at the same index:
        # the archive reopened after entries were appended to it.
        def rebind(native)
          @native = native
        end

        def detached
          NONE
        end

        private

        # Whether the reopened archive still holds this record where it was.
        def still_at_place?(reopened, offset)
          name = @raw_name.b
          return @index < reopened.entry_count && reopened.entry_meta(@index)[:name] == name if @index

          reopened.entries.any? do |meta|
            meta[:index].nil? && meta[:header_offset] == offset && meta[:name] == name
          end
        end
      end

      # Data still outside the archive.
      class Pending
        include Defaults

        attr_reader :stored

        def initialize(stored = nil)
          @stored = stored
        end

        def pending?
          true
        end
      end

      class Path < Pending
        attr_reader :path

        def initialize(path, stored = nil)
          super(stored)
          @path = path
        end

        # An IO over the file, or over the link's target for a symlink.
        def open(ftype, &block)
          return ::File.open(@path, 'rb', &block) unless ftype == :symlink

          io = ::StringIO.new(::File.readlink(@path))
          block ? yield(io) : io
        end

        def detached
          stored ? self.class.new(@path) : self
        end
      end

      class IO < Pending
        attr_reader :io

        def initialize(io, stored = nil)
          super(stored)
          @io = io
        end

        # The IO itself, from the top (a pipe or socket cannot be rewound
        # and is read once).
        def open(_ftype)
          @io.rewind if ::Ziperu::IOExtras.seekable?(@io)
          block_given? ? yield(@io) : @io
        end

        def detached
          stored ? self.class.new(@io) : self
        end
      end
    end
  end
end
