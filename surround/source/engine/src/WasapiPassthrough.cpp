// WasapiPassthrough.cpp — see WasapiPassthrough.h.
#include "WasapiPassthrough.h"
#include "Ac3Formats.h"

#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <avrt.h>

extern "C" {
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
}

namespace {

AVSampleFormat MapSampleFmt(const CaptureFormat& f)
{
  if (f.isFloat && f.bits == 32) return AV_SAMPLE_FMT_FLT;
  if (!f.isFloat && f.bits == 16) return AV_SAMPLE_FMT_S16;
  if (!f.isFloat && f.bits == 32) return AV_SAMPLE_FMT_S32;
  return AV_SAMPLE_FMT_NONE;
}

} // namespace

WasapiPassthrough::~WasapiPassthrough()
{
  Stop();
  if (dataEvent_) CloseHandle(dataEvent_);
  if (stopEvent_) CloseHandle(stopEvent_);
}

bool WasapiPassthrough::ProbeAc3(IMMDevice* dev, int rate)
{
  ComPtr<IAudioClient> c;
  if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &c)))
    return false;
  for (const auto kind : Ac3Formats::kCandidates) {
    auto w = Ac3Formats::Make(rate, kind);
    if (c->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &w.FormatExt.Format, nullptr) == S_OK)
      return true;
  }
  return false;
}

bool WasapiPassthrough::Init(IMMDevice* dev, RingBuffer* ring, const CaptureFormat& capFmt,
                             const Params& p)
{
  dev_ = dev;
  ring_ = ring;
  capFmt_ = capFmt;
  params_ = p;
  capBytesPerFrame_ = capFmt.bytesPerFrame();
  if(!ring_ || !capBytesPerFrame_ || p.safeFrames>8*1536)return false;

  const int rate = static_cast<int>(capFmt.sampleRate);
  if (rate != 48000 && rate != 44100 && rate != 32000)
  {
    std::fprintf(stderr, "[WasapiPassthrough] capture rate %d unsupported for AC3 "
                         "(need 48000/44100/32000). Set the virtual device to 48 kHz.\n", rate);
    return false;
  }

  AVSampleFormat inFmt = MapSampleFmt(capFmt);
  if (inFmt == AV_SAMPLE_FMT_NONE)
  {
    std::fprintf(stderr, "[WasapiPassthrough] unsupported capture sample format (%u-bit %s)\n",
                 capFmt.bits, capFmt.isFloat ? "float" : "int");
    return false;
  }

  // Configure the encoder. Input = the capture layout; downmixed to 5.1 internally.
  SpdifEncoder::Params ep;
  ep.sampleRate = rate;
  ep.bitRate = params_.bitRate;
  ep.inSampleFmt = inFmt;
  ep.upmix = params_.upmixSurround ? SpdifEncoder::Upmix::Surround : SpdifEncoder::Upmix::Off;
  if (capFmt.channelMask)
    av_channel_layout_from_mask(&ep.inLayout, capFmt.channelMask);
  else
    av_channel_layout_default(&ep.inLayout, static_cast<int>(capFmt.channels));

  bool encOk = enc_.Init(ep);
  av_channel_layout_uninit(&ep.inLayout);
  if (!encOk)
    return false;
  framesPerPacket_ = enc_.FramesPerPacket();

  if (!InitExclusive(rate))
    return false;

  const size_t pktBytes = static_cast<size_t>(framesPerPacket_) * capBytesPerFrame_;
  staging_.resize(pktBytes);
  silence_.assign(pktBytes, 0);
  burst_.resize(kBurstBytes);
  return true;
}

bool WasapiPassthrough::InitExclusive(int rate)
{
  HRESULT last = E_FAIL;
  const bool opened = Ac3Formats::Negotiate(rate, [&](Ac3Formats::Kind kind, const WAVEFORMATEX& format) -> HRESULT {
    // Every candidate starts with a new client. A successful IsFormatSupported query
    // does not guarantee Initialize succeeds, especially on older USB audio drivers.
    client_.Reset();
    HRESULT hr = dev_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
    if (FAILED(hr)) return hr;
    hr = client_->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &format, nullptr);
    if (hr != S_OK) {
      std::printf("[WasapiPassthrough] %s query rejected: %s\n", Ac3Formats::Name(kind), HrStr(hr).c_str());
      return hr;
    }
    REFERENCE_TIME defPeriod = 0;
    hr = client_->GetDevicePeriod(&defPeriod, nullptr);
    if (FAILED(hr)) return hr;
    if (defPeriod <= 0) return E_UNEXPECTED;
    const REFERENCE_TIME burstHns = static_cast<REFERENCE_TIME>(10000000.0 * framesPerPacket_ / rate + 0.5);
    // Queue three bursts so a delayed wake can catch up from actual device space.
    // USB event callbacks can change cadence while the device still consumes 48 kHz.
    REFERENCE_TIME bufferHns = 3 * burstHns > defPeriod ? 3 * burstHns : defPeriod;
    for (int retry = 0; retry < 16 && bufferHns >= defPeriod; ++retry) {
      if (retry) {
        // Failed Initialize can poison the client; alignment and size retries also
        // require fresh activation rather than reusing that COM object.
        client_.Reset();
        hr = dev_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
        if (FAILED(hr)) return hr;
      }
      hr = client_->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE,
                              AUDCLNT_STREAMFLAGS_NOPERSIST,
                              bufferHns, defPeriod, &format, nullptr);
      if (SUCCEEDED(hr)) {
        std::printf("[WasapiPassthrough] AC3 stream initialized: %s\n", Ac3Formats::Name(kind));
        return S_OK;
      }
      if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
        UINT32 aligned = 0;
        const HRESULT sizeHr = client_->GetBufferSize(&aligned);
        if (FAILED(sizeHr) || !aligned) return FAILED(sizeHr) ? sizeHr : E_UNEXPECTED;
        bufferHns = static_cast<REFERENCE_TIME>(10000000.0 * aligned / rate + 0.5);
      } else if (hr == AUDCLNT_E_BUFFER_SIZE_ERROR || hr == AUDCLNT_E_INVALID_DEVICE_PERIOD || hr == E_OUTOFMEMORY) {
        bufferHns -= defPeriod;
      } else {
        break;
      }
    }
    std::printf("[WasapiPassthrough] %s Initialize rejected: %s; trying next encoded format\n",
                Ac3Formats::Name(kind), HrStr(hr).c_str());
    return hr;
  }, last);
  if (!opened) {
    client_.Reset();
    std::fprintf(stderr, "[WasapiPassthrough] all encoded AC3 formats failed to initialize: %s\n", HrStr(last).c_str());
    return false;
  }

  HR_FAIL(client_->GetBufferSize(&bufferFrames_), "GetBufferSize");
  burstsPerCycle_ = static_cast<int>(bufferFrames_ / framesPerPacket_);
  if (burstsPerCycle_ < 2)
  {
    std::fprintf(stderr, "[WasapiPassthrough] buffer (%u frames) cannot retain two AC3 bursts\n",
                 bufferFrames_);
    return false;
  }
  // Nonmultiple capacity is safe: only complete bursts are submitted, with no
  // zero padding between them. A high-resolution timer is local to this stream.
  dataEvent_ = CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_ALL_ACCESS);
  stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!dataEvent_ || !stopEvent_) return false;
  HR_FAIL(client_->GetService(__uuidof(IAudioRenderClient), &render_), "GetService(IAudioRenderClient)");

  std::printf("[WasapiPassthrough] timer-driven exclusive buffer = %u frames (%d queued bursts, ~%.1f ms)\n",
              bufferFrames_, burstsPerCycle_, 1000.0 * bufferFrames_ / rate);
  return true;
}

bool WasapiPassthrough::EncodeIntoBuffer(BYTE* out, UINT32 frames)
{
  const size_t pktBytes = staging_.size();
  size_t outOff = 0;
  for (UINT32 b = 0; b < frames / framesPerPacket_; ++b)
  {
    const uint8_t* in;
    if (ring_->BytesAvailable() >= pktBytes)
    {
      ring_->Read(staging_.data(), pktBytes);
      in = staging_.data();
    }
    else
    {
      in = silence_.data(); // underrun: emit AC3 silence, leave the ring to refill
      ++health_.underruns;
    }

    int n = enc_.EncodePacket(in, burst_.data(), static_cast<int>(burst_.size()));
    if (!health_.BurstSize(n,kBurstBytes))return false;
    if (n == 0)
    {
      std::memset(burst_.data(), 0, kBurstBytes); // priming / error: stuff zeros this slot
      n = kBurstBytes;
    }
    std::memcpy(out + outOff, burst_.data(), kBurstBytes);
    outOff += kBurstBytes;
  }

  return true;
}

bool WasapiPassthrough::RenderOnce()
{
  UINT32 padding=0;
  if(!health_.Check(client_->GetCurrentPadding(&padding),"render_get_padding"))return false;
  if(padding>bufferFrames_) { health_.Fail("render_invalid_padding");return false; }
  const UINT32 frames=(bufferFrames_-padding)/framesPerPacket_*framesPerPacket_;
  if(!frames)return true;
  BYTE* out=nullptr;
  const HRESULT hr=render_->GetBuffer(frames,&out);
  // A transient unavailable packet consumes no PCM and is retried on the timer.
  // No successful submissions for 15 seconds is detected by the existing watchdog.
  if(hr==AUDCLNT_E_BUFFER_ERROR)return true;
  if(!health_.Check(hr,"render_get_buffer"))return false;
  // Drift tracking is based on submitted bursts, never idle polling ticks.
  const uint32_t avail=static_cast<uint32_t>(ring_->BytesAvailable()/capBytesPerFrame_);
  minAvail_=std::min(minAvail_,avail);
  cycle_+=frames/framesPerPacket_;
  if(cycle_>=64) {
    const uint32_t desired=frames+params_.safeFrames;
    if(minAvail_>desired) {
      const uint32_t trim=minAvail_-desired;
      ring_->Discard(static_cast<size_t>(trim)*capBytesPerFrame_);
      health_.trimmedFrames+=trim;
    }
    cycle_=0;minAvail_=0xFFFFFFFFu;
  }
  bool encoded=false;
  try { encoded=out && EncodeIntoBuffer(out,frames); }
  catch(...) { render_->ReleaseBuffer(frames,AUDCLNT_BUFFERFLAGS_SILENT);throw; }
  if(!out)health_.Fail("render_null_buffer");
  const bool released=health_.Check(render_->ReleaseBuffer(frames,encoded?0:AUDCLNT_BUFFERFLAGS_SILENT),"render_release_buffer");
  if(encoded && released) { ++health_.progress;health_.frames+=frames; }
  return encoded && released;
}

bool WasapiPassthrough::Start()
{
  if(health_.Failed())return false;
  if (running_.exchange(true))
    return true;
  if(!ResetEvent(stopEvent_)) { health_.Fail("render_reset_event",HRESULT_FROM_WIN32(GetLastError()));running_=false;return false; }
  cycle_ = 0;
  minAvail_ = 0xFFFFFFFFu;
  LARGE_INTEGER due;due.QuadPart=-40000; // first wake in 4 ms, then every 4 ms
  if(!SetWaitableTimer(dataEvent_,&due,4,nullptr,nullptr,FALSE)) {
    health_.Fail("render_timer_start",HRESULT_FROM_WIN32(GetLastError()));running_=false;return false;
  }

  // Pre-fill the first buffer (primes the encoder and avoids an initial underrun) before Start.
  try {
    if(!RenderOnce() || !health_.Check(client_->Start(),"render_start")) {
      running_=false;return false;
    }
    thread_=std::thread([this] {
      try { ThreadProc(); }
      catch(...) { health_.Fail("render_worker_exception"); }
      running_=false;
    });
  } catch(...) {
    health_.Fail("render_start_exception");running_=false;client_->Stop();return false;
  }
  return true;
}

void WasapiPassthrough::Stop()
{
  running_=false;
  if (stopEvent_) SetEvent(stopEvent_);
  if (thread_.joinable()) thread_.join();
  if (dataEvent_) CancelWaitableTimer(dataEvent_);
  if (client_) client_->Stop();
}

void WasapiPassthrough::ThreadProc()
{
  ComApartment apartment;
  if(!health_.Check(apartment.hr,"render_com_init"))return;
  AudioThreadPriority priority;

  HANDLE waits[2] = { dataEvent_, stopEvent_ };

  while (running_.load(std::memory_order_relaxed))
  {
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, 2000);
    if(!health_.RenderWait(wr)) {
      if(wr==WAIT_OBJECT_0+1 || health_.Failed())break;
      continue;
    }

    if(!RenderOnce())break;
  }

}
