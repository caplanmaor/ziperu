# frozen_string_literal: true

module Zip
  # The encrypter/decrypter objects rubyzip's API passes around
  # (`encrypter:` / `decrypter:` keywords). The Rust core does the actual
  # ZipCrypto/AES work, so these are typed password holders.
  class Decrypter # :nodoc:
    attr_reader :password

    def initialize(password)
      @password = password.to_s
    end
  end

  class TraditionalDecrypter < Decrypter; end

  class AESDecrypter < Decrypter
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

  class NullEncrypter < Encrypter
    def initialize
      super(nil)
    end
  end

  # ZipCrypto. The Rust core only decrypts it (the crate keeps the weak
  # legacy encrypter private), so this can only be used for reading.
  class TraditionalEncrypter < Encrypter
    def native_options # :nodoc:
      raise Error, 'Writing ZipCrypto (traditional) encryption is not supported; use AESEncrypter.'
    end
  end

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
