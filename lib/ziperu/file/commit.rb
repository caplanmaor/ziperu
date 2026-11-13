# frozen_string_literal: true

module Ziperu
  # Committing: writing the archive out with its changes, by appending in
  # place, rewriting beside it and renaming over it, or to another path or
  # an IO.
  class File
    # Commits changes made since the previous commit to the zip archive: a
    # new archive is written beside the old one and renamed over it.
    def commit
      return if name.kind_of?(StringIO) || !commit_required?

      appended = write_changes
      # Only now are the changes on disk; until here the entries keep
      # their dirty state so a failed commit can be retried.
      @cdir.each(&:clean_up)
      if @write_to
        # From here on this object works on the archive just written:
        # what it holds now includes the changes, and a later commit
        # updates it rather than starting again from the original (which
        # would drop what this commit wrote).
        @name = @write_to
        @write_to = nil
      end
      initialize_cdir(@name) unless appended && refresh_after_append(appended)
    end

    # Writes the archive out with its changes. Returns the entries added
    # when they were appended in place, nil when the archive was written
    # whole.
    def write_changes
      if @write_to
        # The changes go to a new archive; the one opened is not touched,
        # and keeps being what this object reads. It is written beside
        # its path and renamed into place once complete, so a failure
        # leaves whatever was at the path as it was.
        dirname, basename = ::File.split(@write_to)
        ::Dir::Tmpname.create(basename, dirname) do |tmp_filename|
          write_all_entries(tmp_filename)
          ::File.rename(tmp_filename, @write_to)
        ensure
          FileUtils.rm_f(tmp_filename)
        end
        nil
      elsif (appended = appended_entries)
        # Only additions: they go after the entries already there, which
        # are left untouched (see Ziperu.append_in_place). A failure puts
        # the archive back as it was.
        ::Ziperu::OutputStream.open(@name, append: true, **stream_options) do |zos|
          zos.put_entries(appended, threads: @threads)
        end
        appended
      else
        learn_raw_copy_losses
        on_success_replace do |tmp_file|
          write_all_entries(tmp_file)
          true
        end
        nil
      end
    end
    private :write_changes

    def write_all_entries(target)
      ::Ziperu::OutputStream.open(target, **stream_options) do |zos|
        zos.put_entries(@cdir.writable_entries, threads: @threads)
        zos.comment = comment
      end
    end
    private :write_all_entries

    # Before a rewrite: which entries a raw copy would lose fields of, asked
    # of the native core for all of them at once rather than by reading
    # each one's local header into Ruby (see Entry#loses_fields_on_raw_copy?).
    def learn_raw_copy_losses
      return unless @native

      candidates = @cdir.entries.select do |e|
        e.index && !e.pending_data? && e.backed_by?(@native) && e.restreamable?
      end
      return if candidates.empty?

      lossy = @native.indices_with_extra_fields(candidates.map(&:index), Entry::RAW_COPY_LOSES_IDS)
      lossy = lossy.to_h { |i| [i, true] }
      candidates.each { |e| e.raw_copy_loses = lossy.key?(e.index) }
    rescue Error
      # Only a shortcut: should the archive no longer read as it did (the
      # file changed under it, say), each entry is asked the long way.
      nil
    end
    private :learn_raw_copy_losses

    # After an append: the entries already there are where they were, so
    # they are kept (pointed at the archive reopened) and only the new
    # records are read, rather than every entry built again. False, with
    # nothing changed, when the archive does not hold what was expected;
    # `initialize_cdir` then reads it all.
    def refresh_after_append(appended)
      held = @native.entry_count
      native = InputStream.open_archive(@name, @settings)
      unless native.entry_count == held + appended.size && !native.duplicate_names?
        native.close
        return false
      end

      fresh = native.entry_metas(held, appended.size).map do |meta|
        Entry.from_meta(native, meta, self, metadata_encoding: @metadata_encoding, settings: @settings)
      end
      unless fresh.map { |e| e.name.b } == appended.map { |e| e.name.b }
        native.close
        return false
      end

      kept = @cdir.entries.first(held)
      kept.each { |e| e.rebind_native(native) }
      fresh.each { |e| @cdir << e }
      @native.close
      @native = native
      @dirty = false
      @file_permissions = ::File.stat(@name).mode
      true
    end
    private :refresh_after_append

    # The entries to append, when the pending changes are additions and
    # nothing else: every entry the archive holds is still listed, in
    # place, unchanged, and the comment is as it was. Nil otherwise, and
    # the archive is rewritten.
    def appended_entries
      return nil if @create || @buffer || @native.nil? || @comment_changed || @settings.sort_entries
      return nil unless @settings.append_in_place && appendable_in_place?

      all = @cdir.entries
      held = @native.entry_count
      # The local headers there stay as they are; the crate writes the
      # central directory again, which loses some fields, so those decide
      # (without reading every local header, as `needs_restream?` would).
      return nil if all.size <= held || all.first(held).each_with_index.any? do |e, i|
        !(e.index == i && e.backed_by?(@native) && !e.dirty? && !e.changed? &&
          !e.central_fields_lost_on_append? && !@cdir.shadowed?(e))
      end

      all.drop(held)
    end
    private :appended_entries

    # Whether the archive's file can take an append: one that is read-only
    # can still be replaced (the rewrite renames a new file over it), and
    # one with other hard links must be, or the append would change what
    # they hold too.
    def appendable_in_place?
      stat = ::File.stat(@name)
      stat.file? && stat.writable? && stat.nlink <= 1
    rescue SystemCallError
      false
    end
    private :appendable_in_place?

    # Writes the archive, with any changes, to `io` and returns it. `io`
    # may be a pipe, socket or response body: entries are streamed to it
    # as they are written, unless the archive holds ZipCrypto entries,
    # whose headers are patched at the end; such an archive is built in
    # memory first.
    def write_buffer(io = ::StringIO.new)
      return io unless commit_required?

      # Rewriting the archive into the very IO it is read from would
      # overwrite entries still to be copied; build it aside first.
      if @buffer && io.equal?(@io) && !io.kind_of?(::StringIO)
        built = write_buffer(::StringIO.new).string
        io.rewind
        io.write(built)
        io.truncate(built.bytesize) if io.respond_to?(:truncate)
        return io
      end

      # ZipCrypto entries are copied with patched headers, which a stream
      # (a pipe, say) cannot take: such an archive is built in memory first.
      memory = @cdir.writable_entries.any?(&:zipcrypto?)
      ::Ziperu::OutputStream.write_buffer(io, memory: memory, **stream_options) do |zos|
        @cdir.writable_entries.each { |e| e.write_to_zip_output_stream(zos) }
        zos.comment = comment
      end
    end

    # Returns true if any changes has been made to this archive since the
    # previous commit
    def commit_required?
      @create || @dirty || @cdir.any?(&:dirty?)
    end

    private

    # Windows refuses to replace a file that is still open. A stream the
    # caller forgot to close holds its own handle until the GC frees it, so
    # on failure collect garbage once and try again.
    def rename_over_original(tmp_filename)
      ::File.rename(tmp_filename, name)
    rescue Errno::EACCES
      raise unless ::Ziperu::RUNNING_ON_WINDOWS

      GC.start
      begin
        ::File.rename(tmp_filename, name)
      rescue Errno::EACCES
        # A directory (or anything but a file) at the path is not ours to
        # move: the commit fails, as rubyzip's does.
        raise unless ::File.file?(name)

        # Something else (another Ziperu::File, say) still has the archive
        # open. Renaming an open file is allowed where replacing one is
        # not, so move the old archive aside first; that handle keeps
        # reading the old bytes, as it would on Unix.
        aside = "#{name}.#{Process.pid}.#{rand(1 << 32).to_s(36)}.old"
        ::File.rename(name, aside)
        begin
          ::File.rename(tmp_filename, name)
        rescue SystemCallError => e
          # The original goes back, so a failed commit leaves an archive
          # at the path.
          begin
            ::File.rename(aside, name)
          rescue SystemCallError
            raise Error, "could not replace #{name} (#{e.message}), nor put it back: the original is at #{aside}"
          end
          raise
        end
        begin
          ::File.delete(aside)
        rescue SystemCallError
          warn "WARNING: could not remove '#{aside}' (still open elsewhere); delete it once it is closed."
        end
      end
    end

    # What every stream this archive is written through is opened with.
    def stream_options
      { suppress_extra_fields: @suppress_extra_fields, **Settings.overrides(@settings) }
    end

    def on_success_replace
      dirname, basename = ::File.split(name)
      ::Dir::Tmpname.create(basename, dirname) do |tmp_filename|
        if yield tmp_filename
          # The native handle must be gone before the rename on Windows.
          release_native
          rename_over_original(tmp_filename)
          ::File.chmod(@file_permissions, name) unless @create
        end
      ensure
        FileUtils.rm_f(tmp_filename)
      end
    end
  end
end
