#include "doctest.h"
#include "Ac3Formats.h"
#include <audioclient.h>
#include <vector>

TEST_CASE("AC3 negotiation continues after accepted query but failed initialization")
{
  std::vector<Ac3Formats::Kind> attempted;
  HRESULT last = E_FAIL;
  // C-Media reproducer: capability query succeeds, Initialize rejects first format.
  const bool opened = Ac3Formats::Negotiate(48000, [&](auto kind, const WAVEFORMATEX&) {
    attempted.push_back(kind);
    const HRESULT supportedQuery = S_OK;
    REQUIRE(supportedQuery == S_OK);
    return attempted.size() == 1 ? AUDCLNT_E_UNSUPPORTED_FORMAT : S_OK;
  }, last);
  REQUIRE(opened);
  REQUIRE(attempted.size() == 2);
  CHECK(attempted[0] == Ac3Formats::Kind::Extended);
  CHECK(attempted[1] == Ac3Formats::Kind::PlainEncodedMask);
  CHECK(last == S_OK);
}

TEST_CASE("AC3 negotiation reaches legacy format and fails safely if none initialize")
{
  int attempts = 0;
  HRESULT last = S_OK;
  CHECK_FALSE(Ac3Formats::Negotiate(48000, [&](auto, const WAVEFORMATEX&) {
    ++attempts;
    return AUDCLNT_E_UNSUPPORTED_FORMAT;
  }, last));
  CHECK(attempts == 4);
  CHECK(last == AUDCLNT_E_UNSUPPORTED_FORMAT);
  attempts = 0;
  CHECK(Ac3Formats::Negotiate(48000, [&](auto kind, const WAVEFORMATEX&) {
    ++attempts;
    return kind == Ac3Formats::Kind::Legacy ? S_OK : AUDCLNT_E_UNSUPPORTED_FORMAT;
  }, last));
  CHECK(attempts == 4);
}

TEST_CASE("every AC3 candidate declares encoded audio with correct carrier fields")
{
  for (auto kind : Ac3Formats::kCandidates) {
    const auto w = Ac3Formats::Make(48000, kind);
    const auto& x = w.FormatExt;
    CHECK(x.Format.nChannels == 2);
    CHECK(x.Format.nSamplesPerSec == 48000);
    CHECK(x.Format.wBitsPerSample == 16);
    CHECK(x.Format.nBlockAlign == 4);
    CHECK(x.Format.nAvgBytesPerSec == 192000);
    CHECK(x.Format.wFormatTag != WAVE_FORMAT_PCM);
    if (kind == Ac3Formats::Kind::Legacy) {
      CHECK(x.Format.wFormatTag == 0x0092);
      CHECK(x.Format.cbSize == 0);
    } else {
      CHECK(x.Format.wFormatTag == WAVE_FORMAT_EXTENSIBLE);
      CHECK(IsEqualGUID(x.SubFormat, KSDATAFORMAT_SUBTYPE_IEC61937_DOLBY_DIGITAL));
      CHECK(x.Samples.wValidBitsPerSample == 16);
      CHECK(x.dwChannelMask == (kind == Ac3Formats::Kind::PlainCarrierMask ? KSAUDIO_SPEAKER_STEREO : KSAUDIO_SPEAKER_5POINT1));
      if (kind == Ac3Formats::Kind::Extended) {
        CHECK(x.Format.cbSize == sizeof(w) - sizeof(WAVEFORMATEX));
        CHECK(w.dwEncodedSamplesPerSec == 48000);
        CHECK(w.dwEncodedChannelCount == 6);
      } else {
        CHECK(x.Format.cbSize == sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX));
      }
    }
  }
}
