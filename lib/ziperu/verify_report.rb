# frozen_string_literal: true

module Ziperu
  # What `File#verify(report: true)` found, entry by entry:
  #
  # - `verified`: the entries whose data inflated with the right CRC and
  #   size, in archive order;
  # - `failed`: a Hash of the entries that did not to the exception raised;
  # - `skipped`: a Hash of the entries not checked to why: `:encrypted` (no
  #   password was given) or `:not_written` (added or replaced since the
  #   archive was opened, so not in it yet).
  #
  # Directories have no data and appear in none of them.
  # Not in rubyzip.
  class VerifyReport
    attr_reader :verified, :failed, :skipped

    def initialize # :nodoc:
      @verified = []
      @failed = {}
      @skipped = {}
    end

    # True when every entry with data was checked and passed.
    def ok?
      @failed.empty? && @skipped.empty?
    end

    # True when nothing that was checked failed; skipped entries aside.
    def no_failures?
      @failed.empty?
    end

    def add_verified(entry) # :nodoc:
      @verified << entry
    end

    def add_failed(entry, error) # :nodoc:
      @failed[entry] = error
    end

    def add_skipped(entry, reason) # :nodoc:
      @skipped[entry] = reason
    end

    def freeze
      @verified.freeze
      @failed.freeze
      @skipped.freeze
      super
    end

    # One line: how many were verified, failed and skipped.
    def to_s
      "#{@verified.size} verified, #{@failed.size} failed, #{@skipped.size} skipped"
    end

    def inspect
      "#<#{self.class.name} #{self}>"
    end
  end
end
