// test_encoder.cpp — contract tests for SpdifEncoder (PCM -> AC3 -> IEC 61937).
#include "doctest.h"
#include "SpdifEncoder.h"

struct SpdifEncoderTestAccess {
  static int Write(SpdifEncoder& encoder, uint8_t* destination, int capacity,
                   const uint8_t* source, int count) {
    encoder.writeDst_ = destination;
    encoder.writeCap_ = capacity;
    encoder.writeLen_ = 0;
    return encoder.OnWritePacket(source, count);
  }
};

extern "C" {
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
}

#include <cstdint>
#include <vector>

namespace {

// IEC 61937 burst preamble Pa=0xF872, Pb=0x4E1F. Accept either byte order, since the
// only thing that matters is that the muxer produced a real burst (Phase 1 already
// proved ffmpeg can demux/decode it back to AC3).
bool HasIec61937Sync(const uint8_t* b)
{
  const bool le = (b[0] == 0x72 && b[1] == 0xF8 && b[2] == 0x1F && b[3] == 0x4E);
  const bool be = (b[0] == 0xF8 && b[1] == 0x72 && b[2] == 0x4E && b[3] == 0x1F);
  return le || be;
}

// Helper: init an encoder for `channels` interleaved samples in `fmt`.
bool InitFor(SpdifEncoder& enc, int channels, AVSampleFormat fmt, int rate = 48000)
{
  SpdifEncoder::Params p;
  p.sampleRate = rate;
  p.inSampleFmt = fmt;
  av_channel_layout_default(&p.inLayout, channels);
  bool ok = enc.Init(p);
  av_channel_layout_uninit(&p.inLayout);
  return ok;
}

} // namespace

TEST_CASE("init: 5.1 float")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 6, AV_SAMPLE_FMT_FLT));
  CHECK(enc.IsOpen());
  CHECK(enc.FramesPerPacket() == 1536);
  CHECK(enc.InChannels() == 6);
}

TEST_CASE("encode: 5.1 float -> 6144-byte IEC 61937 burst")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 6, AV_SAMPLE_FMT_FLT));
  std::vector<float> in(static_cast<size_t>(enc.FramesPerPacket()) * 6, 0.25f);
  std::vector<uint8_t> out(SpdifEncoder::kMaxBytesPerPacket);
  int n = enc.EncodePacket(reinterpret_cast<uint8_t*>(in.data()), out.data(),
                           static_cast<int>(out.size()));
  REQUIRE(n > 0);
  CHECK(n == 6144);
  CHECK(HasIec61937Sync(out.data()));
}

TEST_CASE("encode: 7.1 input is downmixed to 5.1")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 8, AV_SAMPLE_FMT_FLT));
  CHECK(enc.InChannels() == 8);
  std::vector<float> in(static_cast<size_t>(enc.FramesPerPacket()) * 8, 0.1f);
  std::vector<uint8_t> out(SpdifEncoder::kMaxBytesPerPacket);
  int n = enc.EncodePacket(reinterpret_cast<uint8_t*>(in.data()), out.data(),
                           static_cast<int>(out.size()));
  CHECK(n > 0);
  CHECK(HasIec61937Sync(out.data()));
}

TEST_CASE("encode: stereo input is accepted")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 2, AV_SAMPLE_FMT_FLT));
  std::vector<float> in(static_cast<size_t>(enc.FramesPerPacket()) * 2, 0.1f);
  std::vector<uint8_t> out(SpdifEncoder::kMaxBytesPerPacket);
  CHECK(enc.EncodePacket(reinterpret_cast<uint8_t*>(in.data()), out.data(),
                         static_cast<int>(out.size())) > 0);
}

TEST_CASE("encode: 16-bit integer input is accepted")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 6, AV_SAMPLE_FMT_S16));
  std::vector<int16_t> in(static_cast<size_t>(enc.FramesPerPacket()) * 6, 1000);
  std::vector<uint8_t> out(SpdifEncoder::kMaxBytesPerPacket);
  int n = enc.EncodePacket(reinterpret_cast<uint8_t*>(in.data()), out.data(),
                           static_cast<int>(out.size()));
  CHECK(n > 0);
  CHECK(HasIec61937Sync(out.data()));
}

TEST_CASE("encode: consecutive packets keep producing bursts")
{
  SpdifEncoder enc;
  REQUIRE(InitFor(enc, 6, AV_SAMPLE_FMT_FLT));
  std::vector<float> in(static_cast<size_t>(enc.FramesPerPacket()) * 6, 0.2f);
  std::vector<uint8_t> out(SpdifEncoder::kMaxBytesPerPacket);
  int produced = 0;
  for (int i = 0; i < 10; ++i)
    if (enc.EncodePacket(reinterpret_cast<uint8_t*>(in.data()), out.data(),
                         static_cast<int>(out.size())) == 6144)
      ++produced;
  CHECK(produced >= 9); // allow at most one priming call to yield nothing
}

TEST_CASE("init: AC3-invalid sample rate fails cleanly")
{
  SpdifEncoder enc;
  CHECK_FALSE(InitFor(enc, 6, AV_SAMPLE_FMT_FLT, 96000)); // AC3 supports 48/44.1/32k only
  CHECK_FALSE(enc.IsOpen());
}

TEST_CASE("muxer overflow rejects the complete write without reporting false success")
{
  SpdifEncoder encoder;
  const uint8_t source[8] = {1,2,3,4,5,6,7,8};
  uint8_t destination[6] = {9,9,9,9,9,9};
  CHECK(SpdifEncoderTestAccess::Write(encoder, destination, 4, source, 8) < 0);
  for (uint8_t value : destination) CHECK(value == 9);
  CHECK(SpdifEncoderTestAccess::Write(encoder, destination, 4, source, 4) == 4);
  CHECK(destination[0] == 1);
  CHECK(destination[3] == 4);
  CHECK(destination[4] == 9);
}

TEST_CASE("encoder rejects unsafe parameter combinations and can reopen after failure")
{
  SpdifEncoder encoder;
  SpdifEncoder::Params p;
  av_channel_layout_default(&p.inLayout, 6);
  p.inSampleFmt = AV_SAMPLE_FMT_FLTP; // EncodePacket accepts one interleaved plane.
  CHECK_FALSE(encoder.Init(p));
  CHECK_FALSE(encoder.IsOpen());
  p.inSampleFmt = AV_SAMPLE_FMT_FLT;
  p.bitRate = 640001;
  CHECK_FALSE(encoder.Init(p));
  p.bitRate = 0;
  CHECK_FALSE(encoder.Init(p));
  p.bitRate = 448000;
  REQUIRE(encoder.Init(p));
  CHECK(encoder.IsOpen());
  std::vector<float> input(1536 * 6);
  std::vector<uint8_t> output(6144);
  CHECK(encoder.EncodePacket(nullptr, output.data(), 6144) < 0);
  CHECK(encoder.EncodePacket(reinterpret_cast<uint8_t*>(input.data()), nullptr, 6144) < 0);
  CHECK(encoder.EncodePacket(reinterpret_cast<uint8_t*>(input.data()), output.data(), 6143) < 0);
  CHECK(encoder.EncodePacket(reinterpret_cast<uint8_t*>(input.data()), output.data(), 6144) == 6144);
  av_channel_layout_uninit(&p.inLayout);
  encoder.Close();
  CHECK_FALSE(encoder.IsOpen());
}

// (The surround upmix is covered by a meaningful behavioral test in test_upmix.cpp:
//  it decodes the AC3 output and checks that energy actually lands in the surround channels.)
