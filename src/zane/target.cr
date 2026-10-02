module Zane
  # Target triples, spelled as the compiler's cross-linker, `zig cc`, reads
  # them (compiler docs/design/platforms.md).
  module Target
    # The machine `zane` runs on, which is what a build is for unless
    # `--target` says otherwise. A library's artifact for it is the one
    # fetched.
    HOST = {% begin %}
             {% arch = flag?(:aarch64) ? "aarch64" : "x86_64" %}
             {% if flag?(:win32) %}
               "{{ arch.id }}-windows-gnu"
             {% elsif flag?(:darwin) %}
               "{{ arch.id }}-macos"
             {% else %}
               "{{ arch.id }}-linux-gnu"
             {% end %}
           {% end %}

    def self.windows?(target : String) : Bool
      target.includes?("windows")
    end
  end
end
