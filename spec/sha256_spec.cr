require "./spec_helper"

# The examples published with FIPS 180-4, and splits of one input around the
# 56- and 64-byte padding boundaries. The split input's digest is Python's
# `hashlib`.
describe Zane::SHA256 do
  it "hashes the empty input" do
    Zane::SHA256.hexdigest("").should eq "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  end

  it "hashes one block" do
    Zane::SHA256.hexdigest("abc").should eq "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  it "hashes two blocks" do
    Zane::SHA256.hexdigest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
      .should eq "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  end

  it "hashes a million bytes" do
    Zane::SHA256.hexdigest("a" * 1_000_000).should eq "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  end

  it "gives the same digest however the input is split" do
    data = Bytes.new(1000) { |i| (i * 7).to_u8! }
    whole = Zane::SHA256.hexdigest(data)
    whole.should eq "89f4ff56a25dd1db06a4ce6033603775d705fb96f30f8693733fef602a1ca532"
    [1, 55, 56, 63, 64, 65, 999].each do |cut|
      Zane::SHA256.new.update(data[0, cut]).update(data[cut..]).hexfinal.should eq whole
    end
  end

  it "hashes a file" do
    File.tempfile("sha256") do |f|
      f.print "abc"
    end.tap do |f|
      Zane::SHA256.file(f.path).should eq Zane::SHA256.hexdigest("abc")
      f.delete
    end
  end
end
