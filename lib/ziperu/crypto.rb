# frozen_string_literal: true

module Ziperu
  # The encrypter/decrypter objects rubyzip's API passes around
  # (`encrypter:` / `decrypter:` keywords). The Rust core does the actual
  # ZipCrypto/AES work, so these are typed password holders.
  class Decrypter # :nodoc:
    attr_reader :password

    def initialize(password)
      @password = password.to_s
    end
  end

  class TraditionalDecrypter < Decrypter; end # :nodoc:

  class AESDecrypter < Decrypter # :nodoc:
    def initialize(password, _strength = nil)
      super(password)
    end
  end

  module AESEncryption # :nodoc:
    STRENGTH_128_BIT = 0x01
    STRENGTH_192_BIT = 0x02
    STRENGTH_256_BIT = 0x03
  end

  class Encrypter # :nodoc:
    attr_reader :password

    def initialize(password)
      @password = password.to_s
    end

    # Options for the native writer.
    def native_options # :nodoc:
      {}
    end
  end

  # No encryption.
  class NullEncrypter < Encrypter
    def initialize
      super(nil)
    end

    # rubyzip's compressors (Deflater, PassThruCompressor) pass their
    # output through the encrypter.
    def encrypt(data) # :nodoc:
      data
    end
  end

  # ZipCrypto, the weak legacy cipher that Windows Explorer and other
  # AES-less tools can open. Entries are written with general purpose bits
  # 0 and 3 set, as rubyzip writes them; only Stored and Deflate entries
  # can be encrypted this way.
  class TraditionalEncrypter < Encrypter
    def native_options # :nodoc:
      { password: @password.b, zipcrypto: true }
    end
  end

  # WinZip AES; 256-bit unless another strength is given.
  class AESEncrypter < Encrypter
    include AESEncryption

    attr_reader :strength

    def initialize(password, strength = STRENGTH_256_BIT)
      super(password)
      @strength = strength
    end

    def native_options # :nodoc:
      { password: @password.b, aes_mode: @strength }
    end
  end
end
