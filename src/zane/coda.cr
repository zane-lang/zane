# Reading and writing `.coda` files through coda's C API, built from the
# vendored sources into a static library (see the justfile).

# Crystal passes these to the linker in reverse order, and the C++ runtime has to
# come after coda.
{% if flag?(:darwin) %}
  @[Link("c++")]
{% elsif !flag?(:win32) %}
  @[Link("stdc++")]
{% end %}
@[Link("coda")]
lib LibCoda
  type Doc = Void*
  alias Node = UInt32

  struct Str
    ptr : UInt8*
    len : LibC::SizeT
  end

  struct OwnedStr
    ptr : UInt8*
    len : LibC::SizeT
  end

  struct Error
    code : UInt32
    line : UInt32
    col : UInt32
    offset : LibC::SizeT
    message : OwnedStr
  end

  enum Kind
    Null       = 0
    String     = 2
    Block      = 3
    Array      = 4
    Table      = 5
    KeyedTable = 6
    Row        = 7
  end

  enum Status
    Ok         = 0
    Err        = 1
    NotFound   = 2
    BadKind    = 3
    OutOfRange = 4
  end

  fun error_clear = coda_error_clear(err : Error*)
  fun owned_str_free = coda_owned_str_free(s : OwnedStr)

  fun doc_new = coda_doc_new : Doc
  fun doc_free = coda_doc_free(doc : Doc)
  fun doc_parse = coda_doc_parse(src : UInt8*, len : LibC::SizeT, filename : UInt8*, err : Error*) : Doc
  fun doc_serialize = coda_doc_serialize(doc : Doc, indent : UInt8*, indent_len : LibC::SizeT, err : Error*) : OwnedStr
  fun doc_root = coda_doc_root(doc : Doc) : Node

  fun node_kind = coda_node_kind(doc : Doc, n : Node) : Kind
  fun string_get = coda_string_get(doc : Doc, n : Node) : Str

  fun array_len = coda_array_len(doc : Doc, a : Node) : LibC::SizeT
  fun array_get = coda_array_get(doc : Doc, a : Node, idx : LibC::SizeT) : Node
  fun array_push = coda_array_push(doc : Doc, a : Node, value : Node) : Status

  fun map_len = coda_map_len(doc : Doc, m : Node) : LibC::SizeT
  fun map_key_at = coda_map_key_at(doc : Doc, m : Node, idx : LibC::SizeT) : Str
  fun map_get = coda_map_get(doc : Doc, m : Node, key : UInt8*, key_len : LibC::SizeT) : Node
  fun map_set = coda_map_set(doc : Doc, m : Node, key : UInt8*, key_len : LibC::SizeT, value : Node) : Status

  fun table_col_count = coda_table_col_count(doc : Doc, t : Node) : LibC::SizeT
  fun table_col_name = coda_table_col_name(doc : Doc, t : Node, idx : LibC::SizeT) : Str
  fun table_col_append = coda_table_col_append(doc : Doc, t : Node, name : UInt8*, len : LibC::SizeT) : Status
  fun table_row_count = coda_table_row_count(doc : Doc, t : Node) : LibC::SizeT
  fun table_row_at = coda_table_row_at(doc : Doc, t : Node, idx : LibC::SizeT) : Node
  fun table_row_append = coda_table_row_append(doc : Doc, t : Node, row : Node) : Status

  fun keyed_table_col_count = coda_keyed_table_col_count(doc : Doc, kt : Node) : LibC::SizeT
  fun keyed_table_col_name = coda_keyed_table_col_name(doc : Doc, kt : Node, idx : LibC::SizeT) : Str
  fun keyed_table_col_append = coda_keyed_table_col_append(doc : Doc, kt : Node, name : UInt8*, len : LibC::SizeT) : Status
  fun keyed_table_row_count = coda_keyed_table_row_count(doc : Doc, kt : Node) : LibC::SizeT
  fun keyed_table_row_key_at = coda_keyed_table_row_key_at(doc : Doc, kt : Node, idx : LibC::SizeT) : Str
  fun keyed_table_row_at = coda_keyed_table_row_at(doc : Doc, kt : Node, idx : LibC::SizeT) : Node
  fun keyed_table_row_set = coda_keyed_table_row_set(doc : Doc, kt : Node, key : UInt8*, key_len : LibC::SizeT, row : Node) : Status

  fun row_get = coda_row_get(doc : Doc, row : Node, col : UInt8*, len : LibC::SizeT) : Str
  fun row_set = coda_row_set(doc : Doc, row : Node, col : UInt8*, col_len : LibC::SizeT, val : UInt8*, val_len : LibC::SizeT) : Status

  fun new_string = coda_new_string(doc : Doc, s : UInt8*, len : LibC::SizeT) : Node
  fun new_array = coda_new_array(doc : Doc) : Node
  fun new_table = coda_new_table(doc : Doc) : Node
  fun new_keyed_table = coda_new_keyed_table(doc : Doc) : Node
  fun new_row = coda_new_row(doc : Doc) : Node
end

module Zane::Coda
  class ParseError < Exception
    getter line : UInt32
    getter col : UInt32

    def initialize(@line, @col, message : String)
      super(message)
    end
  end

  class Error < Exception
  end

  # One parsed or newly built document. It owns its C document and frees it
  # when collected.
  class Document
    @doc : LibCoda::Doc

    def self.parse(source : String, filename : String = "<input>") : Document
      err = LibCoda::Error.new
      doc = LibCoda.doc_parse(source.to_unsafe, source.bytesize, filename, pointerof(err))
      if doc.null?
        message = Coda.owned(err.message)
        line, col = err.line, err.col
        LibCoda.error_clear(pointerof(err))
        raise ParseError.new(line, col, message)
      end
      new(doc)
    end

    def self.read(path : String | Path) : Document
      parse(File.read(path), path.to_s)
    end

    def initialize
      @doc = LibCoda.doc_new
    end

    protected def initialize(@doc : LibCoda::Doc)
    end

    def finalize
      LibCoda.doc_free(@doc)
    end

    def root : Node
      Node.new(self, LibCoda.doc_root(@doc))
    end

    def to_unsafe : LibCoda::Doc
      @doc
    end

    # The document as text, indented with four spaces.
    def to_s(io : IO) : Nil
      indent = "    "
      err = LibCoda::Error.new
      text = LibCoda.doc_serialize(@doc, indent, indent.bytesize, pointerof(err))
      if text.ptr.null?
        message = Coda.owned(err.message)
        LibCoda.error_clear(pointerof(err))
        raise Error.new(message)
      end
      io << Coda.owned(text)
      LibCoda.owned_str_free(text)
    end

    def []=(key : String, value : String)
      root[key] = value
    end

    def [](key : String) : Node
      root[key]
    end

    def []?(key : String) : Node?
      root[key]?
    end

    # Adds a top-level table with the given columns and returns it. A table
    # whose first column is `key` is a keyed table, as the parser reads it.
    def add_table(key : String, columns : Array(String)) : Node
      keyed = columns.first? == "key"
      table = Node.new(self, keyed ? LibCoda.new_keyed_table(@doc) : LibCoda.new_table(@doc))
      columns.each do |c|
        next if keyed && c == "key"
        status = keyed ? LibCoda.keyed_table_col_append(@doc, table.handle, c, c.bytesize) : LibCoda.table_col_append(@doc, table.handle, c, c.bytesize)
        Coda.check status, "column #{c}"
      end
      Coda.check LibCoda.map_set(@doc, root.handle, key, key.bytesize, table.handle), key
      table
    end

    # Adds a top-level array of strings.
    def add_array(key : String, items : Array(String)) : Node
      array = Node.new(self, LibCoda.new_array(@doc))
      items.each do |item|
        Coda.check LibCoda.array_push(@doc, array.handle, LibCoda.new_string(@doc, item, item.bytesize)), key
      end
      Coda.check LibCoda.map_set(@doc, root.handle, key, key.bytesize, array.handle), key
      array
    end
  end

  # A handle to one node of a document. It is valid while the document is
  # alive and the node has not been removed.
  struct Node
    getter handle : LibCoda::Node

    def initialize(@document : Document, @handle : LibCoda::Node)
    end

    def kind : LibCoda::Kind
      LibCoda.node_kind(doc, @handle)
    end

    def as_s : String
      expect LibCoda::Kind::String
      Coda.borrowed(LibCoda.string_get(doc, @handle))
    end

    def []?(key : String) : Node?
      expect LibCoda::Kind::Block
      n = LibCoda.map_get(doc, @handle, key, key.bytesize)
      n == 0 ? nil : Node.new(@document, n)
    end

    def [](key : String) : Node
      self[key]? || raise Error.new("missing field `#{key}`")
    end

    def []=(key : String, value : String)
      expect LibCoda::Kind::Block
      s = LibCoda.new_string(doc, value, value.bytesize)
      Coda.check LibCoda.map_set(doc, @handle, key, key.bytesize, s), key
    end

    def keys : Array(String)
      expect LibCoda::Kind::Block
      Array.new(LibCoda.map_len(doc, @handle).to_i) { |i| Coda.borrowed(LibCoda.map_key_at(doc, @handle, i)) }
    end

    # The strings of an array.
    def items : Array(String)
      expect LibCoda::Kind::Array
      Array.new(LibCoda.array_len(doc, @handle).to_i) do |i|
        Node.new(@document, LibCoda.array_get(doc, @handle, i)).as_s
      end
    end

    # The column names of a table. A keyed table's start with `key`.
    def columns : Array(String)
      if keyed?
        ["key"] + Array.new(LibCoda.keyed_table_col_count(doc, @handle).to_i) { |i| Coda.borrowed(LibCoda.keyed_table_col_name(doc, @handle, i)) }
      else
        expect LibCoda::Kind::Table
        Array.new(LibCoda.table_col_count(doc, @handle).to_i) { |i| Coda.borrowed(LibCoda.table_col_name(doc, @handle, i)) }
      end
    end

    # The rows of a table, each as column name to value. A keyed table's rows
    # carry their key under `key`.
    def rows : Array(Hash(String, String))
      cols = columns
      if keyed?
        Array.new(LibCoda.keyed_table_row_count(doc, @handle).to_i) do |i|
          row = LibCoda.keyed_table_row_at(doc, @handle, i)
          values = {"key" => Coda.borrowed(LibCoda.keyed_table_row_key_at(doc, @handle, i))}
          cols.each { |c| values[c] = Coda.borrowed(LibCoda.row_get(doc, row, c, c.bytesize)) unless c == "key" }
          values
        end
      else
        Array.new(LibCoda.table_row_count(doc, @handle).to_i) do |i|
          row = LibCoda.table_row_at(doc, @handle, i)
          cols.to_h { |c| {c, Coda.borrowed(LibCoda.row_get(doc, row, c, c.bytesize))} }
        end
      end
    end

    # Appends a row. For a keyed table, `values["key"]` is the row's key.
    def append_row(values : Hash(String, String)) : Nil
      keyed = keyed?
      expect LibCoda::Kind::Table unless keyed
      row = LibCoda.new_row(doc)
      values.each do |col, val|
        next if keyed && col == "key"
        Coda.check LibCoda.row_set(doc, row, col, col.bytesize, val, val.bytesize), col
      end
      if keyed
        key = values["key"]
        Coda.check LibCoda.keyed_table_row_set(doc, @handle, key, key.bytesize, row), "row #{key}"
      else
        Coda.check LibCoda.table_row_append(doc, @handle, row), "row"
      end
    end

    def keyed? : Bool
      kind.keyed_table?
    end

    private def doc : LibCoda::Doc
      @document.to_unsafe
    end

    private def expect(k : LibCoda::Kind)
      actual = kind
      raise Error.new("expected #{k.to_s.downcase}, found #{actual.to_s.downcase}") unless actual == k
    end
  end

  # Copies a string that coda lends.
  def self.borrowed(s : LibCoda::Str) : String
    s.ptr.null? ? "" : String.new(s.ptr, s.len)
  end

  # Copies a string that coda hands over; the caller still frees it.
  def self.owned(s : LibCoda::OwnedStr) : String
    s.ptr.null? ? "" : String.new(s.ptr, s.len)
  end

  def self.check(status : LibCoda::Status, what : String) : Nil
    raise Error.new("#{what}: #{status.to_s.downcase}") unless status.ok?
  end
end
