module Zane
  # Which versions of one package remapping collapses, and onto which (spec
  # dependencies.md §15). Each version brings the `version-pattern` its own
  # manifest declares.
  module Remap
    # A version-pattern's components after its leading `v`: each a marker,
    # `*` or a repeated `+` or `-`, or a literal (§15.2).
    record Component, text : String do
      def marker? : Bool
        {'*', '+', '-'}.includes?(text[0]) && text.each_char.all?(text[0])
      end

      def fixed? : Bool
        text == "*"
      end

      # The rank of a `+` or `-` component: fewer repeats rank higher.
      def priority : Int32
        text.size
      end

      def upward? : Bool
        text[0] == '+'
      end
    end

    # What remapping decided: each displaced tag with the tag chosen in its
    # place, and the patterns that kept versions apart, when they differ.
    record Result, chosen : Hash(String, String), divergent : Hash(String, String)?

    # *versions* are each version's tag and declared pattern.
    def self.select(versions : Array({String, String})) : Result
      chosen = {} of String => String
      versions.group_by { |_, pattern| pattern }.each do |pattern, group|
        components = parse(pattern)
        directional = components.each_with_index.select { |c, _| c.marker? && !c.fixed? }.to_a
          .sort_by! { |c, _| c.priority }.map { |c, i| {i, c.upward?} }
        windows = {} of Array(String) => Array({String, Array(String)})
        group.each do |tag, _|
          parts = shape(tag, components) || next
          window = components.each_with_index.reject { |c, _| c.marker? && !c.fixed? }.map { |_, i| parts[i] }.to_a
          (windows[window] ||= [] of {String, Array(String)}) << {tag, parts}
        end
        windows.each_value do |members|
          next if members.size < 2
          best = members.reduce { |a, b| better?(b[1], a[1], directional) ? b : a }
          members.each do |tag, parts|
            next if tag == best[0]
            chosen[tag] = best[0] if substitutes?(best[1], parts, directional)
          end
        end
      end
      patterns = versions.map { |_, p| p }.uniq
      Result.new(chosen, patterns.size > 1 ? versions.to_h : nil)
    end

    def self.parse(pattern : String) : Array(Component)
      pattern.lchop('v').split('.').map { |c| Component.new(c) }
    end

    # *tag*'s components when it has the pattern's shape: as many
    # components, a number at each marker, and each literal as written
    # (§15.4). Nil when it does not, and then it is never remapped.
    def self.shape(tag : String, components : Array(Component)) : Array(String)?
      parts = tag.lchop('v').split('.')
      return nil unless parts.size == components.size
      parts.each_with_index do |part, i|
        if components[i].marker?
          return nil unless !part.empty? && part.each_char.all?(&.ascii_number?)
        else
          return nil unless part == components[i].text
        end
      end
      parts
    end

    # Whether *a* ranks above *b*: at the first directional component, in
    # priority order, where they differ, *a* has the greater value of a `+`
    # or the smaller of a `-`.
    def self.better?(a : Array(String), b : Array(String), directional : Array({Int32, Bool})) : Bool
      directional.each do |i, upward|
        order = number(a[i]) <=> number(b[i])
        next if order == 0
        return upward ? order > 0 : order < 0
      end
      false
    end

    # Whether *replacement* may stand in for *required* (§15.3): equal, or
    # better at the first component where they differ.
    def self.substitutes?(replacement : Array(String), required : Array(String), directional : Array({Int32, Bool})) : Bool
      replacement == required || better?(replacement, required, directional)
    end

    # A component's value, compared without leading zeros or a size limit.
    private def self.number(text : String) : {Int32, String}
      digits = text.lstrip('0')
      {digits.size, digits}
    end
  end
end
