// WasapiCapture.h
//
// Captures PCM from a WASAPI endpoint (the virtual cable's recording side) in shared,
// event-driven mode and pushes interleaved samples into a RingBuffer. Runs on its own
// thread; this is the producer / input-clock side of the pipeline.
#pragma once

#include "ComUtil.h"
#include "RingBuffer.h"
#include "AudioWorkerHealth.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>

#include <atomic>
#include <array>
#include <thread>

struct CaptureFormat
{
  unsigned channels = 0;
  unsigned sampleRate = 0;
  unsigned bits = 0;       // bits per sample in the captured stream
  bool     isFloat = false;
  uint32_t channelMask = 0; // WASAPI speaker mask (0 if unknown)

  size_t bytesPerFrame() const { return static_cast<size_t>(channels) * (bits / 8); }
};

class WasapiCapture
{
public:
  WasapiCapture() = default;
  ~WasapiCapture();

  // Opens `dev` for shared capture and learns its mix format.
  //   loopback == false: a real capture endpoint, event-driven.
  //   loopback == true : a RENDER endpoint captured via AUDCLNT_STREAMFLAGS_LOOPBACK (polled;
  //                      loopback streams don't support event-driven mode). This is how the
  //                      engine reads the virtual 5.1 sink's mix.
  bool Init(IMMDevice* dev, bool loopback = false, bool followEndpointVolume = false);
  // Destination ring for captured samples (set before Start, once it can be sized).
  void SetRing(RingBuffer* ring) { ring_ = ring; }
  bool Start();
  void Stop();
  const AudioWorkerHealth& Health() const { return health_; }

  const CaptureFormat& Format() const { return fmt_; }
  // Raw source peaks, before Windows gain/mute, for local diagnostics only.
  std::array<float, 6> ReadSignalPeaks() {
    std::array<float, 6> result{};
    for(size_t i=0;i<result.size();++i) result[i]=signalPeaks_[i].exchange(0);
    return result;
  }

private:
  friend struct AudioWorkerTest;
  void ThreadProc();

  RingBuffer*               ring_ = nullptr;
  ComPtr<IAudioClient>      client_;
  ComPtr<IAudioCaptureClient> capture_;
  ComPtr<IAudioEndpointVolume> volume_;
  CaptureFormat             fmt_;

  bool                      loopback_ = false;
  HANDLE                    dataEvent_ = nullptr;
  HANDLE                    stopEvent_ = nullptr;
  std::thread               thread_;
  std::atomic_bool          running_{false};
  AudioWorkerHealth health_;
  std::array<std::atomic<float>, 6> signalPeaks_{};
};
