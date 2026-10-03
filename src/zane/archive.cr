require "compress/gzip"
require "file_utils"
require "./errors"
require "./sha256"

module Zane
  # A library's release archive: downloading it, checking it against the hash
  # its library committed, and unpacking its objects (spec dependencies.md
  # §3.1, §5).
  module Archive
    # Downloads *url* to *path*. Specs replace it; everything else uses curl.
    class_property download : Proc(String, Path, Nil) = ->(url : String, path : Path) { curl(url, path) }

    # curl ships with every supported system. It is told to speak only HTTPS,
    # redirects included, and to fail on an error status rather than save the
    # error page.
    def self.curl(url : String, path : Path) : Nil
      error = IO::Memory.new
      args = ["--fail", "--silent", "--show-error", "--location", "--proto", "=https",
              "--proto-redir", "=https", "--output", path.to_s, url]
      status = begin
        Process.run("curl", args, error: error)
      rescue File::NotFoundError
        raise UserError.new("curl is not installed; zane needs it to download packages")
      end
      raise UserError.new("cannot download #{url}:\n#{error.to_s.strip}") unless status.success?
    end

    # Downloads *url* to *path* and checks it is the archive whose SHA-256 is
    # *sha256*. Nothing is left at *path* unless it is.
    def self.fetch(url : String, sha256 : String, path : Path) : Nil
      Dir.mkdir_p(path.parent)
      partial = path.parent / ".#{path.basename}.#{Random::Secure.hex(4)}"
      download.call(url, partial)
      verify(partial, sha256, url)
      File.rename(partial, path)
    ensure
      File.delete?(partial) if partial
    end

    # Refuses the file at *path* unless its SHA-256 is *sha256*.
    def self.verify(path : Path, sha256 : String, url : String) : Nil
      actual = SHA256.file(path)
      return if actual == sha256
      raise UserError.new("security error: #{url} has SHA-256 #{actual}, " \
                          "but the library's zane-artifacts.coda says #{sha256}")
    end

    # Unpacks the gzip-compressed tar archive at *path* into *dir*, which must
    # not exist, and returns how many files it held. Only directories and
    # regular files under `build/` are allowed, so nothing can land outside
    # *dir* (§3.1). The tar format is read here, rather than by `tar`, so that
    # every entry is checked before anything is written. Nothing is left at
    # *dir* unless it succeeds.
    def self.extract(path : Path, dir : Path) : Int32
      Dir.mkdir_p(dir.parent)
      partial = dir.parent / ".#{dir.basename}.#{Random::Secure.hex(4)}"
      Dir.mkdir(partial)
      files = File.open(path) do |file|
        Compress::Gzip::Reader.open(file) { |gzip| Tar.new(gzip, path).extract(partial) }
      end
      raise UserError.new("#{path} holds no files under build/") if files == 0
      File.rename(partial, dir)
      files
    rescue error : Compress::Gzip::Error
      raise UserError.new("#{path} is not a gzip-compressed archive: #{error.message}")
    rescue error : File::Error
      raise UserError.new("cannot unpack #{path}: #{error.message}")
    ensure
      FileUtils.rm_rf(partial) if partial && Dir.exists?(partial)
    end

    # A tar stream, in the ustar layout with the pax and GNU long-name
    # extensions that common `tar` programs write.
    private class Tar
      BLOCK = 512

      def initialize(@io : IO, @archive : Path)
      end

      def extract(dir : Path) : Int32
        files = 0
        long_name = nil
        header = Bytes.new(BLOCK)
        loop do
          break unless read_block(header)
          break if header.all?(&.zero?)
          check_sum(header)
          name = long_name || ustar_name(header)
          long_name = nil
          size = octal(header[124, 12], "size")
          case type = header[156].unsafe_chr
          when 'x'
            long_name = pax_path(read_data(size)) || long_name
          when 'g'
            skip(size)
          when 'L'
            long_name = String.new(read_data(size)).rstrip('\0')
          when '0', '\0', '7'
            files += 1 if write(dir, name, size)
          when '5'
            make_dir(dir, name)
            skip(size)
          else
            what = {'1' => "a hard link", '2' => "a symbolic link"}[type]? || "a special file"
            refuse("#{name} is #{what}; an archive holds only directories and files")
          end
        end
        files
      end

      # The path a pax header gives the next entry, if it gives one. Each
      # record is `LENGTH KEY=VALUE\n`.
      private def pax_path(data : Bytes) : String?
        text = String.new(data)
        found = nil
        at = 0
        while at < text.bytesize
          space = text.byte_index(' '.ord, at) || refuse("a pax header is malformed")
          length = text.byte_slice(at, space - at).to_i? || refuse("a pax header is malformed")
          refuse("a pax header is malformed") if length <= 0 || at + length > text.bytesize
          record = text.byte_slice(space + 1, length - (space - at) - 2)
          key, _, value = record.partition('=')
          found = value if key == "path"
          at += length
        end
        found
      end

      private def ustar_name(header : Bytes) : String
        name = field(header[0, 100])
        if String.new(header[257, 5]) == "ustar" && !(prefix = field(header[345, 155])).empty?
          "#{prefix}/#{name}"
        else
          name
        end
      end

      private def field(bytes : Bytes) : String
        String.new(bytes[0, bytes.index(0_u8) || bytes.size])
      end

      private def octal(bytes : Bytes, what : String) : Int64
        refuse("an entry's #{what} is too large") if bytes[0] & 0x80 != 0
        text = field(bytes).strip
        return 0_i64 if text.empty?
        text.to_i64?(8) || refuse("an entry's #{what} is not a number")
      end

      private def check_sum(header : Bytes) : Nil
        expected = octal(header[148, 8], "checksum")
        sum = 0_i64
        header.each_with_index { |b, i| sum += (148 <= i < 156) ? 32 : b }
        refuse("an entry's header is corrupt") unless sum == expected
      end

      # *name* as a path under *dir*, refused unless it is under `build/` and
      # cannot leave it. Nil for the archive's top directory itself.
      private def target(dir : Path, name : String) : Path?
        refuse("#{name} is an absolute path") if name.starts_with?('/')
        parts = name.split('/').reject { |p| p.empty? || p == "." }
        if parts.any? { |p| p == ".." || p.includes?('\\') || p.includes?(':') }
          refuse("#{name} leaves the directory it is unpacked into")
        end
        return nil if parts.empty?
        refuse("#{name} is outside build/") unless parts.first == "build"
        dir.join(parts)
      end

      private def make_dir(dir : Path, name : String) : Nil
        if path = target(dir, name)
          Dir.mkdir_p(path)
        end
      end

      private def write(dir : Path, name : String, size : Int64) : Bool
        path = target(dir, name) || refuse("#{name} is a file outside build/")
        refuse("#{name} is not under build/") if path.parent == dir
        refuse("#{name} is in the archive twice") if File.exists?(path)
        Dir.mkdir_p(path.parent)
        File.open(path, "wb") do |file|
          copied = IO.copy(@io, file, size)
          refuse("the archive ends inside #{name}") if copied < size
        end
        skip_padding(size)
        true
      end

      private def read_block(block : Bytes) : Bool
        read = @io.read_fully?(block)
        !read.nil?
      end

      private def read_data(size : Int64) : Bytes
        refuse("an extended header is too large") if size > 1 << 20
        data = Bytes.new(size)
        @io.read_fully?(data) || refuse("the archive ends inside an extended header")
        skip_padding(size)
        data
      end

      private def skip(size : Int64) : Nil
        @io.skip(size + padding(size))
      rescue IO::EOFError
        refuse("the archive ends inside an entry")
      end

      private def skip_padding(size : Int64) : Nil
        @io.skip(padding(size))
      rescue IO::EOFError
        refuse("the archive ends inside an entry")
      end

      private def padding(size : Int64) : Int64
        (BLOCK.to_i64 - size % BLOCK) % BLOCK
      end

      private def refuse(why : String) : NoReturn
        raise UserError.new("#{@archive} is not a usable archive: #{why}")
      end
    end
  end
end
