require "./spec_helper"

# The manifest and lock file examples of the spec (dependencies.md §2.1, §2.2).
MANIFEST = <<-CODA
  name app
  kind application
  zane-version v0.4.1
  version-pattern v*.+.++

  deps [
      key      version  from
      core     v1.4.0   release
      math     v6.2.9   source
      geometry v0.3.0   ../geometry
  ]

  remaps [
      https://github.com/zane-lang/math
  ]
  CODA

describe Zane::Coda do
  it "reads the manifest's fields" do
    doc = Zane::Coda::Document.parse(MANIFEST)
    doc.root.keys.should eq ["name", "kind", "zane-version", "version-pattern", "deps", "remaps"]
    doc["name"].as_s.should eq "app"
    doc["version-pattern"].as_s.should eq "v*.+.++"
    doc["remaps"].items.should eq ["https://github.com/zane-lang/math"]
    doc["missing"]?.should be_nil
  end

  it "reads a table whose first column is key as a keyed table" do
    deps = Zane::Coda::Document.parse(MANIFEST)["deps"]
    deps.keyed?.should be_true
    deps.columns.should eq ["key", "version", "from"]
    deps.rows.should eq [
      {"key" => "core", "version" => "v1.4.0", "from" => "release"},
      {"key" => "math", "version" => "v6.2.9", "from" => "source"},
      {"key" => "geometry", "version" => "v0.3.0", "from" => "../geometry"},
    ]
  end

  it "reads a plain table" do
    doc = Zane::Coda::Document.parse("artifacts [\n    target url sha256\n    x86_64-linux https://a 00ff\n]\n")
    doc["artifacts"].keyed?.should be_false
    doc["artifacts"].rows.should eq [{"target" => "x86_64-linux", "url" => "https://a", "sha256" => "00ff"}]
  end

  it "writes a document that reads back the same" do
    doc = Zane::Coda::Document.new
    doc["name"] = "app"
    doc["kind"] = "library"
    doc.add_table("deps", ["key", "version", "from"])
      .append_row({"key" => "core", "version" => "v1.4.0", "from" => "release"})
    doc.add_table("empty", ["key", "url", "commit"])
    doc.add_array("remaps", ["https://github.com/zane-lang/math"])

    back = Zane::Coda::Document.parse(doc.to_s)
    back["kind"].as_s.should eq "library"
    back["deps"].rows.should eq [{"key" => "core", "version" => "v1.4.0", "from" => "release"}]
    back["empty"].keyed?.should be_true
    back["empty"].rows.should be_empty
    back["remaps"].items.should eq ["https://github.com/zane-lang/math"]
  end

  it "reports where a document is malformed" do
    error = expect_raises(Zane::Coda::ParseError) do
      Zane::Coda::Document.parse("deps [\n    key version\n    core\n]\n", "zane.coda")
    end
    error.line.should eq 3
    error.message.not_nil!.should contain "zane.coda:3"
  end

  it "refuses to read a node as the wrong kind" do
    expect_raises(Zane::Coda::Error, "expected string, found keyedtable") do
      Zane::Coda::Document.parse(MANIFEST)["deps"].as_s
    end
  end
end
