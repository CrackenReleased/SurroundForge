#pragma once
#include "ComUtil.h"
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <array>

namespace Ac3Formats {
enum class Kind { Extended, PlainEncodedMask, PlainCarrierMask, Legacy };
inline constexpr std::array<Kind, 4> kCandidates = {
  Kind::Extended, Kind::PlainEncodedMask, Kind::PlainCarrierMask, Kind::Legacy
};

inline const char* Name(Kind kind)
{
  switch (kind) {
    case Kind::Extended: return "extended IEC61937";
    case Kind::PlainEncodedMask: return "plain extensible / encoded 5.1 mask";
    case Kind::PlainCarrierMask: return "plain extensible / stereo carrier mask";
    case Kind::Legacy: return "legacy AC3 S/PDIF tag 0x0092";
  }
  return "unknown";
}

inline WAVEFORMATEXTENSIBLE_IEC61937 Make(int rate, Kind kind)
{
  WAVEFORMATEXTENSIBLE_IEC61937 w{};
  auto& x = w.FormatExt;
  x.Format.wFormatTag = kind == Kind::Legacy ? WAVE_FORMAT_DOLBY_AC3_SPDIF : WAVE_FORMAT_EXTENSIBLE;
  x.Format.nChannels = 2;
  x.Format.nSamplesPerSec = rate;
  x.Format.wBitsPerSample = 16;
  x.Format.nBlockAlign = 4;
  x.Format.nAvgBytesPerSec = rate * 4;
  if (kind == Kind::Legacy) return w; // Plain WAVEFORMATEX: cbSize remains zero.
  x.Samples.wValidBitsPerSample = 16;
  x.dwChannelMask = kind == Kind::PlainCarrierMask ? KSAUDIO_SPEAKER_STEREO : KSAUDIO_SPEAKER_5POINT1;
  x.SubFormat = KSDATAFORMAT_SUBTYPE_IEC61937_DOLBY_DIGITAL;
  x.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
  if (kind == Kind::Extended) {
    x.Format.cbSize = sizeof(w) - sizeof(WAVEFORMATEX);
    w.dwEncodedSamplesPerSec = rate;
    w.dwEncodedChannelCount = 6;
  }
  return w;
}

// Success means an actual initialized stream, never merely a successful capability query.
// The callback owns fresh-client activation and alignment retries for each candidate.
template<class Attempt>
bool Negotiate(int rate, Attempt&& attempt, HRESULT& last)
{
  for (const auto kind : kCandidates) {
    auto format = Make(rate, kind);
    last = attempt(kind, format.FormatExt.Format);
    if (last == S_OK) return true;
  }
  return false;
}
}
