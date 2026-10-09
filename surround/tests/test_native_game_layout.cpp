// Gaming API probe. Default mode is read-only. The explicit test-only reproduction
// changes ONLY an exactly named VB render input, and restores the assigned 5.1 mix.
// No source voices, audio buffers, defaults/volume or cooperative-level changes.
// API contracts: learn.microsoft.com/windows/win32/api/xaudio2/nf-xaudio2-ixaudio2-createmasteringvoice
// DirectSound identity: learn.microsoft.com/windows/win32/coreaudio/pkey-audioendpoint-guid
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define DIRECTSOUND_VERSION 0x1000
#include <windows.h>
#include <mmdeviceapi.h>
#include <propsys.h>
#include <xaudio2.h>
#include <dsound.h>
#include <wrl/client.h>
#include <cstdio>
#include <string>

#define BRIDGE_SPEAKER_LAYOUT_TEST
#include "../source/engine/src/BridgeControl.cpp" // Reuse verified policy format ABI and VB guard.

// Microsoft documents side/back 5.1 as equivalent, and the mastering voice's
// implicit six-channel assignment uses sides. Requiring only 0x3f is a false fail.
// learn.microsoft.com/windows/win32/xaudio2/xaudio2-default-channel-mapping
constexpr bool IsGame51(UINT32 channels, DWORD mask)
{
  return channels == 6 && (mask == 0x3f || mask == 0x60f);
}
static_assert(IsGame51(6, 0x3f) && IsGame51(6, 0x60f), "Both standard 5.1 layouts accepted");
static_assert(!IsGame51(2, 3) && !IsGame51(6, 0) && !IsGame51(8, 0x63f), "Stereo, unassigned and 7.1 rejected");

static bool ReportFailure(HRESULT hr, const char* operation)
{
  if (SUCCEEDED(hr)) return false;
  std::fprintf(stderr, "%s_error=0x%08lx\n", operation, static_cast<unsigned long>(hr));
  return true;
}

static const char* SpeakerConfigName(DWORD config)
{
  switch (config) {
    case DSSPEAKER_DIRECTOUT: return "direct_out";
    case DSSPEAKER_HEADPHONE: return "headphones";
    case DSSPEAKER_MONO: return "mono";
    case DSSPEAKER_STEREO: return "stereo";
    case DSSPEAKER_QUAD: return "quad";
    case DSSPEAKER_SURROUND: return "surround";
    case DSSPEAKER_5POINT1_BACK: return "5.1_back";
    case DSSPEAKER_5POINT1_SURROUND: return "5.1_side";
    case DSSPEAKER_7POINT1_WIDE: return "7.1_wide";
    case DSSPEAKER_7POINT1_SURROUND: return "7.1_surround";
    default: return "unknown";
  }
}

static bool QueryDirectSound(IMMDevice* endpoint, DWORD* result)
{
  ComPtr<IPropertyStore> store;
  if (ReportFailure(endpoint->OpenPropertyStore(STGM_READ, &store), "ds_property_store")) return false;
  PROPVARIANT value{};
  HRESULT hr = store->GetValue(PKEY_AudioEndpoint_GUID, &value);
  GUID id{};
  if (SUCCEEDED(hr))
    hr = value.vt == VT_LPWSTR && value.pwszVal ? CLSIDFromString(value.pwszVal, &id) : E_INVALIDARG;
  PropVariantClear(&value);
  if (ReportFailure(hr, "ds_endpoint_guid")) return false;
  ComPtr<IDirectSound8> ds;
  if (ReportFailure(DirectSoundCreate8(&id, &ds, nullptr), "ds_create")) return false;
  DWORD packed = 0;
  if (ReportFailure(ds->GetSpeakerConfig(&packed), "ds_speaker_config")) return false;
  const DWORD config = DSSPEAKER_CONFIG(packed);
  if(result) *result=config;
  std::printf("directsound_packed=0x%08lx\ndirectsound_config=%lu\ndirectsound_name=%s\ndirectsound_geometry=%lu\ndirectsound_51=%d\n",
    packed, config, SpeakerConfigName(config), DSSPEAKER_GEOMETRY(packed),
    config == DSSPEAKER_5POINT1_BACK || config == DSSPEAKER_5POINT1_SURROUND);
  return true;
}

static int ProbeGameApis(IMMDevice* endpoint, LPCWSTR endpointId, bool requireDirectSound51=true, DWORD* result=nullptr)
{
  // DirectSound is reported independently: its legacy configuration is not assumed
  // equivalent to XAudio2 or to the modern shared mix channel count.
  DWORD dsConfig=0xffffffff;
  const bool dsQueried = QueryDirectSound(endpoint, &dsConfig);
  if(result) *result=dsConfig;
  ComPtr<IXAudio2> engine;
  if (ReportFailure(XAudio2Create(&engine, 0, XAUDIO2_DEFAULT_PROCESSOR), "xaudio2_create")) return 2;
  engine->StopEngine(); // No processing; no source voices or buffers are created.
  IXAudio2MasteringVoice* master = nullptr;
  // DEFAULT_CHANNELS is essential: requesting six would force the expected answer.
  HRESULT hr = engine->CreateMasteringVoice(&master, XAUDIO2_DEFAULT_CHANNELS,
    XAUDIO2_DEFAULT_SAMPLERATE, XAUDIO2_NO_VIRTUAL_AUDIO_CLIENT, endpointId, nullptr,
    AudioCategory_GameEffects);
  if (ReportFailure(hr, "xaudio2_mastering_voice")) return 2;
  XAUDIO2_VOICE_DETAILS details{};
  master->GetVoiceDetails(&details);
  DWORD mask = 0;
  hr = master->GetChannelMask(&mask);
  master->DestroyVoice();
  if (ReportFailure(hr, "xaudio2_channel_mask")) return 2;
  std::printf("xaudio2_channels=%u\nxaudio2_rate=%u\nxaudio2_mask=0x%lx\nxaudio2_rear_mask_match=%d\nxaudio2_51=%d\n",
    details.InputChannels, details.InputSampleRate, mask, mask == 0x3f, IsGame51(details.InputChannels, mask));
  if (!IsGame51(details.InputChannels, mask)) {
    std::fprintf(stderr, "FAIL: XAudio2 did not automatically detect six assigned 5.1 channels.\n");
    return 1;
  }
  std::puts("PASS: XAudio2 automatically detected six channels with a documented 5.1 speaker mask; no audio played.");
  if(!dsQueried) return 2;
  if(requireDirectSound51 && dsConfig!=DSSPEAKER_5POINT1_BACK && dsConfig!=DSSPEAKER_5POINT1_SURROUND) {
    std::fputs("FAIL: DirectSound did not automatically detect assigned 5.1 speakers.\n",stderr);
    return 1;
  }
  return 0;
}

int wmain(int argc, wchar_t** argv)
{
  const bool reproduce = argc == 3 && std::wstring(argv[2]) == L"--reproduce-reboot-loss";
  if ((argc != 2 && !reproduce) || !argv[1][0]) {
    std::fprintf(stderr, "Usage: native_game_layout_test.exe EXACT_RENDER_ENDPOINT_ID [--reproduce-reboot-loss]\nStop the bridge before the explicit reproduction mode.\n");
    return 2;
  }
  ComApartment apartment;
  if (ReportFailure(apartment.hr, "com_initialize")) return 2;
  ComPtr<IMMDevice> endpoint;
  if (!DeviceEnum::GetById(argv[1], endpoint)) return 2;
  ComPtr<IMMEndpoint> direction;
  EDataFlow flow = eAll;
  if (ReportFailure(endpoint.As(&direction), "endpoint_direction") ||
    ReportFailure(direction->GetDataFlow(&flow), "endpoint_flow") || flow != eRender) return 2;
  if (!reproduce) return ProbeGameApis(endpoint.Get(), argv[1]);

  bool exactCable = false;
  for (const auto& device : DeviceEnum::List(eRender))
    if (device.id == argv[1]) exactCable = IsCableInput(device.name);
  if (!exactCable) { std::fprintf(stderr, "Reproduction refused: exact endpoint must be a verified VB-Audio render input.\n"); return 2; }
  ComPtr<IPolicyConfig> policy;
  if (ReportFailure(CoCreateInstance(kPolicyClient, nullptr, CLSCTX_ALL,
    IID_PPV_ARGS(&policy)), "format_policy")) return 2;
  auto fixed = Pcm51();
  struct RestoreMix {
    IPolicyConfig* policy;
    LPCWSTR id;
    WAVEFORMATEXTENSIBLE* format;
    bool pending = true;
    ~RestoreMix() {
      if (pending) ReportFailure(policy->SetDeviceFormat(id, &format->Format, &format->Format), "finally_restore_mix");
    }
  } restore{policy.Get(), argv[1], &fixed};
  auto lost = fixed; lost.dwChannelMask = 0;
  if (ReportFailure(policy->SetDeviceFormat(argv[1], &lost.Format, &lost.Format), "reproduce_mask_zero")) return 2;
  std::puts("phase=mask_zero");
  ShowFormat(endpoint.Get(), argv[1]);
  DWORD beforeConfig=0xffffffff;
  const int before = ProbeGameApis(endpoint.Get(), argv[1], false, &beforeConfig);
  // Always restore, including when the old native probe fails or cannot initialize.
  if (ReportFailure(policy->SetDeviceFormat(argv[1], &fixed.Format, &fixed.Format), "restore_assigned_mix")) return 2;
  std::puts("phase=restored_mask_3f");
  if (ShowFormat(endpoint.Get(), argv[1]) != 0) return 2;
  ComPtr<IAudioClient> restoredClient;
  if (ReportFailure(endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
    &restoredClient), "verify_restored_client")) return 2;
  WAVEFORMATEX* restoredFormat = nullptr;
  if (ReportFailure(restoredClient->GetMixFormat(&restoredFormat), "verify_restored_format")) return 2;
  const bool restored51 = IsMix51(restoredFormat);
  CoTaskMemFree(restoredFormat);
  if (!restored51) { std::fprintf(stderr, "FAIL: restored mix is not assigned 5.1; finally will retry restoration.\n"); return 2; }
  restoredClient.Reset();
  restore.pending = false;
  const int after = ProbeGameApis(endpoint.Get(), argv[1]);
  std::printf("before_probe_status=%d\nafter_probe_status=%d\n", before, after);
  if(before!=0 || beforeConfig!=DSSPEAKER_DIRECTOUT || after!=0) {
    std::fputs("FAIL: did not reproduce DirectSound's unassigned-to-5.1 transition.\n",stderr);
    return 1;
  }
  std::puts("PASS: original mask-zero bug produced DirectSound DIRECTOUT; restoration fixed automatic 5.1 detection.");
  return 0;
}
