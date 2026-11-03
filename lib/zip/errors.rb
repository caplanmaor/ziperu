# frozen_string_literal: true

# The full rubyzip 3.x exception hierarchy. The Rust core looks these up by
# name, so every class here must exist before the native extension raises.
module Zip
  class Error < StandardError; end
  class EntryExistsError < Error; end
  class DestinationExistsError < Error; end
  class CompressionMethodError < Error; end
  class EntryNameError < Error; end
  class EntrySizeError < Error; end
  class InternalError < Error; end
  class GPFBit3Error < Error; end
  class DecompressionError < Error; end
  class SplitArchiveError < Error; end
  class StreamingError < Error; end
end
