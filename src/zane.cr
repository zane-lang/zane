require "./zane/cli"

# An update on Windows leaves the binary it replaced, which only a later run
# can delete (docs/design/cli.md §4.2).
{% if flag?(:win32) %}
  if path = Process.executable_path
    Zane::SelfUpdate.clean_old(Path[path].parent)
  end
{% end %}

exit Zane::CLI.run(ARGV)
