# frozen_string_literal: true

require 'zlib'

module Ziperu
  # Info-ZIP's Unicode Path extra field (0x7075): the entry's name in
  # UTF-8, for an archive whose header carries the name in another
  # encoding (one without the language encoding flag), with a CRC-32 of
  # the header's name so a reader can tell when a rename has left the two
  # apart. Info-ZIP, 7-Zip and libarchive honour it.
  class ExtraField::UnicodePath < ExtraField::Generic # :nodoc:
    HEADER_ID = 'up'
    register_map

    attr_accessor :name, :crc

    def initialize(binstr = nil)
      @name = nil
      @crc = nil
      merge(binstr) unless binstr.nil?
    end

    def merge(binstr)
      return if binstr.empty?

      size, content = initial_parse(binstr)
      return if !size || size < 5

      version, crc = content.unpack('CV')
      return unless version == 1

      @crc = crc
      @name = content.byteslice(5, size - 5).force_encoding(::Encoding::UTF_8)
    end

    # Whether this field describes the header name `stored`.
    def for?(stored)
      !@name.nil? && @name.valid_encoding? && @crc == Zlib.crc32(stored.b)
    end

    def ==(other)
      other.kind_of?(self.class) && name == other.name && crc == other.crc
    end

    def pack_for_local
      [1, @crc.to_i].pack('CV') + @name.to_s.b
    end

    alias pack_for_c_dir pack_for_local
  end
end
