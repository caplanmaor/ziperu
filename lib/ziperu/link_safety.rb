# frozen_string_literal: true

module Ziperu
  # The checks made before a link is created under a destination, and
  # before anything is put where a link on disk could redirect it. Shared
  # by zip and tar extraction.
  module LinkSafety # :nodoc:
    # Why a link to `target` at `dest_path` must not be made under
    # `dest_dir`, or nil when it may.
    def symlink_refusal(target, dest_path, dest_dir)
      resolved = ::File.expand_path(target, ::File.dirname(dest_path))
      unless resolved.start_with?(dest_dir + ::File::SEPARATOR) || resolved == dest_dir
        return 'it points outside the destination'
      end

      # The check above is lexical. A `..` after a name is not: through a
      # link, `b/..` is the parent of wherever `b` points, so `c -> b/..`
      # with `b -> .` is really the destination's parent. Leading `..`s
      # only climb real directories (the ones on the way were checked).
      parts = target.split(%r{[/\\]}).reject { |part| part.empty? || part == '.' }
      "a '..' after a name could lead through a link" if parts.drop_while { |part| part == '..' }.include?('..')
    end

    # The first link already on disk below `dest_dir` on the way to `path`,
    # and at `path` itself when `leaf`, or nil. A junction counts (Ruby's
    # lstat reports one as a link). The walk stops at the first component
    # that is missing or not a directory: the callers deal with those.
    def link_on_the_way(dest_dir, path, leaf: true)
      parts = path.delete_prefix(dest_dir).split('/').reject(&:empty?)
      parts.pop unless leaf
      walked = dest_dir
      parts.each do |part|
        walked = ::File.join(walked, part)
        stat = ::File.lstat(walked)
        return walked if stat.symlink?
        return nil unless stat.directory?
      rescue Errno::ENOENT, Errno::ENOTDIR
        return nil
      end
      nil
    end
  end
end
