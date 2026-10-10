#include "doctest.h"
#include "WasapiPassthrough.h"

TEST_CASE("transient diagnostic publication never kills healthy audio but persistent failure is bounded") {
  HealthPublicationGuard publication;
  CHECK(publication.Observe(false,0));CHECK(publication.Pending());
  CHECK(publication.Observe(false,2800));
  CHECK(publication.Observe(true,3000));CHECK_FALSE(publication.Pending());
  CHECK(publication.Observe(false,4000));
  CHECK(publication.Observe(false,13999));
  CHECK_FALSE(publication.Observe(false,14000));
  CHECK(publication.Observe(true,14001));CHECK_FALSE(publication.Pending());
}

// Exercise the production Start/Stop paths without touching any audio hardware.
struct FakeClient : IAudioClient {
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE Initialize(AUDCLNT_SHAREMODE,DWORD flags,REFERENCE_TIME duration,REFERENCE_TIME,const WAVEFORMATEX*,LPCGUID) override { streamFlags=flags;requestedDuration=duration;return S_OK; }
  HRESULT STDMETHODCALLTYPE GetBufferSize(UINT32* value) override { *value=bufferFrames;return S_OK; }
  HRESULT STDMETHODCALLTYPE GetStreamLatency(REFERENCE_TIME*) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetCurrentPadding(UINT32* value) override { *value=padding;return paddingResult; }
  HRESULT STDMETHODCALLTYPE IsFormatSupported(AUDCLNT_SHAREMODE,const WAVEFORMATEX*,WAVEFORMATEX**) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE GetMixFormat(WAVEFORMATEX**) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetDevicePeriod(REFERENCE_TIME* value,REFERENCE_TIME*) override { *value=10000;return S_OK; }
  HRESULT STDMETHODCALLTYPE Start() override { ++starts; return startResult; }
  HRESULT STDMETHODCALLTYPE Stop() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE Reset() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE SetEventHandle(HANDLE) override { ++eventRegistrations;return S_OK; }
  HRESULT STDMETHODCALLTYPE GetService(REFIID,void** value) override { *value=service;return service?S_OK:E_NOTIMPL; }
  HRESULT startResult=S_OK;
  HRESULT paddingResult=S_OK;
  UINT32 padding=0;
  DWORD streamFlags=0;
  REFERENCE_TIME requestedDuration=0;
  unsigned eventRegistrations=0;
  unsigned starts=0;
  UINT32 bufferFrames=1536;
  void* service=nullptr;
};
struct FakeDevice : IMMDevice {
  explicit FakeDevice(FakeClient& value):client(value){}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void**) override {return E_NOINTERFACE;}
  ULONG STDMETHODCALLTYPE AddRef() override {return 1;}
  ULONG STDMETHODCALLTYPE Release() override {return 1;}
  HRESULT STDMETHODCALLTYPE Activate(REFIID,DWORD,PROPVARIANT*,void** value) override {*value=&client;return S_OK;}
  HRESULT STDMETHODCALLTYPE OpenPropertyStore(DWORD,IPropertyStore**) override {return E_NOTIMPL;}
  HRESULT STDMETHODCALLTYPE GetId(LPWSTR*) override {return E_NOTIMPL;}
  HRESULT STDMETHODCALLTYPE GetState(DWORD* state) override {*state=DEVICE_STATE_ACTIVE;return S_OK;}
  FakeClient& client;
};
struct FakeRender : IAudioRenderClient {
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE GetBuffer(UINT32 frames,BYTE** p) override { requestedFrames=frames;++gets;*p=buffer;return getResult; }
  HRESULT STDMETHODCALLTYPE ReleaseBuffer(UINT32 frames,DWORD flags) override { releasedFrames=frames;++releases;releasedFlags=flags;return releaseResult; }
  HRESULT getResult=S_OK,releaseResult=S_OK;
  DWORD releasedFlags=0;
  UINT32 requestedFrames=0,releasedFrames=0;
  unsigned gets=0,releases=0;
  BYTE buffer[4*6144]{};
};
struct FakeCapture : IAudioCaptureClient {
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void**) override { return E_NOINTERFACE; }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE GetBuffer(BYTE** p,UINT32* frames,DWORD* flags,UINT64*,UINT64*) override {
    *p=nullptr;*frames=1;*flags=AUDCLNT_BUFFERFLAGS_SILENT;return getResult;
  }
  HRESULT STDMETHODCALLTYPE ReleaseBuffer(UINT32) override { return releaseResult; }
  HRESULT STDMETHODCALLTYPE GetNextPacketSize(UINT32* frames) override { *frames=packet;return nextResult; }
  HRESULT nextResult=S_OK,getResult=S_OK,releaseResult=S_OK;
  UINT32 packet=0;
};
struct AudioWorkerTest {
  static bool Render(WasapiPassthrough& out) { return out.RenderOnce(); }
  static bool OpenExclusive(WasapiPassthrough& out,FakeDevice& device) {
    out.dev_=&device;return out.InitExclusive(48000);
  }
  static void Prepare(WasapiPassthrough& out,FakeClient& client,FakeRender& render) {
    out.client_=&client;out.render_=&render;out.bufferFrames_=1536;
    static RingBuffer empty(65536);
    out.ring_=&empty;out.capBytesPerFrame_=24;
    out.staging_.resize(1536*24);out.silence_.resize(1536*24);out.burst_.resize(6144);
    SpdifEncoder::Params params;params.inSampleFmt=AV_SAMPLE_FMT_FLT;
    av_channel_layout_default(&params.inLayout,6);
    REQUIRE(out.enc_.Init(params));av_channel_layout_uninit(&params.inLayout);
    out.dataEvent_=CreateWaitableTimerExW(nullptr,nullptr,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,TIMER_ALL_ACCESS);
    out.stopEvent_=CreateEventW(nullptr,TRUE,FALSE,nullptr);
  }
  static bool Running(WasapiPassthrough& out) { return out.running_.load(); }
  static bool UninitializedEncoderFails(WasapiPassthrough& out,RingBuffer& ring) {
    out.enc_.Close();
    out.ring_=&ring;out.burstsPerCycle_=1;out.staging_.resize(6144);
    out.silence_.resize(6144);out.burst_.resize(6144);
    return !out.RenderOnce() && out.Health().Failed();
  }
  static void Prepare(WasapiCapture& cap,FakeClient& client,FakeCapture& capture,RingBuffer& ring) {
    cap.client_=&client;cap.capture_=&capture;cap.ring_=&ring;
    cap.loopback_=true;cap.fmt_.channels=6;cap.fmt_.bits=32;cap.fmt_.isFloat=true;
    cap.stopEvent_=CreateEventW(nullptr,TRUE,FALSE,nullptr);
  }
  static bool StopJoinsCompletedWorker(WasapiPassthrough& out) {
    out.thread_=std::thread([]{});out.running_=false;out.Stop();
    bool joined=!out.thread_.joinable();
    if(out.thread_.joinable()) out.thread_.join(); // old code cleanup avoids terminate
    return joined;
  }
};
TEST_CASE("optical refill follows device space without relying on USB callback timing") {
  FakeClient client;FakeRender render;FakeDevice device(client);WasapiPassthrough out;
  client.bufferFrames=4608;client.service=&render;
  SUBCASE("whole-burst capacity") {}
  SUBCASE("fractional capacity") {client.bufferFrames=5000;}
  RingBuffer ring(524288);
  CaptureFormat format;format.channels=6;format.bits=32;format.isFloat=true;
  format.sampleRate=48000;format.channelMask=0x3f;
  REQUIRE(out.Init(&device,&ring,format,{}));
  CHECK((client.streamFlags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK)==0);
  CHECK(client.eventRegistrations==0);
  CHECK(client.requestedDuration>=960000);
  // Missed/delayed wakes can leave several bursts free; fractional capacity is
  // never filled with carrier zeros, which would stretch the audio timeline.
  for(UINT32 free:{0u,1535u,1536u,3071u,3072u,4607u,client.bufferFrames}) {
    std::vector<float> pcm(6*6144,0.1f);ring.Clear();
    REQUIRE(ring.Write(pcm.data(),pcm.size()*sizeof(float))==pcm.size()*sizeof(float));
    client.padding=client.bufferFrames-free;
    const auto beforeBytes=ring.BytesAvailable();const auto beforeGets=render.gets;
    const UINT32 expected=free/1536*1536;
    REQUIRE(AudioWorkerTest::Render(out));
    CHECK(render.gets==beforeGets+(expected?1:0));
    CHECK(ring.BytesAvailable()==beforeBytes-expected*24);
    if(expected) {
      CHECK(render.requestedFrames==expected);CHECK(render.releasedFrames==expected);
      CHECK(render.releasedFlags==0);
      for(UINT32 offset=0;offset<expected*4;offset+=6144) {
        CHECK(render.buffer[offset]==0x72);CHECK(render.buffer[offset+1]==0xf8);
        CHECK(render.buffer[offset+2]==0x1f);CHECK(render.buffer[offset+3]==0x4e);
      }
    }
  }
}
TEST_CASE("invalid padding never acquires a buffer or consumes queued audio") {
  for(bool apiFailure:{false,true}) {
    FakeClient client;FakeRender render;WasapiPassthrough out;
    AudioWorkerTest::Prepare(out,client,render);
    client.padding=1537;if(apiFailure)client.paddingResult=AUDCLNT_E_DEVICE_INVALIDATED;
    CHECK_FALSE(AudioWorkerTest::Render(out));
    CHECK(out.Health().Failed());CHECK(render.gets==0);CHECK(render.releases==0);
  }
}
TEST_CASE("temporarily unavailable optical buffer retries without consuming PCM or releasing unowned memory") {
  FakeClient client;FakeRender render;WasapiPassthrough out;
  AudioWorkerTest::Prepare(out,client,render);
  render.getResult=AUDCLNT_E_BUFFER_ERROR;
  CHECK(AudioWorkerTest::Render(out));CHECK_FALSE(out.Health().Failed());
  CHECK(render.releases==0);CHECK(out.Health().progress.load()==0);
  render.getResult=S_OK;
  CHECK(AudioWorkerTest::Render(out));CHECK(render.releases==1);
  CHECK(out.Health().frames.load()==1536);
}
TEST_CASE("idle timer wakes do not certify audio progress and Stop joins the worker") {
  FakeClient client;FakeRender render;WasapiPassthrough out;
  AudioWorkerTest::Prepare(out,client,render);client.padding=1536;
  REQUIRE(out.Start());std::this_thread::sleep_for(std::chrono::milliseconds(20));out.Stop();
  CHECK(out.Health().progress.load()==0);CHECK(render.gets==0);
  CHECK_FALSE(AudioWorkerTest::Running(out));
}
TEST_CASE("optical buffers retain two whole bursts and allow unused fractional capacity") {
  for(UINT32 frames:{0u,512u,1536u,2048u,3072u,4096u,4608u}) {
    FakeClient client;FakeRender render;FakeDevice device(client);WasapiPassthrough out;
    client.bufferFrames=frames;client.service=&render;
    CHECK(AudioWorkerTest::OpenExclusive(out,device)==(frames>=3072));
  }
}
TEST_CASE("render startup rejects failed prefill and never starts the audio client") {
  for(bool getFailure:{true,false}) {
    FakeClient client;FakeRender render;WasapiPassthrough out;
    AudioWorkerTest::Prepare(out,client,render);
    if(getFailure)render.getResult=AUDCLNT_E_DEVICE_INVALIDATED;
    else render.releaseResult=AUDCLNT_E_DEVICE_INVALIDATED;
    bool started=out.Start();out.Stop();
    CHECK_FALSE(started);CHECK(client.starts==0);
  }
}
TEST_CASE("failed audio client start clears running state") {
  FakeClient client;FakeRender render;WasapiPassthrough out;
  AudioWorkerTest::Prepare(out,client,render);client.startResult=E_FAIL;
  CHECK_FALSE(out.Start());CHECK_FALSE(AudioWorkerTest::Running(out));
}
TEST_CASE("stop joins a worker that already returned") {
  WasapiPassthrough out;CHECK(AudioWorkerTest::StopJoinsCompletedWorker(out));
}
TEST_CASE("capture packet API failures reach supervisor while silence remains healthy") {
  for(int failure=0;failure<5;++failure) {
    FakeClient client;FakeCapture capture;RingBuffer ring(6144);WasapiCapture cap;
    AudioWorkerTest::Prepare(cap,client,capture,ring);
    if(failure==1)capture.nextResult=AUDCLNT_E_DEVICE_INVALIDATED;
    if(failure>=2)capture.packet=1;
    if(failure==2)capture.getResult=AUDCLNT_E_DEVICE_INVALIDATED;
    if(failure==3)capture.releaseResult=AUDCLNT_E_DEVICE_INVALIDATED;
    if(failure==4)capture.getResult=AUDCLNT_S_BUFFER_EMPTY;
    REQUIRE(cap.Start());
    for(int i=0;i<100 && !cap.Health().Failed();++i) {
      if((failure==0 || failure==4) && cap.Health().progress.load()>=3)break;
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    cap.Stop();CHECK(cap.Health().Failed()==(failure>0 && failure<4));CHECK(cap.Health().progress.load()>0);
  }
}
TEST_CASE("encoder failure releases acquired output buffer as silence and reaches supervisor") {
  FakeClient client;FakeRender render;WasapiPassthrough out;RingBuffer ring(6144);
  AudioWorkerTest::Prepare(out,client,render);
  CHECK(AudioWorkerTest::UninitializedEncoderFails(out,ring));
  CHECK(render.releasedFlags==AUDCLNT_BUFFERFLAGS_SILENT);
}
TEST_CASE("render timeout and wait failure are bounded and recover a transient timeout") {
  AudioWorkerHealth health;
  CHECK_FALSE(health.RenderWait(WAIT_TIMEOUT));CHECK_FALSE(health.Failed());
  CHECK(health.RenderWait(WAIT_OBJECT_0));
  CHECK_FALSE(health.RenderWait(WAIT_TIMEOUT));CHECK_FALSE(health.RenderWait(WAIT_TIMEOUT));
  CHECK_FALSE(health.Failed());CHECK_FALSE(health.RenderWait(WAIT_TIMEOUT));CHECK(health.Failed());
  AudioWorkerHealth invalid;CHECK_FALSE(invalid.RenderWait(WAIT_FAILED));CHECK(invalid.Failed());
}
TEST_CASE("volume failure fails closed then escalates after six seconds but valid mute is healthy") {
  AudioWorkerHealth health;
  CHECK_FALSE(health.VolumeRead(false,100));CHECK_FALSE(health.VolumeRead(false,6099));CHECK_FALSE(health.Failed());
  CHECK(health.VolumeRead(true,6100));CHECK_FALSE(health.Failed()); // readable mute/zero gain are normal
  CHECK_FALSE(health.VolumeRead(false,7000));CHECK_FALSE(health.VolumeRead(false,13000));CHECK(health.Failed());
}
TEST_CASE("encoder priming is bounded and malformed bursts fail") {
  for(int size:{-1,1,6143,6145}) { AudioWorkerHealth health;CHECK_FALSE(health.BurstSize(size,6144)); }
  AudioWorkerHealth health;
  for(int i=0;i<64;++i)CHECK(health.BurstSize(0,6144));
  CHECK(health.BurstSize(6144,6144)); // valid output resets priming allowance
  for(int i=0;i<64;++i)CHECK(health.BurstSize(0,6144));
  CHECK_FALSE(health.BurstSize(0,6144));
}
