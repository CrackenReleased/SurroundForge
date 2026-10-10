// WasapiCapture.cpp — see WasapiCapture.h.
#include "WasapiCapture.h"
#include "PcmVolume.h"

#include <mmreg.h>
#include <ksmedia.h>

#include <avrt.h>
#include <vector>

WasapiCapture::~WasapiCapture()
{
  Stop();
  if (dataEvent_) CloseHandle(dataEvent_);
  if (stopEvent_) CloseHandle(stopEvent_);
}

bool WasapiCapture::Init(IMMDevice* dev, bool loopback, bool followEndpointVolume)
{
  loopback_ = loopback;
  HR_FAIL(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_), "Activate IAudioClient");

  WAVEFORMATEX* mix = nullptr;
  HR_FAIL(client_->GetMixFormat(&mix), "GetMixFormat");

  fmt_.channels = mix->nChannels;
  fmt_.sampleRate = mix->nSamplesPerSec;
  fmt_.bits = mix->wBitsPerSample;
  fmt_.isFloat = (mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
  if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE && mix->cbSize >= 22)
  {
    auto* ext = reinterpret_cast<WAVEFORMATEXTENSIBLE*>(mix);
    fmt_.channelMask = ext->dwChannelMask;
    fmt_.isFloat = (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
  }
  if(!fmt_.channels || fmt_.channels>64 || !fmt_.sampleRate || !fmt_.bytesPerFrame() ||
     (fmt_.isFloat?fmt_.bits!=32:(fmt_.bits!=16 && fmt_.bits!=32))) {
    CoTaskMemFree(mix);std::fputs("Unsupported capture PCM format.\n",stderr);return false;
  }

  // Shared mode. Loopback streams cannot be event-driven, so they are polled instead.
  // periodicity must be 0 in shared mode.
  const DWORD flags = loopback_ ? AUDCLNT_STREAMFLAGS_LOOPBACK : AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
  REFERENCE_TIME bufferHns = 200000; // 20 ms; WASAPI may enlarge as needed
  HRESULT hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, bufferHns, 0, mix, nullptr);
  CoTaskMemFree(mix);
  if (FAILED(hr)) { std::fprintf(stderr, "[WasapiCapture] Initialize failed: %s\n", HrStr(hr).c_str()); return false; }

  if (followEndpointVolume) {
    if (!loopback || !fmt_.isFloat || fmt_.bits != 32) {
      std::fputs("[WasapiCapture] Endpoint gain requires 32-bit float render loopback.\n", stderr);
      return false;
    }
    HR_FAIL(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, &volume_), "Activate endpoint volume");
    std::puts("[WasapiCapture] Following Windows input endpoint volume and mute before AC3 encoding.");
  }

  stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr); // manual-reset
  if (!stopEvent_) return false;
  if (!loopback_)
  {
    dataEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!dataEvent_) return false;
    HR_FAIL(client_->SetEventHandle(dataEvent_), "SetEventHandle");
  }
  HR_FAIL(client_->GetService(__uuidof(IAudioCaptureClient), &capture_), "GetService(IAudioCaptureClient)");

  std::printf("[WasapiCapture] %s: %u ch, %u Hz, %u-bit %s, mask=0x%X\n",
              loopback_ ? "loopback" : "capture", fmt_.channels, fmt_.sampleRate, fmt_.bits,
              fmt_.isFloat ? "float" : "int", fmt_.channelMask);
  return true;
}

bool WasapiCapture::Start()
{
  if(health_.Failed())return false;
  if (!ring_)
  {
    std::fprintf(stderr, "[WasapiCapture] SetRing() not called before Start()\n");
    return false;
  }
  if (running_.exchange(true))
    return true;
  if(!ResetEvent(stopEvent_)) { health_.Fail("capture_reset_event",HRESULT_FROM_WIN32(GetLastError()));running_=false;return false; }
  if(!health_.Check(client_->Start(),"capture_start")) { running_=false;return false; }
  try {
    thread_=std::thread([this] {
      try { ThreadProc(); }
      catch(...) { health_.Fail("capture_worker_exception"); }
      running_=false;
    });
  } catch(...) { health_.Fail("capture_start_exception");running_=false;client_->Stop();return false; }
  return true;
}

void WasapiCapture::Stop()
{
  running_=false;
  if (stopEvent_) SetEvent(stopEvent_);
  if (thread_.joinable()) thread_.join();
  if (client_) client_->Stop();
}

void WasapiCapture::ThreadProc()
{
  ComApartment apartment;
  if(!health_.Check(apartment.hr,"capture_com_init"))return;
  AudioThreadPriority priority;

  const size_t bpf = fmt_.bytesPerFrame();
  std::vector<uint8_t> scaled;

  auto drain = [&]() {
    ++health_.progress;
    float gain = 1;
    if (volume_) {
      float db = 0, scalar = 0; BOOL muted = TRUE;
      const bool ok = SUCCEEDED(volume_->GetMasterVolumeLevel(&db)) &&
        SUCCEEDED(volume_->GetMasterVolumeLevelScalar(&scalar)) && SUCCEEDED(volume_->GetMute(&muted));
      const bool readable=ok && std::isfinite(db) && std::isfinite(scalar) && scalar>=0 && scalar<=1;
      gain = health_.VolumeRead(readable,AudioNowMs()) ? EndpointGain(db, scalar, muted != FALSE) : 0;
      if(health_.Failed())return;
    }
    UINT32 packet = 0;
    while (running_.load() && health_.Check(capture_->GetNextPacketSize(&packet),"capture_next_packet") && packet > 0)
    {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      const HRESULT bufferHr=capture_->GetBuffer(&data,&frames,&flags,nullptr,nullptr);
      if(bufferHr==AUDCLNT_S_BUFFER_EMPTY)break; // legitimate race: no acquired buffer
      if (!health_.Check(bufferHr,"capture_get_buffer"))
        break;

      health_.frames+=frames;
      if(flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)++health_.discontinuities;

      const size_t bytes = static_cast<size_t>(frames) * bpf;
      auto write=[&](const void* samples) { if(ring_->Write(samples,bytes)!=bytes)++health_.droppedPackets; };
      try {
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT)
      {
        // Push silence so the timeline stays continuous.
        static thread_local std::vector<uint8_t> zeros;
        if (zeros.size() < bytes) zeros.assign(bytes, 0);
        write(zeros.data());
      }
      else if (data)
      {
        if (fmt_.isFloat && fmt_.bits == 32 && fmt_.channels == 6) {
          std::array<float, 6> peaks{};
          const auto* pcm = reinterpret_cast<const float*>(data);
          for(size_t i=0;i<static_cast<size_t>(frames)*6;++i) {
            const float value=std::abs(pcm[i]);
            if(std::isfinite(value)) peaks[i%6]=std::max(peaks[i%6],value);
          }
          for(size_t i=0;i<peaks.size();++i) {
            float previous=signalPeaks_[i].load();
            while(previous<peaks[i] && !signalPeaks_[i].compare_exchange_weak(previous,peaks[i])) {}
          }
        }
        if (volume_) {
          if (scaled.size() < bytes) scaled.resize(bytes);
          ApplyPcmVolume(scaled.data(), data, bytes, gain);
          write(scaled.data());
        } else {
          write(data); // overflow drops the whole packet (consumer trims drift)
        }
      }
      else health_.Fail("capture_null_buffer");
      } catch(...) { capture_->ReleaseBuffer(frames);throw; }
      if(!health_.Check(capture_->ReleaseBuffer(frames),"capture_release_buffer") || health_.Failed())break;
      ++health_.progress; // large backlogs still demonstrate a responsive capture worker
    }
  };

  if (loopback_)
  {
    // Loopback streams aren't event-driven: poll, waking early if asked to stop.
    while (running_.load(std::memory_order_relaxed) && !health_.Failed())
    {
      const DWORD wait=WaitForSingleObject(stopEvent_,5);
      if (wait == WAIT_OBJECT_0) // ~5 ms poll
        break;
      if(wait!=WAIT_TIMEOUT) { health_.Fail("capture_wait_failed",HRESULT_FROM_WIN32(GetLastError()));break; }
      drain();
    }
  }
  else
  {
    HANDLE waits[2] = { dataEvent_, stopEvent_ };
    while (running_.load(std::memory_order_relaxed) && !health_.Failed())
    {
      DWORD w = WaitForMultipleObjects(2, waits, FALSE, 1000);
      if (w == WAIT_OBJECT_0 + 1) // stop
        break;
      if(w!=WAIT_OBJECT_0 && w!=WAIT_TIMEOUT) { health_.Fail("capture_wait_failed",HRESULT_FROM_WIN32(GetLastError()));break; }
      drain();
    }
  }

}
