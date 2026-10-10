#pragma once
#include <cmath>
#include <cstddef>
#include <cstring>

// Windows' scalar is audio-tapered; dB is the amplitude conversion. Zero and
// mute must be exact digital silence, without modifying encoded carrier bytes.
inline float EndpointGain(float db, float scalar, bool muted)
{
  if (muted || scalar <= 0 || !std::isfinite(db) || !std::isfinite(scalar)) return 0;
  return std::pow(10.0f, (db < 0 ? db : 0) / 20.0f);
}

inline void ApplyPcmVolume(void* destination, const void* source, size_t bytes, float gain)
{
  if (gain <= 0 || !std::isfinite(gain) || bytes % sizeof(float)) {
    std::memset(destination, 0, bytes); return;
  }
  for (size_t offset = 0; offset < bytes; offset += sizeof(float)) {
    float sample;
    std::memcpy(&sample, static_cast<const unsigned char*>(source) + offset, sizeof(sample));
    sample *= gain;
    if (!std::isfinite(sample)) sample = 0;
    std::memcpy(static_cast<unsigned char*>(destination) + offset, &sample, sizeof(sample));
  }
}
