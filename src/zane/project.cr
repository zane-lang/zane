require "./errors"

module Zane
  # Rules about a project that the manifest has to follow.
  module Project
    # A package name: camelCase, starting with a lowercase letter (spec
    # lexical.md §3, §4.1).
    NAME = /\A[a-z][A-Za-z0-9]*\z/

    DEFAULT_VERSION_PATTERN = "v*.+.++"

    # The name every test package declares (spec packages.md §7.1).
    TEST_PACKAGE = "test"

    def self.valid_name?(name : String) : Bool
      NAME.matches?(name)
    end

    # The package name a directory's name suggests: its words joined in
    # camelCase, so `my-tool` gives `myTool`. Nil when that is not a valid name.
    def self.name_from(dir_name : String) : String?
      words = dir_name.split(/[^A-Za-z0-9]+/, remove_empty: true)
      return nil if words.empty?
      name = String.build do |io|
        words.each_with_index do |word, i|
          io << (i == 0 ? word[0].downcase : word[0].upcase) << word[1..]
        end
      end
      valid_name?(name) ? name : nil
    end

    # Why *pattern* is not a valid `version-pattern` (spec dependencies.md
    # §15.2), or nil when it is.
    def self.version_pattern_error(pattern : String) : String?
      components = pattern.lchop('v').split('.')
      return "it is empty" if components.any?(&.empty?)
      priorities = {} of Int32 => String
      components.each do |c|
        marker = c[0]
        next unless {'*', '+', '-'}.includes?(marker) && c.each_char.all?(marker)
        next if marker == '*'
        if other = priorities[c.size]?
          return "`#{other}` and `#{c}` share a priority level"
        end
        priorities[c.size] = c
      end
      nil
    end
  end
end
