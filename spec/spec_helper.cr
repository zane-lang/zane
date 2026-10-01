require "spec"
require "file_utils"
require "../src/zane/cli"
require "../src/zane/sha256"
require "../src/zane/coda"

alias CodaValue = String | Hash(String, Array(String) | Hash(String, Hash(String, String)))

# The top-level fields of a `.coda` file, with strings as themselves and keyed
# tables as their columns and rows, so a whole file compares with one `eq`.
def read_coda(path : Path) : Hash(String, CodaValue)
  Coda::Doc.parse_file(path) do |doc|
    doc.root.to_h do |key, node|
      value = case node
              when Coda::StringNode then node.value
              when Coda::KeyedTable
                rows = node.to_h { |k, row| {k, row.to_h} }
                {"columns" => node.columns, "rows" => rows}.as(Hash(String, Array(String) | Hash(String, Hash(String, String))))
              else raise "unexpected #{node.class} at #{key}"
              end
      {key, value.as(CodaValue)}
    end
  end
end
