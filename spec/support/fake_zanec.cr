# Stands in for `zanec` in the specs. `--rewrite STAMP INPUT OUTPUT` writes
# the stamp's line followed by the input, and `--remap FROM TO INPUT OUTPUT`
# a line naming both stamps followed by the input. As a compiler (any run
# given `--package`) it appends its arguments to the file `FAKE_ZANEC_LOG`
# names, exits with `FAKE_ZANEC_STATUS`, for `--build OUT` copies itself to
# OUT, and for `--object OUT` writes its arguments to OUT, and with
# `FAKE_ZANEC_C` set, writes beside it what a package's C adds: `STEM.c.0.o`
# and `STEM.c.hashes`. For
# `--tier-up OUT` it writes OUT once it has logged, unless `FAKE_TIER_HANG`
# is set, when it never finishes.
# Run as that program, it prints its arguments and exits with
# `FAKE_PROGRAM_STATUS`. With `FAKE_PROGRAM_TIER` set it first waits for the
# file `ZANE_TIER_UP` names, and writes that name to `FAKE_PROGRAM_TIER`.
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
