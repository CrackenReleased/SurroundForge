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
    REFERENCE_TIME bufferHns = burstHns > defPeriod ? burstHns : defPeriod;
    for (int retry = 0; retry < 16 && bufferHns >= defPeriod; ++retry) {
      if (retry) {
        // Failed Initialize can poison the client; alignment and size retries also
        // require fresh activation rather than reusing that COM object.
        client_.Reset();
        hr = dev_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client_);
        if (FAILED(hr)) return hr;
      }
      hr = client_->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE,
                              AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_NOPERSIST,
                              bufferHns, bufferHns, &format, nullptr);
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
  if (burstsPerCycle_ < 1)
  {
    std::fprintf(stderr, "[WasapiPassthrough] buffer (%u frames) smaller than one AC3 burst\n",
                 bufferFrames_);
    return false;
  }
  if (bufferFrames_ % framesPerPacket_ != 0)
    std::fprintf(stderr, "[WasapiPassthrough] note: buffer %u not a multiple of %d; "
                         "remainder will be zero-stuffed\n", bufferFrames_, framesPerPacket_);

  dataEvent_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!dataEvent_ || !stopEvent_) return false;
  HR_FAIL(client_->SetEventHandle(dataEvent_), "SetEventHandle");
  HR_FAIL(client_->GetService(__uuidof(IAudioRenderClient), &render_), "GetService(IAudioRenderClient)");

  std::printf("[WasapiPassthrough] exclusive buffer = %u frames (%d burst(s)/cycle, ~%.1f ms)\n",
              bufferFrames_, burstsPerCycle_, 1000.0 * bufferFrames_ / rate);
  return true;
}

void WasapiPassthrough::EncodeIntoBuffer(BYTE* out)
{
  const size_t pktBytes = staging_.size();
  size_t outOff = 0;
  for (int b = 0; b < burstsPerCycle_; ++b)
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
    }

    int n = enc_.EncodePacket(in, burst_.data(), static_cast<int>(burst_.size()));
    if (n <= 0)
    {
      std::memset(burst_.data(), 0, kBurstBytes); // priming / error: stuff zeros this slot
      n = kBurstBytes;
    }
    std::memcpy(out + outOff, burst_.data(), kBurstBytes);
    outOff += kBurstBytes;
  }

  const size_t totalBytes = static_cast<size_t>(bufferFrames_) * kCarrierBytesPerFrame;
  if (outOff < totalBytes)
    std::memset(out + outOff, 0, totalBytes - outOff); // inter-burst stuffing
}

bool WasapiPassthrough::Start()
{
  if (running_.exchange(true))
    return true;
  ResetEvent(stopEvent_);
  cycle_ = 0;
  minAvail_ = 0xFFFFFFFFu;

  // Pre-fill the first buffer (primes the encoder and avoids an initial underrun) before Start.
  BYTE* out = nullptr;
  if (SUCCEEDED(render_->GetBuffer(bufferFrames_, &out)))
  {
    EncodeIntoBuffer(out);
    render_->ReleaseBuffer(bufferFrames_, 0);
  }

  HR_FAIL(client_->Start(), "client Start");
  thread_ = std::thread(&WasapiPassthrough::ThreadProc, this);
  return true;
}

void WasapiPassthrough::Stop()
{
  if (!running_.exchange(false))
    return;
  if (stopEvent_) SetEvent(stopEvent_);
  if (thread_.joinable()) thread_.join();
  if (client_) client_->Stop();
}

void WasapiPassthrough::ThreadProc()
{
  DWORD taskIndex = 0;
  HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &taskIndex);

  const uint32_t required = static_cast<uint32_t>(burstsPerCycle_) * framesPerPacket_;
  const uint32_t desired = required + params_.safeFrames;
  HANDLE waits[2] = { dataEvent_, stopEvent_ };

  while (running_.load(std::memory_order_relaxed))
  {
    DWORD wr = WaitForMultipleObjects(2, waits, FALSE, 2000);
    if (wr == WAIT_OBJECT_0 + 1)
      break;
    if (wr == WAIT_TIMEOUT)
    {
      std::fprintf(stderr, "[WasapiPassthrough] render event timed out\n");
      continue;
    }

    // --- drift control (SoundPusher style) ---
    const uint32_t avail =
        static_cast<uint32_t>(ring_->BytesAvailable() / capBytesPerFrame_);
    if (avail < minAvail_)
      minAvail_ = avail;
    if (cycle_++ % 64 == 0)
    {
      if (minAvail_ != 0xFFFFFFFFu && minAvail_ > desired)
      {
        const uint32_t trim = minAvail_ - desired;
        ring_->Discard(static_cast<size_t>(trim) * capBytesPerFrame_);
      }
      minAvail_ = 0xFFFFFFFFu;
    }

    BYTE* out = nullptr;
    HRESULT hr = render_->GetBuffer(bufferFrames_, &out);
    if (FAILED(hr))
    {
      std::fprintf(stderr, "[WasapiPassthrough] GetBuffer failed: %s\n", HrStr(hr).c_str());
      break;
    }
    EncodeIntoBuffer(out);
    render_->ReleaseBuffer(bufferFrames_, 0);
  }

  if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
}
