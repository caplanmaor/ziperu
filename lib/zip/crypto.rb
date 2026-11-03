# frozen_string_literal: true

module Zip
  # The decrypter objects rubyzip's API passes around (`decrypter:`
  # keyword). The Rust core does the actual ZipCrypto/AES work, so these are
  # just typed password holders.
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
end
