require "json"

# Stands in for `zanec` in the specs.
# - `--rewrite STAMP INPUT OUTPUT` writes the stamp's line followed by the
#   input.
# - `--remap FROM TO INPUT OUTPUT` writes a line naming both stamps followed
#   by the input.
# - Run as a compiler (any run given `--package`), it appends its arguments
#   to the file `FAKE_ZANEC_LOG` names and exits with `FAKE_ZANEC_STATUS`.
#   Besides that:
#   - `--build OUT` copies the fake compiler itself to OUT.
#   - `--object OUT` writes its arguments to OUT. With `FAKE_ZANEC_C` set, it
#     also writes beside OUT what a package's C adds: `STEM.c.0.o` and
#     `STEM.c.hashes`.
#   - `--tier-up OUT` writes OUT once it has logged, unless `FAKE_TIER_HANG`
#     is set, in which case it never finishes.
#   - `--compile-commands OUT` writes a database of each `.c` file directly in
#     a `--package` directory, whose arguments name `FAKE_FFI_DIR` with
#     `-isystem`.
#   - `--write-backs OUT` writes `FAKE_WRITE_BACKS` to OUT, or a file naming no
#     place when that is unset. With `FAKE_NO_WRITE_BACKS` set, it exits with
#     2, as a compiler that has no such flag does.
# - Run as the program that `--build` produced, it prints its arguments and
#   exits with `FAKE_PROGRAM_STATUS`. With `FAKE_PROGRAM_TIER` set, it first
#   waits for the file `ZANE_TIER_UP` names, and writes that name to
#   `FAKE_PROGRAM_TIER`.
if ARGV.first? == "--rewrite"
  if log = ENV["FAKE_ZANEC_LOG"]?
    File.open(log, "a") { |f| f.puts ARGV.join(" ") }
  end
  _, stamp, input, output = ARGV
  File.write(output, "rewritten #{stamp}\n#{File.read(input)}")
elsif ARGV.first? == "--remap"
  if log = ENV["FAKE_ZANEC_LOG"]?
    File.open(log, "a") { |f| f.puts ARGV.join(" ") }
  end
  _, from, to, input, output = ARGV
  File.write(output, "remapped #{from} #{to}\n#{File.read(input)}")
elsif ARGV.includes?("--package")
  if log = ENV["FAKE_ZANEC_LOG"]?
    File.open(log, "a") { |f| f.puts ARGV.join(" ") }
  end
  status = ENV.fetch("FAKE_ZANEC_STATUS", "0").to_i
  if status != 0
    STDERR.puts "fake compiler error"
    exit status
  end
  if i = ARGV.index("--write-backs")
    exit 2 if ENV["FAKE_NO_WRITE_BACKS"]?
    File.write(ARGV[i + 1], ENV.fetch("FAKE_WRITE_BACKS", "zanec write-backs 1\n"))
  end
  if i = ARGV.index("--build")
    File.copy(Process.executable_path.not_nil!, ARGV[i + 1])
  end
  if i = ARGV.index("--object")
    File.write(ARGV[i + 1], "object #{ARGV.join(" ")}")
    if ENV["FAKE_ZANEC_C"]?
      stem = Path[ARGV[i + 1]].parent / Path[ARGV[i + 1]].stem
      File.write("#{stem}.c.0.o", "assembled")
      File.write("#{stem}.c.hashes", "hashes")
    end
  end
  if i = ARGV.index("--compile-commands")
    dirs = ARGV.each_cons_pair.select { |flag, _| flag == "--package" }.map { |_, value| value.split('=').last }
    entries = dirs.flat_map do |dir|
      Dir.children(dir).select(&.ends_with?(".c")).sort.map do |c|
        file = File.join(dir, c)
        {"directory" => dir, "file" => file, "arguments" => ["clang", "-isystem", ENV.fetch("FAKE_FFI_DIR", ""), "-c", file]}
      end
    end
    File.write(ARGV[i + 1], entries.to_json)
  end
  if i = ARGV.index("--tier-up")
    sleep 1.hour if ENV["FAKE_TIER_HANG"]?
    File.write(ARGV[i + 1], "tier 1")
  end
else
  if tier = ENV["FAKE_PROGRAM_TIER"]?
    library = ENV["ZANE_TIER_UP"]? || ""
    deadline = Time.instant + 10.seconds
    until library.empty? || File.exists?(library) || Time.instant > deadline
      sleep 10.milliseconds
    end
    File.write(tier, library)
  end
  puts "program ran with [#{ARGV.join(", ")}]"
  exit ENV.fetch("FAKE_PROGRAM_STATUS", "0").to_i
end
