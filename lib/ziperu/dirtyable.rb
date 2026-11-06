# frozen_string_literal: true

# Ported from rubyzip (Copyright (C) 2002-2026 the rubyzip authors), with
# the setters that dirtied the object recorded as well as the flag: an
# entry whose only change the native raw copy can carry (a rename, or a
# chmod) need not be recompressed on commit.

module Ziperu
  module Dirtyable # :nodoc:all
    def initialize(dirty_on_create: true)
      @dirty = dirty_on_create
      @dirty_fields = []
    end

    def dirty?
      @dirty
    end

    # The setters called since the object was last clean, as symbols.
    def dirty_fields
      @dirty_fields ||= []
    end

    def mark_dirty!(field)
      @dirty = true
      dirty_fields << field unless dirty_fields.include?(field)
    end

    module ClassMethods # :nodoc:
      def mark_dirty(*symbols) # :nodoc:
        # Move the original method and call it after we've set the dirty flag.
        symbols.each do |symbol|
          orig_name = "orig_#{symbol}"
          alias_method orig_name, symbol

          define_method(symbol) do |param|
            mark_dirty!(symbol)
            send(orig_name, param)
          end
        end
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end
  end
end
