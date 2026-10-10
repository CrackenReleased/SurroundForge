#pragma once
#include "ComUtil.h"
#include <atomic>
#include <chrono>
#include <avrt.h>

// Fixed-size, lock-free status; main owns logging and recovery. Silence is not failure.
struct AudioWorkerHealth {
  std::atomic<const char*> error{nullptr};
  std::atomic<HRESULT> errorCode{S_OK};
  std::atomic<uint64_t> progress{0}, droppedPackets{0}, underruns{0}, timeouts{0};
  std::atomic<uint64_t> frames{0}, trimmedFrames{0}, discontinuities{0};
  void Fail(const char* reason,HRESULT hr=E_FAIL) {
    const char* expected=nullptr;
    if(error.compare_exchange_strong(expected,reason)) errorCode=hr;
  }
  bool Check(HRESULT hr,const char* reason) { if(FAILED(hr)) Fail(reason,hr);return SUCCEEDED(hr); }
  bool Failed() const { return error.load()!=nullptr; }
  bool RenderWait(DWORD result) {
    if(result==WAIT_OBJECT_0) { consecutiveTimeouts=0;return true; }
    if(result==WAIT_OBJECT_0+1)return false;
    if(result==WAIT_TIMEOUT) {
      ++timeouts;
      if(++consecutiveTimeouts>=3)Fail("render_timeout");
    } else Fail("render_wait_failed",HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }
  bool VolumeRead(bool ok,uint64_t nowMs) {
    if(ok) { volumeFailureStart=0;return true; }
    if(!volumeFailureStart)volumeFailureStart=nowMs+1;
    if(nowMs+1-volumeFailureStart>=6000)Fail("volume_read_failed");
    return false;
  }
  bool BurstSize(int bytes,int expected) {
    if(bytes<0 || (bytes!=0 && bytes!=expected))Fail("encoder_invalid_burst");
    else if(bytes==0 && ++primingPackets>64)Fail("encoder_stalled");
    else if(bytes==expected)primingPackets=0;
    return !Failed();
  }
private:
  unsigned consecutiveTimeouts=0,primingPackets=0;
  uint64_t volumeFailureStart=0;
};

struct AudioThreadPriority {
  HANDLE handle=nullptr;
  AudioThreadPriority() { DWORD index=0;handle=AvSetMmThreadCharacteristicsW(L"Pro Audio",&index); }
  ~AudioThreadPriority() { if(handle)AvRevertMmThreadCharacteristics(handle); }
};
inline uint64_t AudioNowMs() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Diagnostic publication is not an audio-worker failure. A transient sharing
// conflict must not cut a healthy stream; a sustained inability still fails
// before the supervisor's 15-second stale-heartbeat deadline.
struct HealthPublicationGuard {
  bool Observe(bool published,uint64_t nowMs) {
    if(published) { failureStart=0;return true; }
    if(!failureStart)failureStart=nowMs+1;
    return nowMs+1-failureStart<10000;
  }
  bool Pending() const { return failureStart!=0; }
private:
  uint64_t failureStart=0;
};
