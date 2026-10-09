#include "doctest.h"
#include "PcmVolume.h"
#include <array>
#include <limits>

TEST_CASE("Windows dB gain and exact volume-zero/mute silence")
{
  CHECK(EndpointGain(0, 1, false) == doctest::Approx(1));
  CHECK(EndpointGain(-20, .1f, false) == doctest::Approx(.1));
  CHECK(EndpointGain(-14.6628065f, .38f, false) == doctest::Approx(.184868));
  CHECK(EndpointGain(-96, 0, false) == 0);
  CHECK(EndpointGain(0, 1, true) == 0);
  CHECK(EndpointGain(std::numeric_limits<float>::quiet_NaN(), 1, false) == 0);
  CHECK(EndpointGain(10, 1, false) == 1);
}

TEST_CASE("Volume preserves all six interleaved channels and the source packet")
{
  const std::array<float, 12> source{.1f, -.2f, .3f, -.4f, .5f, -.6f,
                                    -.7f, .8f, -.9f, 1.f, -.1f, .2f};
  std::array<float, 12> output{};
  for (float gain : {1.f, .1f, 0.f}) {
    ApplyPcmVolume(output.data(), source.data(), sizeof(source), gain);
    for (size_t i = 0; i < source.size(); ++i)
      CHECK(output[i] == doctest::Approx(source[i] * gain));
  }
  CHECK(source[5] == -.6f);
  CHECK(source[11] == .2f);
}
