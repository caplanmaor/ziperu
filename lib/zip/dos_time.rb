# frozen_string_literal: true

module Zip
  # A Time that knows how to round-trip the MS-DOS date/time packed into a
  # zip header. Mirrors rubyzip's class so `entry.time` behaves identically.
  class DOSTime < Time
    def dos_equals(other)
      to_i / 2 == other.to_i / 2
    end

    def to_binary_dos_time
      (sec / 2) + (min << 5) + (hour << 11)
    end

    def to_binary_dos_date
      day + (month << 5) + ((year - 1980) << 9)
    end

    def self.parse_binary_dos_format(bin_dos_date, bin_dos_time)
      second = 2 * (0b11111 & bin_dos_time)
      minute = (0b11111100000 & bin_dos_time) >> 5
      hour   = (0b1111100000000000 & bin_dos_time) >> 11
      day    = (0b11111 & bin_dos_date)
      month  = (0b111100000 & bin_dos_date) >> 5
      year   = ((0b1111111000000000 & bin_dos_date) >> 9) + 1980
      local(year, month, day, hour, minute, second)
    rescue ArgumentError
      # Zero or garbage fields; rubyzip falls back to the epoch too.
      local(1980, 1, 1, 0, 0, 0)
    end

    def self.from_time(time)
      local(time.year, time.month, time.day, time.hour, time.min, time.sec)
    end
  end
end
