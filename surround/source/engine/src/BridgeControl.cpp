// Explicit native Core Audio controls for bridge start/stop scripts.
// IPolicyConfig ABI reference: github.com/frgnca/AudioDeviceCmdlets/blob/master/SOURCE/IPolicyConfig.cs
#include "ComUtil.h"
#include "DeviceEnum.h"
#include "CmediaOpticalControl.h"
#include "../test/WavFile.h"
#include <audioclient.h>
#include <audiopolicy.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <algorithm>
#include <cwctype>
#include <endpointvolume.h>
#include <devicetopology.h>
#include <functiondiscoverykeys_devpkey.h>
#include <cmath>

static std::string JsonString(const std::wstring& value)
{
  std::string result = "\"";
  for (const unsigned char c : Narrow(value.c_str())) {
    if (c == '\\' || c == '"') { result += '\\'; result += c; }
    else if (c < 0x20) {
      char escape[7]; std::snprintf(escape, sizeof(escape), "\\u%04x", c); result += escape;
    } else result += c;
  }
  return result + "\"";
}

static int Volume(IMMDevice* dev, const wchar_t* level = nullptr, const wchar_t* muteArg = nullptr)
{
  ComPtr<IAudioEndpointVolume> volume;
  HRESULT hr = dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, &volume);
  if (FAILED(hr)) return 1;
  if (level) {
    wchar_t* end = nullptr;
    const float scalar = std::wcstof(level, &end);
    if (end == level || *end || !std::isfinite(scalar) || scalar < 0 || scalar > 1 ||
        (std::wstring(muteArg) != L"0" && std::wstring(muteArg) != L"1")) return 2;
    hr = volume->SetMasterVolumeLevelScalar(scalar, nullptr);
    if (FAILED(hr)) return 1;
    hr = volume->SetMute(muteArg[0] == L'1', nullptr);
    if (FAILED(hr)) return 1;
  }
  float scalar = 0, db = 0; BOOL mute = FALSE; DWORD hardware = 0;
  if (FAILED(volume->GetMasterVolumeLevelScalar(&scalar)) || FAILED(volume->GetMasterVolumeLevel(&db)) ||
      FAILED(volume->GetMute(&mute)) || FAILED(volume->QueryHardwareSupport(&hardware))) return 1;
  std::printf("scalar=%.9g\ndb=%.9g\nmute=%d\nhardware=0x%lx\n", scalar, db, mute, hardware);
  return 0;
}

// Raw loopback measurement establishes whether the driver already applies master gain.
static int Measure(IMMDevice* dev, const wchar_t* duration)
{
  wchar_t* end = nullptr;
  long seconds = std::wcstol(duration, &end, 10);
  if (end == duration || *end || seconds < 1 || seconds > 10) return 2;
  ComPtr<IAudioClient> client;
  if (FAILED(dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client))) return 1;
  WAVEFORMATEX* format = nullptr;
  if (FAILED(client->GetMixFormat(&format))) return 1;
  const bool isFloat = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
    (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22 &&
     reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
  const UINT channels = format->nChannels;
  HRESULT hr = isFloat && format->wBitsPerSample == 32
    ? client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 200000, 0, format, nullptr)
    : E_INVALIDARG;
  CoTaskMemFree(format);
  if (FAILED(hr)) return 1;
  ComPtr<IAudioCaptureClient> capture;
  if (FAILED(client->GetService(__uuidof(IAudioCaptureClient), &capture)) || FAILED(client->Start())) return 1;
  double energy = 0, peak = 0; size_t count = 0;
  const ULONGLONG deadline = GetTickCount64() + seconds * 1000;
  while (GetTickCount64() < deadline) {
    UINT packet = 0;
    while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet) {
      BYTE* data = nullptr; UINT frames = 0; DWORD flags = 0;
      if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) { client->Stop(); return 1; }
      const size_t samples = static_cast<size_t>(frames) * channels;
      if (data && !(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
        const auto* pcm = reinterpret_cast<const float*>(data);
        for (size_t i = 0; i < samples; ++i) { energy += pcm[i] * pcm[i]; peak = std::max(peak, std::abs(double(pcm[i]))); }
      }
      count += samples;
      capture->ReleaseBuffer(frames);
    }
    Sleep(5);
  }
  client->Stop();
  std::printf("samples=%zu\nrms=%.9g\npeak=%.9g\n", count, count ? std::sqrt(energy/count) : 0, peak);
  return count ? 0 : 1;
}

struct __declspec(uuid("f8679f50-850a-41cf-9c72-430f290290c8")) IPolicyConfig : IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetMixFormat(PCWSTR, WAVEFORMATEX**) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetDeviceFormat(PCWSTR, INT, WAVEFORMATEX**) = 0;
  virtual HRESULT STDMETHODCALLTYPE ResetDeviceFormat(PCWSTR) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetDeviceFormat(PCWSTR, WAVEFORMATEX*, WAVEFORMATEX*) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetProcessingPeriod(PCWSTR, INT, INT64*, INT64*) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetProcessingPeriod(PCWSTR, INT64*) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetShareMode(PCWSTR, void*) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetShareMode(PCWSTR, void*) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetPropertyValue(PCWSTR, BOOL, const PROPERTYKEY&, PROPVARIANT*) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetPropertyValue(PCWSTR, BOOL, const PROPERTYKEY&, PROPVARIANT*) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetDefaultEndpoint(PCWSTR, ERole) = 0;
  virtual HRESULT STDMETHODCALLTYPE SetEndpointVisibility(PCWSTR, INT) = 0;
};
static const GUID kPolicyClient = {0x870af99c, 0x171d, 0x4f9e, {0xaf,0x0d,0xe6,0x3d,0xf4,0x0c,0x2b,0xc9}};

static int Failed(const char* what, HRESULT hr)
{
  std::fprintf(stderr, "%s failed: %s\n", what, HrStr(hr).c_str());
  return 1;
}

static const char* SessionStateName(AudioSessionState state)
{
  switch (state) {
    case AudioSessionStateInactive: return "inactive";
    case AudioSessionStateActive: return "active";
    case AudioSessionStateExpired: return "expired";
    default: return "unknown";
  }
}

// One read-only snapshot. A fresh invocation is needed to see newly created sessions.
// Never request session display names, identifiers, paths, or any setters.
static int Sessions(IMMDevice* dev)
{
  ComPtr<IAudioSessionManager2> manager;
  HRESULT hr = dev->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, &manager);
  if (FAILED(hr)) return Failed("Activate session manager", hr);
  ComPtr<IAudioSessionEnumerator> sessions;
  hr = manager->GetSessionEnumerator(&sessions);
  if (FAILED(hr)) return Failed("Get session enumerator", hr);
  int count = 0, reported = 0;
  hr = sessions->GetCount(&count);
  if (FAILED(hr)) return Failed("Get session count", hr);
  std::printf("session_count=%d\n", count);
  for (int i = 0; i < count; ++i) {
    ComPtr<IAudioSessionControl> control;
    ComPtr<IAudioSessionControl2> details;
    ComPtr<ISimpleAudioVolume> volume;
    DWORD pid = 0; AudioSessionState state = AudioSessionStateInactive;
    float scalar = 0; BOOL mute = FALSE; bool multipleProcesses = false;
    hr = sessions->GetSession(i, &control);
    if (SUCCEEDED(hr)) hr = control.As(&details);
    if (SUCCEEDED(hr)) {
      hr = details->GetProcessId(&pid);
      // SDK omits this named success constant; GetProcessId documentation defines it.
      multipleProcesses = hr == AUDCLNT_SUCCESS(0x00d);
    }
    if (SUCCEEDED(hr)) hr = control->GetState(&state);
    if (SUCCEEDED(hr)) hr = control.As(&volume);
    if (SUCCEEDED(hr)) hr = volume->GetMasterVolume(&scalar);
    if (SUCCEEDED(hr)) hr = volume->GetMute(&mute);
    if (FAILED(hr)) {
      // Sessions can expire during enumeration. Report the failure and continue.
      std::printf("session[%d].error=%s\n", i, HrStr(hr).c_str());
      continue;
    }
    std::printf("session[%d].pid=%lu\nsession[%d].state=%s\nsession[%d].volume=%.9g\nsession[%d].mute=%d\nsession[%d].multiple_processes=%d\n",
      i, pid, i, SessionStateName(state), i, scalar, i, mute, i, multipleProcesses);
    ++reported;
  }
  std::printf("session_reported=%d\nsession_errors=%d\n", reported, count - reported);
  return reported == count ? 0 : 1;
}

static HRESULT Mix(IMMDevice* dev, WAVEFORMATEX** out)
{
  ComPtr<IAudioClient> client;
  HRESULT hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
  return FAILED(hr) ? hr : client->GetMixFormat(out);
}

static int ShowFormat(IMMDevice* dev, const std::wstring& id)
{
  WAVEFORMATEX* format = nullptr;
  const HRESULT hr = Mix(dev, &format);
  if (FAILED(hr)) return Failed("GetMixFormat", hr);
  const DWORD mask = format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22
    ? reinterpret_cast<WAVEFORMATEXTENSIBLE*>(format)->dwChannelMask : 0;
  std::printf("id=%s\nchannels=%u\nrate=%lu\nbits=%u\nmask=0x%lx\n",
              Narrow(id.c_str()).c_str(), format->nChannels, format->nSamplesPerSec,
              format->wBitsPerSample, mask);
  CoTaskMemFree(format);
  return 0;
}

static bool IsCableInput(std::wstring name)
{
  std::transform(name.begin(), name.end(), name.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return name == L"cable input (vb-audio virtual cable)" ||
         name == L"cable in 16ch (vb-audio virtual cable)" ||
         name.find(L"surroundforge 5.1") == 0 ||
         name.find(L"virtual ac3 encoder") == 0;
}

static int SetVirtualVisibility(const std::wstring& id, bool visible)
{
  ComPtr<IMMDevice> dev;
  if (!DeviceEnum::GetById(id, dev)) {
    std::fputs("ID must exactly match an installed render endpoint.\n", stderr);
    return 2;
  }
  ComPtr<IMMEndpoint> endpoint;
  EDataFlow flow = eAll;
  if (FAILED(dev.As(&endpoint)) || FAILED(endpoint->GetDataFlow(&flow)) || flow != eRender) {
    std::fputs("Visibility is restricted to render endpoints.\n", stderr);
    return 2;
  }
  ComPtr<IPropertyStore> props;
  PROPVARIANT name{};
  const HRESULT nameHr = dev->OpenPropertyStore(STGM_READ, &props);
  if (FAILED(nameHr) || FAILED(props->GetValue(PKEY_Device_FriendlyName, &name)))
    return Failed("Read endpoint name", FAILED(nameHr) ? nameHr : E_FAIL);
  const bool allowed = name.vt == VT_LPWSTR && IsCableInput(name.pwszVal);
  PropVariantClear(&name);
  if (!allowed) {
    std::fputs("Visibility is restricted to a SurroundForge virtual input.\n", stderr);
    return 2;
  }
  ComPtr<IPolicyConfig> policy;
  HRESULT hr = CoCreateInstance(kPolicyClient, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&policy));
  if (FAILED(hr)) return Failed("PolicyConfig activation", hr);
  hr = policy->SetEndpointVisibility(id.c_str(), visible ? 1 : 0);
  if (FAILED(hr)) return Failed("SetEndpointVisibility", hr);
  DWORD state = 0;
  hr = dev->GetState(&state);
  if (FAILED(hr)) return Failed("Verify endpoint visibility", hr);
  if (visible ? (state != DEVICE_STATE_ACTIVE) : (state == DEVICE_STATE_ACTIVE))
    return Failed("Endpoint visibility did not change", E_FAIL);
  std::printf("visibility=%d\n", visible ? 1 : 0);
  return 0;
}

static WAVEFORMATEXTENSIBLE Pcm51()
{
  WAVEFORMATEXTENSIBLE format{};
  format.Format = {WAVE_FORMAT_EXTENSIBLE, 6, 48000, 576000, 12, 16, 22};
  format.Samples.wValidBitsPerSample = 16;
  format.dwChannelMask = 0x3f;
  format.SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
  return format;
}

// A six-channel count does not establish speaker assignments. Windows games also
// consume the endpoint speaker mask; an unassigned mask after reboot is not 5.1.
static bool IsMix51(const WAVEFORMATEX* format)
{
  return format && format->nChannels == 6 && format->nSamplesPerSec == 48000 &&
    format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22 &&
    reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format)->dwChannelMask == 0x3f;
}

static bool IsPhysical51(const PROPVARIANT& value)
{
  return value.vt == VT_UI4 && value.ulVal == 0x3f;
}

static HRESULT PersistSpeakerMask51(IPropertyStore* properties)
{
  PROPVARIANT value{};
  HRESULT hr = properties->GetValue(PKEY_AudioEndpoint_PhysicalSpeakers, &value);
  const bool already51 = SUCCEEDED(hr) && IsPhysical51(value);
  PropVariantClear(&value);
  if (FAILED(hr) || already51) return hr;
  value.vt = VT_UI4;
  value.ulVal = 0x3f;
  hr = properties->SetValue(PKEY_AudioEndpoint_PhysicalSpeakers, value);
  if (SUCCEEDED(hr)) hr = properties->Commit();
  if (FAILED(hr)) return hr;
  value = PROPVARIANT{};
  hr = properties->GetValue(PKEY_AudioEndpoint_PhysicalSpeakers, &value);
  const bool correct = SUCCEEDED(hr) && IsPhysical51(value);
  PropVariantClear(&value);
  return FAILED(hr) ? hr : correct ? S_OK : E_FAIL;
}

static HRESULT EnsureSpeakerMask51(IMMDevice* dev)
{
  ComPtr<IPropertyStore> properties;
  HRESULT hr = dev->OpenPropertyStore(STGM_READ, &properties);
  if (FAILED(hr)) return hr;
  PROPVARIANT value{};
  hr = properties->GetValue(PKEY_AudioEndpoint_PhysicalSpeakers, &value);
  const bool already51 = SUCCEEDED(hr) && IsPhysical51(value);
  PropVariantClear(&value);
  if (FAILED(hr) || already51) return hr;
  properties.Reset();
  // Documented IMMDevice API; administrative setup permission is required for
  // writes. Never guess an undocumented IPolicyConfig property-call ABI.
  hr = dev->OpenPropertyStore(STGM_READWRITE, &properties);
  if (FAILED(hr)) return hr;
  hr = PersistSpeakerMask51(properties.Get());
  if (FAILED(hr)) return hr;
  properties.Reset();
  hr = dev->OpenPropertyStore(STGM_READ, &properties);
  if (FAILED(hr)) return hr;
  hr = properties->GetValue(PKEY_AudioEndpoint_PhysicalSpeakers, &value);
  const bool persisted = SUCCEEDED(hr) && IsPhysical51(value);
  PropVariantClear(&value);
  return FAILED(hr) ? hr : persisted ? S_OK : E_FAIL;
}

// Documented, read-only discovery of a driver channel-configuration control.
// Only a subunit explicitly exposing IAudioChannelConfig can provide this path.
static std::vector<ComPtr<IAudioChannelConfig>> ChannelConfigControls(IMMDevice* dev)
{
  std::vector<ComPtr<IAudioChannelConfig>> controls;
  ComPtr<IDeviceTopology> topology;
  if (FAILED(dev->Activate(__uuidof(IDeviceTopology), CLSCTX_ALL, nullptr, &topology))) return controls;
  ComPtr<IConnector> connector, connected;
  ComPtr<IPart> connectedPart;
  if (SUCCEEDED(topology->GetConnector(0, &connector)) &&
      SUCCEEDED(connector->GetConnectedTo(&connected)) && SUCCEEDED(connected.As(&connectedPart))) {
    ComPtr<IDeviceTopology> adapter;
    if (SUCCEEDED(connectedPart->GetTopologyObject(&adapter))) topology = adapter;
  }
  UINT count = 0;
  if (FAILED(topology->GetSubunitCount(&count))) return controls;
  for (UINT i = 0; i < count; ++i) {
    ComPtr<ISubunit> subunit;
    ComPtr<IPart> part;
    ComPtr<IAudioChannelConfig> channel;
    if (SUCCEEDED(topology->GetSubunit(i, &subunit)) && SUCCEEDED(subunit.As(&part)) &&
        SUCCEEDED(part->Activate(CLSCTX_ALL, __uuidof(IAudioChannelConfig),
                                reinterpret_cast<void**>(channel.GetAddressOf())))) controls.push_back(channel);
  }
  return controls;
}

static int SpeakerInfo(IMMDevice* dev, const std::wstring& id)
{
  const int shown = ShowFormat(dev, id);
  if (shown) return shown;
  ComPtr<IPropertyStore> properties;
  HRESULT hr = dev->OpenPropertyStore(STGM_READ, &properties);
  if (FAILED(hr)) return Failed("Read speaker properties", hr);
  PROPVARIANT value{};
  hr = properties->GetValue(PKEY_AudioEndpoint_PhysicalSpeakers, &value);
  if (FAILED(hr)) return Failed("Read physical speaker mask", hr);
  const bool physical51 = IsPhysical51(value);
  std::printf("physical_present=%d\nphysical_mask=0x%lx\n", value.vt == VT_UI4,
              value.vt == VT_UI4 ? value.ulVal : 0UL);
  PropVariantClear(&value);
  WAVEFORMATEX* format = nullptr;
  hr = Mix(dev, &format);
  if (FAILED(hr)) return Failed("Verify speaker mix", hr);
  std::printf("mix_51=%d\nlayout_51=%d\n", IsMix51(format), IsMix51(format) && physical51);
  CoTaskMemFree(format);
  auto controls = ChannelConfigControls(dev);
  std::printf("channel_config_controls=%zu\n", controls.size());
  for (size_t i = 0; i < controls.size(); ++i) {
    DWORD mask = 0;
    hr = controls[i]->GetChannelConfig(&mask);
    if (SUCCEEDED(hr)) std::printf("channel_config_mask[%zu]=0x%lx\n", i, mask);
    else std::printf("channel_config_error[%zu]=%s\n", i, HrStr(hr).c_str());
  }
  return 0;
}

static int PlayWav(IMMDevice* dev, const wchar_t* path)
{
  WavFile wav;
  std::string error;
  if (!WavFile::Load(Narrow(path), wav, error)) {
    std::fprintf(stderr, "WAV load failed: %s\n", error.c_str()); return 1;
  }
  if (wav.channels != 6 || wav.sampleRate != 48000 || wav.bitsPerSample != 16 || wav.isFloat || !wav.numFrames()) {
    std::fputs("--play-wav requires a nonempty 6-channel 48 kHz 16-bit PCM WAV.\n", stderr); return 2;
  }
  ComPtr<IAudioClient> client;
  HRESULT hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
  if (FAILED(hr)) return Failed("Activate shared playback", hr);
  auto format = Pcm51();
  WAVEFORMATEX* closest = nullptr;
  hr = client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &format.Format, &closest);
  if (closest) CoTaskMemFree(closest);
  if (hr != S_OK) return Failed("Exact shared 6-channel playback support", hr);
  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_NOPERSIST,
                          1000000, 0, &format.Format, nullptr);
  if (FAILED(hr)) return Failed("Initialize shared playback", hr);
  UINT32 capacity = 0;
  hr = client->GetBufferSize(&capacity);
  if (FAILED(hr) || !capacity) return Failed("GetBufferSize", FAILED(hr) ? hr : E_UNEXPECTED);
  ComPtr<IAudioRenderClient> render;
  hr = client->GetService(__uuidof(IAudioRenderClient), &render);
  if (FAILED(hr)) return Failed("Get shared render service", hr);
  const UINT32 first = static_cast<UINT32>(std::min<size_t>(capacity, wav.numFrames()));
  BYTE* samples = nullptr;
  hr = render->GetBuffer(first, &samples);
  if (FAILED(hr)) return Failed("Prime shared render buffer", hr);
  std::memcpy(samples, wav.data.data(), first * wav.bytesPerFrame());
  hr = render->ReleaseBuffer(first, 0);
  if (FAILED(hr)) return Failed("Release primed buffer", hr);
  hr = client->Start();
  if (FAILED(hr)) return Failed("Start shared playback", hr);
  struct StopOnExit { IAudioClient* client; ~StopOnExit() { client->Stop(); } } stop{client.Get()};
  size_t offset = first;
  const ULONGLONG deadline = GetTickCount64() + 5000 + wav.numFrames() * 1000 / wav.sampleRate;
  while (GetTickCount64() < deadline) {
    UINT32 padding = 0;
    hr = client->GetCurrentPadding(&padding);
    if (FAILED(hr)) return Failed("GetCurrentPadding", hr);
    if (offset == wav.numFrames() && padding == 0) {
      std::printf("Played %zu frames through explicit 6-channel shared endpoint.\n", offset); return 0;
    }
    const UINT32 count = static_cast<UINT32>(std::min<size_t>(capacity - padding, wav.numFrames() - offset));
    if (count) {
      hr = render->GetBuffer(count, &samples);
      if (FAILED(hr)) return Failed("Get shared render buffer", hr);
      std::memcpy(samples, wav.data.data() + offset * wav.bytesPerFrame(), count * wav.bytesPerFrame());
      hr = render->ReleaseBuffer(count, 0);
      if (FAILED(hr)) return Failed("Release shared render buffer", hr);
      offset += count;
    }
    Sleep(5);
  }
  return Failed("Shared playback timeout", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
}

static int PlaySpeakerTone(IMMDevice* dev, const std::wstring& speakerIn, const std::wstring& layoutIn)
{
  std::wstring spk = speakerIn, lay = layoutIn;
  std::transform(spk.begin(), spk.end(), spk.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towupper(c)); });
  std::transform(lay.begin(), lay.end(), lay.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  if (lay != L"stereo" && lay != L"2.0" && lay != L"5.1" && lay != L"7.1") return 2;

  double freq = 0.0, modHz = 0.0;
  float gains[6] = {0, 0, 0, 0, 0, 0};
  const bool isStereo = (lay == L"stereo" || lay == L"2.0");
  const bool is71 = (lay == L"7.1");

  // Harmonic series rooted at G3 = 196.00 Hz
  if (spk == L"FL") {
    freq = 196.00; gains[0] = 1.0f;
  } else if (spk == L"FC") {
    freq = 246.94;
    if (isStereo) { gains[0] = 0.707f; gains[1] = 0.707f; } else { gains[2] = 1.0f; }
  } else if (spk == L"FR") {
    freq = 293.66; gains[1] = 1.0f;
  } else if (spk == L"LFE") {
    freq = 55.00; modHz = 3.5;
    if (isStereo) { gains[0] = 0.707f; gains[1] = 0.707f; } else { gains[3] = 1.0f; }
  } else if (spk == L"BL") {
    freq = 329.63; modHz = 5.5;
    if (isStereo) { gains[0] = 0.85f; } else { gains[4] = 1.0f; }
  } else if (spk == L"BR") {
    freq = 369.99; modHz = 5.5;
    if (isStereo) { gains[1] = 0.85f; } else { gains[5] = 1.0f; }
  } else if (spk == L"SL") {
    freq = 392.00; modHz = 8.5;
    if (isStereo) { gains[0] = 0.9f; }
    else if (is71) { gains[4] = 0.85f; gains[0] = 0.42f; }
    else { gains[4] = 1.0f; }
  } else if (spk == L"SR") {
    freq = 440.00; modHz = 8.5;
    if (isStereo) { gains[1] = 0.9f; }
    else if (is71) { gains[5] = 0.85f; gains[1] = 0.42f; }
    else { gains[5] = 1.0f; }
  } else {
    return 2;
  }

  constexpr size_t kRate = 48000;
  constexpr size_t kFrames = 40800; // 0.85s
  std::vector<int16_t> pcm(kFrames * 6, 0);
  const double twoPi = 6.283185307179586;
  for (size_t i = 0; i < kFrames; ++i) {
    const double t = static_cast<double>(i) / static_cast<double>(kRate);
    const double dur = static_cast<double>(kFrames) / static_cast<double>(kRate);
    double env = 1.0;
    if (t < 0.025) env = 0.5 * (1.0 - std::cos(3.141592653589793 * (t / 0.025)));
    else if (t > dur - 0.12) env = 0.5 * (1.0 + std::cos(3.141592653589793 * ((t - (dur - 0.12)) / 0.12)));
    env *= std::exp(-1.4 * t);

    double mod = modHz > 0.0 ? (0.72 + 0.28 * std::sin(twoPi * modHz * t)) : 1.0;
    double wave = 0.0;
    if (spk == L"LFE") {
      wave = 0.75 * std::sin(twoPi * 55.0 * t) + 0.25 * std::sin(twoPi * 98.0 * t);
    } else {
      wave = 0.68 * std::sin(twoPi * freq * t)
           + 0.22 * std::sin(twoPi * (freq * 2.0) * t) * std::exp(-2.2 * t)
           + 0.10 * std::sin(twoPi * (freq * 3.0) * t) * std::exp(-3.5 * t);
    }
    const double sampleVal = 14000.0 * env * mod * wave;
    for (int ch = 0; ch < 6; ++ch) {
      if (gains[ch] > 0.0f) {
        double v = sampleVal * gains[ch];
        if (v > 32760.0) v = 32760.0;
        if (v < -32760.0) v = -32760.0;
        pcm[i * 6 + ch] = static_cast<int16_t>(v);
      }
    }
  }

  ComPtr<IAudioClient> client;
  HRESULT hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
  if (FAILED(hr)) return Failed("Activate shared speaker test", hr);
  auto format = Pcm51();
  hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_NOPERSIST | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
                          1000000, 0, &format.Format, nullptr);
  if (FAILED(hr)) return Failed("Initialize shared speaker test", hr);
  UINT32 capacity = 0;
  hr = client->GetBufferSize(&capacity);
  if (FAILED(hr) || !capacity) return Failed("GetBufferSize", FAILED(hr) ? hr : E_UNEXPECTED);
  ComPtr<IAudioRenderClient> render;
  hr = client->GetService(__uuidof(IAudioRenderClient), &render);
  if (FAILED(hr)) return Failed("Get shared render service", hr);
  const UINT32 first = static_cast<UINT32>(std::min<size_t>(capacity, kFrames));
  BYTE* samples = nullptr;
  hr = render->GetBuffer(first, &samples);
  if (FAILED(hr)) return Failed("Prime speaker buffer", hr);
  std::memcpy(samples, pcm.data(), first * 6 * sizeof(int16_t));
  hr = render->ReleaseBuffer(first, 0);
  if (FAILED(hr)) return Failed("Release primed speaker buffer", hr);
  hr = client->Start();
  if (FAILED(hr)) return Failed("Start shared speaker test", hr);
  struct StopOnExit { IAudioClient* client; ~StopOnExit() { client->Stop(); } } stop{client.Get()};
  size_t offset = first;
  const ULONGLONG deadline = GetTickCount64() + 4000;
  while (GetTickCount64() < deadline) {
    UINT32 padding = 0;
    hr = client->GetCurrentPadding(&padding);
    if (FAILED(hr)) return Failed("GetCurrentPadding", hr);
    if (offset == kFrames && padding == 0) {
      std::printf("speaker_tone=%s\nlayout=%s\nfreq=%.2f\n", Narrow(spk.c_str()).c_str(), Narrow(lay.c_str()).c_str(), freq);
      return 0;
    }
    const UINT32 count = static_cast<UINT32>(std::min<size_t>(capacity - padding, kFrames - offset));
    if (count) {
      hr = render->GetBuffer(count, &samples);
      if (FAILED(hr)) return Failed("Get shared speaker buffer", hr);
      std::memcpy(samples, pcm.data() + offset * 6, count * 6 * sizeof(int16_t));
      hr = render->ReleaseBuffer(count, 0);
      if (FAILED(hr)) return Failed("Release shared speaker buffer", hr);
      offset += count;
    }
    Sleep(5);
  }
  return Failed("Speaker tone timeout", HRESULT_FROM_WIN32(ERROR_TIMEOUT));
}

#ifndef BRIDGE_SPEAKER_LAYOUT_TEST
int wmain(int argc, wchar_t** argv)
{
  const std::wstring command = argc > 1 ? argv[1] : L"--help";
  if (command == L"--help") {
    std::puts("bridge_control --devices-json | --devices-json-all | --defaults | --init-optical [RATE] | --format ID | --speaker-info ID | --sessions ID | --default ID ROLE(0/1/2) | --visibility ID 0/1 | --set-51 ID | --set-mix-51 ID | --play-wav ID PATH | --tone-speaker ID SPEAKER LAYOUT | --volume ID | --set-volume ID SCALAR MUTE(0/1) | --measure-loopback ID SECONDS(1..10)");
    return 0;
  }
  ComApartment apartment;
  if (!apartment.ok()) return Failed("COM initialization", apartment.hr);
  if ((command == L"--devices-json" || command == L"--devices-json-all") && argc == 2) {
    std::putchar('['); bool first = true;
    const DWORD mask = command == L"--devices-json-all" ? DEVICE_STATE_ACTIVE | DEVICE_STATE_DISABLED : DEVICE_STATE_ACTIVE;
    for (const auto& endpoint : DeviceEnum::List(eRender, mask)) {
      ComPtr<IMMDevice> dev;
      DWORD state = 0;
      if (!DeviceEnum::GetById(endpoint.id, dev) || FAILED(dev->GetState(&state))) continue;
      std::printf("%s{\"id\":%s,\"name\":%s,\"isSpdif\":%s,\"active\":%s}", first ? "" : ",",
                  JsonString(endpoint.id).c_str(), JsonString(endpoint.name).c_str(), endpoint.isSpdif ? "true" : "false",
                  state == DEVICE_STATE_ACTIVE ? "true" : "false");
      first = false;
    }
    std::puts("]"); return 0;
  }
  if (command == L"--defaults" && argc == 2) {
    for (int role = 0; role < 3; ++role) {
      ComPtr<IMMDevice> dev;
      EndpointInfo info;
      if (!DeviceEnum::GetDefault(eRender, static_cast<ERole>(role), dev, info)) {
        std::fprintf(stderr, "No default render endpoint for role %d\n", role);
        return 1;
      }
      std::printf("%d=%s\n", role, Narrow(info.id.c_str()).c_str());
    }
    return 0;
  }
  if (command == L"--init-optical") {
    int rate = 48000;
    if (argc >= 3) {
      rate = std::wcstol(argv[2], nullptr, 10);
      if (rate <= 0) rate = 48000;
    }
    if (CmediaOpticalControl::EnableSpdifOutput(rate)) {
      std::printf("cmedia_spdif=initialized\nsample_rate=%d\n", rate);
      return 0;
    }
    std::fputs("No C-Media optical device found or failed to write S/PDIF register.\n", stderr);
    return 1;
  }
  if (command == L"--visibility") {
    if (argc != 4 || (std::wstring(argv[3]) != L"0" && std::wstring(argv[3]) != L"1")) {
      std::fputs("Invalid command or arguments. Run --help.\n", stderr);
      return 2;
    }
    return SetVirtualVisibility(argv[2], argv[3][0] == L'1');
  }
  if ((command != L"--format" && command != L"--speaker-info" && command != L"--sessions" && command != L"--set-51" && command != L"--set-mix-51" && command != L"--default" && command != L"--play-wav" && command != L"--tone-speaker" && command != L"--volume" && command != L"--set-volume" && command != L"--measure-loopback") ||
      argc != (command == L"--set-volume" || command == L"--tone-speaker" ? 5 : command == L"--default" || command == L"--play-wav" || command == L"--measure-loopback" ? 4 : 3)) {
    std::fputs("Invalid command or arguments. Run --help.\n", stderr);
    return 2;
  }
  const std::wstring id = argv[2];
  EndpointInfo selected;
  bool found = false;
  for (const auto& endpoint : DeviceEnum::List(eRender)) {
    if (endpoint.id == id) { selected = endpoint; found = true; break; }
  }
  if (!found) { std::fputs("ID must exactly match an active render endpoint.\n", stderr); return 2; }
  ComPtr<IMMDevice> dev;
  if (!DeviceEnum::GetById(id, dev)) return Failed("GetById", E_FAIL);
  if (command == L"--format") return ShowFormat(dev.Get(), id);
  if (command == L"--speaker-info") return SpeakerInfo(dev.Get(), id);
  if (command == L"--sessions") return Sessions(dev.Get());
  if (command == L"--volume") return Volume(dev.Get());
  if (command == L"--set-volume" && !IsCableInput(selected.name)) return 2;
  if (command == L"--set-volume") return Volume(dev.Get(), argv[3], argv[4]);
  if (command == L"--measure-loopback") return Measure(dev.Get(), argv[3]);
  if ((command == L"--set-51" || command == L"--set-mix-51" || command == L"--play-wav" || command == L"--tone-speaker") && !IsCableInput(selected.name)) {
    std::fputs("Format setting and WAV playback are restricted to CABLE Input or CABLE In 16ch (VB-Audio Virtual Cable).\n", stderr);
    return 2;
  }
  if (command == L"--play-wav") return PlayWav(dev.Get(), argv[3]);
  if (command == L"--tone-speaker") return PlaySpeakerTone(dev.Get(), argv[3], argv[4]);
  if (command == L"--default" && std::wstring(argv[3]) != L"0" &&
      std::wstring(argv[3]) != L"1" && std::wstring(argv[3]) != L"2") {
    std::fputs("ROLE must be exactly 0, 1, or 2.\n", stderr);
    return 2;
  }
  ComPtr<IPolicyConfig> policy;
  HRESULT hr = CoCreateInstance(kPolicyClient, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&policy));
  if (FAILED(hr)) return Failed("PolicyConfig activation", hr);
  if (command == L"--default") {
    const ERole role = static_cast<ERole>(argv[3][0] - L'0');
    hr = policy->SetDefaultEndpoint(id.c_str(), role);
    if (FAILED(hr)) return Failed("SetDefaultEndpoint", hr);
    ComPtr<IMMDevice> actual;
    EndpointInfo info;
    if (!DeviceEnum::GetDefault(eRender, role, actual, info) || info.id != id)
      return Failed("Default endpoint verification", E_FAIL);
    std::printf("%d=%s\n", role, Narrow(id.c_str()).c_str());
    return 0;
  }
  auto format = Pcm51();
  ComPtr<IAudioClient> client;
  hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
  if (FAILED(hr)) return Failed("Activate IAudioClient", hr);
  WAVEFORMATEX* closest = nullptr;
  hr = client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &format.Format, &closest);
  if (closest) CoTaskMemFree(closest);
  // The current stereo shared mixer can return S_FALSE for a hardware-supported
  // six-channel format. Verify exclusive capability before changing that mixer.
  if (hr != S_OK) {
    hr = client->IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, &format.Format, nullptr);
    if (hr != S_OK) return Failed("Hardware 5.1 PCM format support", hr);
  }
  client.Reset();
  hr = policy->SetDeviceFormat(id.c_str(), &format.Format, &format.Format);
  if (FAILED(hr)) return Failed("SetDeviceFormat", hr);
  {
    PROPVARIANT desc{}, adapter{}, physMask{};
    desc.vt = VT_LPWSTR;
    desc.pwszVal = const_cast<LPWSTR>(L"SurroundForge 5.1");
    adapter.vt = VT_LPWSTR;
    adapter.pwszVal = const_cast<LPWSTR>(L"SurroundForge Audio");
    physMask.vt = VT_UI4;
    physMask.ulVal = 0x3f;
    policy->SetPropertyValue(id.c_str(), FALSE, PKEY_Device_DeviceDesc, &desc);
    policy->SetPropertyValue(id.c_str(), FALSE, PKEY_DeviceInterface_FriendlyName, &adapter);
    policy->SetPropertyValue(id.c_str(), FALSE, PKEY_AudioEndpoint_PhysicalSpeakers, &physMask);
    policy->SetPropertyValue(id.c_str(), TRUE, PKEY_AudioEndpoint_PhysicalSpeakers, &physMask);
    ComPtr<IPropertyStore> writable;
    if (SUCCEEDED(dev->OpenPropertyStore(STGM_READWRITE, &writable))) {
      writable->SetValue(PKEY_Device_DeviceDesc, desc);
      writable->SetValue(PKEY_DeviceInterface_FriendlyName, adapter);
      writable->SetValue(PKEY_AudioEndpoint_PhysicalSpeakers, physMask);
      writable->Commit();
    }
  }
  if (command == L"--set-51") {
    hr = EnsureSpeakerMask51(dev.Get());
    if (FAILED(hr)) {
      if (hr == E_ACCESSDENIED)
        std::fputs("Windows needs administrator permission once to save this VB-CABLE speaker layout. Run setup as administrator; no default endpoint was changed.\n", stderr);
      return Failed("Persist 5.1 speaker assignments", hr);
    }
  } else {
    EnsureSpeakerMask51(dev.Get());
  }
  WAVEFORMATEX* actual = nullptr;
  hr = Mix(dev.Get(), &actual);
  if (FAILED(hr)) return Failed("Verify mix format", hr);
  const bool correct = IsMix51(actual);
  CoTaskMemFree(actual);
  if (!correct) return Failed("5.1 mix format verification", E_FAIL);
  hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, &client);
  if (FAILED(hr)) return Failed("Activate verification client", hr);
  closest = nullptr;
  hr = client->IsFormatSupported(AUDCLNT_SHAREMODE_SHARED, &format.Format, &closest);
  if (closest) CoTaskMemFree(closest);
  if (hr != S_OK) return Failed("Configured shared 5.1 PCM support", hr);
  return command == L"--set-51" ? SpeakerInfo(dev.Get(), id) : ShowFormat(dev.Get(), id);
}
#endif
