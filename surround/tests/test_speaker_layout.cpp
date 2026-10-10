// Includes production helpers, but excludes its entry point. No real endpoint is opened.
#define BRIDGE_SPEAKER_LAYOUT_TEST
#include "../source/engine/src/BridgeControl.cpp"

class SpeakerStore final : public IPropertyStore {
public:
  bool present = false, loseOnCommit = false;
  DWORD mask = 0, pending = 0;
  HRESULT setResult = S_OK, commitResult = S_OK;
  int writes = 0, commits = 0;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE GetCount(DWORD* count) override { *count = 1; return S_OK; }
  HRESULT STDMETHODCALLTYPE GetAt(DWORD, PROPERTYKEY* key) override { *key = PKEY_AudioEndpoint_PhysicalSpeakers; return S_OK; }
  HRESULT STDMETHODCALLTYPE GetValue(REFPROPERTYKEY key, PROPVARIANT* value) override {
    if (key.pid != PKEY_AudioEndpoint_PhysicalSpeakers.pid || key.fmtid != PKEY_AudioEndpoint_PhysicalSpeakers.fmtid) return E_INVALIDARG;
    *value = PROPVARIANT{};
    if (present) { value->vt = VT_UI4; value->ulVal = mask; }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE SetValue(REFPROPERTYKEY key, REFPROPVARIANT value) override {
    ++writes;
    if (key.pid != PKEY_AudioEndpoint_PhysicalSpeakers.pid || key.fmtid != PKEY_AudioEndpoint_PhysicalSpeakers.fmtid || value.vt != VT_UI4) return E_INVALIDARG;
    pending = value.ulVal;
    return setResult;
  }
  HRESULT STDMETHODCALLTYPE Commit() override {
    ++commits;
    if (SUCCEEDED(commitResult)) { mask = pending; present = !loseOnCommit; }
    return commitResult;
  }
};

#define REQUIRE_LAYOUT(condition) do { if (!(condition)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); return 1; } } while(0)

int main()
{
  REQUIRE_LAYOUT(std::string(SessionStateName(AudioSessionStateActive)) == "active");
  REQUIRE_LAYOUT(std::string(SessionStateName(AudioSessionStateInactive)) == "inactive");
  REQUIRE_LAYOUT(std::string(SessionStateName(AudioSessionStateExpired)) == "expired");
  REQUIRE_LAYOUT(std::string(SessionStateName(static_cast<AudioSessionState>(99))) == "unknown");
  auto format = Pcm51();
  REQUIRE_LAYOUT(IsMix51(&format.Format));
  format.dwChannelMask = 0; // Actual reboot failure: six unassigned channels.
  REQUIRE_LAYOUT(format.Format.nChannels == 6);
  REQUIRE_LAYOUT(!IsMix51(&format.Format));
  format.dwChannelMask = 0x3f;
  PROPVARIANT missing{};
  REQUIRE_LAYOUT(!IsPhysical51(missing));
  PROPVARIANT assigned{}; assigned.vt = VT_UI4; assigned.ulVal = 0x3f;
  REQUIRE_LAYOUT(IsPhysical51(assigned));
  assigned.vt = VT_UI8;
  REQUIRE_LAYOUT(!IsPhysical51(assigned));

  SpeakerStore absent;
  REQUIRE_LAYOUT(PersistSpeakerMask51(&absent) == S_OK);
  REQUIRE_LAYOUT(absent.present && absent.mask == 0x3f && absent.writes == 1 && absent.commits == 1);
  REQUIRE_LAYOUT(PersistSpeakerMask51(&absent) == S_OK);
  REQUIRE_LAYOUT(absent.writes == 1 && absent.commits == 1); // Correct metadata is idempotent.

  SpeakerStore denied; denied.setResult = E_ACCESSDENIED;
  REQUIRE_LAYOUT(PersistSpeakerMask51(&denied) == E_ACCESSDENIED);
  REQUIRE_LAYOUT(denied.commits == 0 && !denied.present);
  SpeakerStore uncommitted; uncommitted.commitResult = E_FAIL;
  REQUIRE_LAYOUT(PersistSpeakerMask51(&uncommitted) == E_FAIL);
  REQUIRE_LAYOUT(!uncommitted.present);
  SpeakerStore dropped; dropped.loseOnCommit = true;
  REQUIRE_LAYOUT(PersistSpeakerMask51(&dropped) == E_FAIL); // Successful API return alone is insufficient.
  REQUIRE_LAYOUT(IsCableInput(L"CABLE In 16ch (VB-Audio Virtual Cable)"));
  REQUIRE_LAYOUT(IsCableInput(L"SurroundForge 5.1 (VB-Audio Virtual Cable)"));
  REQUIRE_LAYOUT(IsCableInput(L"SurroundForge 5.1 (SurroundForge Audio)"));
  REQUIRE_LAYOUT(IsCableInput(L"SurroundForge 5.1"));
  REQUIRE_LAYOUT(!IsCableInput(L"SPDIF Out (USB Sound Device)"));
  REQUIRE_LAYOUT(!IsCableInput(L"Speakers (Realtek(R) Audio)"));
  std::puts("PASS: unassigned six-channel mix rejected; missing physical speaker mask saved/committed/verified; idempotence, access/commit/readback failures and physical-adapter guard");
  return 0;
}
