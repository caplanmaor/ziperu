# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors).

module Zip
  class StreamableDirectory < Entry # :nodoc:
    def initialize(zipfile, entry, src_path = nil, permission = nil)
      super(zipfile, entry)

      @ftype = :directory
      entry.get_extra_attributes_from_path(src_path) if src_path
      @unix_perms = permission if permission
    end
  end
end
