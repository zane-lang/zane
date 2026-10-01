# SHA-256 (FIPS 180-4) in Crystal, so the binary needs no OpenSSL. Every
# archive a fetch downloads is checked against the hash its library committed
# (spec dependencies.md §5), so this is the one cryptographic primitive the
# command needs.
class Zane::SHA256
  K = StaticArray[
    0x428a2f98_u32, 0x71374491_u32, 0xb5c0fbcf_u32, 0xe9b5dba5_u32, 0x3956c25b_u32, 0x59f111f1_u32, 0x923f82a4_u32, 0xab1c5ed5_u32,
    0xd807aa98_u32, 0x12835b01_u32, 0x243185be_u32, 0x550c7dc3_u32, 0x72be5d74_u32, 0x80deb1fe_u32, 0x9bdc06a7_u32, 0xc19bf174_u32,
    0xe49b69c1_u32, 0xefbe4786_u32, 0x0fc19dc6_u32, 0x240ca1cc_u32, 0x2de92c6f_u32, 0x4a7484aa_u32, 0x5cb0a9dc_u32, 0x76f988da_u32,
    0x983e5152_u32, 0xa831c66d_u32, 0xb00327c8_u32, 0xbf597fc7_u32, 0xc6e00bf3_u32, 0xd5a79147_u32, 0x06ca6351_u32, 0x14292967_u32,
    0x27b70a85_u32, 0x2e1b2138_u32, 0x4d2c6dfc_u32, 0x53380d13_u32, 0x650a7354_u32, 0x766a0abb_u32, 0x81c2c92e_u32, 0x92722c85_u32,
    0xa2bfe8a1_u32, 0xa81a664b_u32, 0xc24b8b70_u32, 0xc76c51a3_u32, 0xd192e819_u32, 0xd6990624_u32, 0xf40e3585_u32, 0x106aa070_u32,
    0x19a4c116_u32, 0x1e376c08_u32, 0x2748774c_u32, 0x34b0bcb5_u32, 0x391c0cb3_u32, 0x4ed8aa4a_u32, 0x5b9cca4f_u32, 0x682e6ff3_u32,
    0x748f82ee_u32, 0x78a5636f_u32, 0x84c87814_u32, 0x8cc70208_u32, 0x90befffa_u32, 0xa4506ceb_u32, 0xbef9a3f7_u32, 0xc67178f2_u32,
  ]

  @state : StaticArray(UInt32, 8) = StaticArray[
    0x6a09e667_u32, 0xbb67ae85_u32, 0x3c6ef372_u32, 0xa54ff53a_u32,
    0x510e527f_u32, 0x9b05688c_u32, 0x1f83d9ab_u32, 0x5be0cd19_u32,
  ]
  @block = StaticArray(UInt8, 64).new(0_u8)
  @filled : Int32 = 0
  @length : UInt64 = 0_u64

  def self.hexdigest(data : Bytes | String) : String
    new.update(data).hexfinal
  end

  def self.file(path : String | Path) : String
    sha = new
    File.open(path) do |f|
      buffer = Bytes.new(64 * 1024)
      while (n = f.read(buffer)) > 0
        sha.update(buffer[0, n])
      end
    end
    sha.hexfinal
  end

  def update(data : String) : self
    update(data.to_slice)
  end

  def update(data : Bytes) : self
    @length &+= data.size.to_u64
    data.each do |byte|
      @block[@filled] = byte
      @filled += 1
      if @filled == 64
        compress
        @filled = 0
      end
    end
    self
  end

  # The digest as 64 lowercase hex digits. The hasher cannot be updated after.
  def hexfinal : String
    bits = @length &* 8
    update_byte(0x80_u8)
    while @filled != 56
      update_byte(0_u8)
    end
    7.downto(0) { |i| update_byte((bits >> (i * 8)).to_u8!) }
    String.build(64) do |io|
      @state.each { |word| io << word.to_s(16).rjust(8, '0') }
    end
  end

  private def update_byte(byte : UInt8)
    @block[@filled] = byte
    @filled += 1
    if @filled == 64
      compress
      @filled = 0
    end
  end

  private def compress
    w = StaticArray(UInt32, 64).new(0_u32)
    16.times do |i|
      w[i] = (@block[i * 4].to_u32 << 24) | (@block[i * 4 + 1].to_u32 << 16) |
             (@block[i * 4 + 2].to_u32 << 8) | @block[i * 4 + 3].to_u32
    end
    (16...64).each do |i|
      s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
      s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
    end
    a, b, c, d, e, f, g, h = @state[0], @state[1], @state[2], @state[3], @state[4], @state[5], @state[6], @state[7]
    64.times do |i|
      t1 = h &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ K[i] &+ w[i]
      t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
      h, g, f, e, d, c, b, a = g, f, e, d &+ t1, c, b, a, t1 &+ t2
    end
    @state[0] &+= a; @state[1] &+= b; @state[2] &+= c; @state[3] &+= d
    @state[4] &+= e; @state[5] &+= f; @state[6] &+= g; @state[7] &+= h
  end

  private def rotr(x : UInt32, n : Int32) : UInt32
    (x >> n) | (x << (32 - n))
  end
end
