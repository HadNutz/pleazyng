// Media Foundation audio streams and in-band timed text for Pleazyng.
#pragma once
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <wrl/client.h>
#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <vector>

struct MediaTrack {
    DWORD id;
    bool audio, selected;
    std::string language, title;
};

class TrackNotifications final : public IMFTimedTextNotify {
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override;
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override;
    void STDMETHODCALLTYPE TrackAdded(DWORD) override { ++revision; }
    void STDMETHODCALLTYPE TrackRemoved(DWORD id) override { TrackSelected(id, FALSE); ++revision; }
    void STDMETHODCALLTYPE TrackSelected(DWORD id, BOOL selected) override;
    void STDMETHODCALLTYPE TrackReadyStateChanged(DWORD) override { ++revision; }
    void STDMETHODCALLTYPE Error(MF_TIMED_TEXT_ERROR_CODE, HRESULT, DWORD) override {}
    void STDMETHODCALLTYPE Cue(MF_TIMED_TEXT_CUE_EVENT event, double, IMFTimedTextCue* cue) override;
    void STDMETHODCALLTYPE Reset() override;
    std::string caption();
    std::atomic<int> revision{0};
private:
    std::atomic<ULONG> references_{1};
    std::mutex mutex_;
    std::map<std::pair<DWORD,DWORD>, std::string> captions_;
};

class MediaTracks {
public:
    void attach(IMFMediaEngineEx* engine);
    void close();
    std::vector<MediaTrack> list() const;
    HRESULT select(bool audio, int64_t id);
    std::string caption() const { return notify_ ? notify_->caption() : ""; }
    int revision() const { return notify_ ? notify_->revision.load() : 0; }
private:
    Microsoft::WRL::ComPtr<IMFMediaEngineEx> engine_;
    Microsoft::WRL::ComPtr<IMFTimedText> text_;
    Microsoft::WRL::ComPtr<TrackNotifications> notify_;
};
