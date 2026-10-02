# Stands in for `zanec` in the specs. As a compiler (any run given
# `--package`) it appends its arguments to the file `FAKE_ZANEC_LOG` names,
# exits with `FAKE_ZANEC_STATUS`, and for `--build OUT` copies itself to OUT.
# Run as that program, it prints its arguments and exits with
# `FAKE_PROGRAM_STATUS`.
if ARGV.includes?("--package")
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
else
  puts "program ran with [#{ARGV.join(", ")}]"
  exit ENV.fetch("FAKE_PROGRAM_STATUS", "0").to_i
end
