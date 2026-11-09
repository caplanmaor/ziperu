# frozen_string_literal: true

module Ziperu
  # rubyzip 2.x's positional call forms, accepted alongside the 3.x
  # keywords. `Zip::VERSION` is ziperu's own, so a library that branches on
  # it takes its 2.x path; every form that 3.0 replaced with keywords goes
  # through here (see docs/migrating.md for the list).
  module Compat # :nodoc:
    class << self
      # Merges the positional arguments `legacy`, given in rubyzip 2.x's
      # parameter order `keys`, into `kwargs`. A positional value wins over
      # the keyword; a positional nil means "not given", as it did in 2.x.
      def positional(legacy, keys, kwargs)
        return kwargs if legacy.empty?

        given = keys.first(legacy.size).zip(legacy).to_h.compact
        kwargs.merge(given)
      end
    end
  end
end
