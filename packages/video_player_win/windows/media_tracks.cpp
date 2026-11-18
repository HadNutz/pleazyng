#include "media_tracks.h"
#include <propvarutil.h>
#include <algorithm>

using Microsoft::WRL::ComPtr;

namespace {
std::string utf8(const wchar_t* value) {
    if (!value) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string result(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, &result[0], size, nullptr, nullptr);
    result.pop_back();
    return result;
}

std::string attribute(IMFMediaEngineEx* engine, DWORD index, REFGUID key) {
    PROPVARIANT v{};
    engine->GetStreamAttribute(index, key, &v);
    const auto result = v.vt == VT_LPWSTR ? utf8(v.pwszVal) : v.vt == VT_BSTR ? utf8(v.bstrVal) : "";
    PropVariantClear(&v);
    return result;
}

bool audioStream(IMFMediaEngineEx* engine, DWORD index) {
    PROPVARIANT v{};
    const bool audio = SUCCEEDED(engine->GetStreamAttribute(index, MF_MT_MAJOR_TYPE, &v)) &&
                       v.vt == VT_CLSID && v.puuid && *v.puuid == MFMediaType_Audio;
    PropVariantClear(&v);
    return audio;
}
}

HRESULT TrackNotifications::QueryInterface(REFIID iid, void** result) {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (iid != IID_IUnknown && iid != __uuidof(IMFTimedTextNotify)) return E_NOINTERFACE;
    *result = static_cast<IMFTimedTextNotify*>(this);
    AddRef();
    return S_OK;
}
ULONG TrackNotifications::Release() {
    const auto count = --references_;
    if (!count) delete this;
    return count;
}
void TrackNotifications::TrackSelected(DWORD id, BOOL selected) {
    if (!selected) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = captions_.lower_bound({id,0});
        while (it != captions_.end() && it->first.first == id) it = captions_.erase(it);
    }
    ++revision;
}
void TrackNotifications::Reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    captions_.clear();
    ++revision;
}
void TrackNotifications::Cue(MF_TIMED_TEXT_CUE_EVENT event, double, IMFTimedTextCue* cue) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (event == MF_TIMED_TEXT_CUE_EVENT_CLEAR) { captions_.clear(); return; }
    if (!cue || cue->GetCueKind() == MF_TIMED_TEXT_TRACK_KIND_METADATA) return;
    const auto key = std::make_pair(cue->GetTrackId(), cue->GetId());
    if (event == MF_TIMED_TEXT_CUE_EVENT_INACTIVE) { captions_.erase(key); return; }
    std::string text;
    for (DWORD i = 0; i < cue->GetLineCount(); ++i) {
        ComPtr<IMFTimedTextFormattedText> line;
        LPWSTR raw = nullptr;
        if (SUCCEEDED(cue->GetLine(i, &line)) && SUCCEEDED(line->GetText(&raw))) {
            if (!text.empty()) text += '\n';
            text += utf8(raw);
        }
        CoTaskMemFree(raw);
    }
    captions_[key] = std::move(text);
}
std::string TrackNotifications::caption() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::string text;
    for (const auto& entry : captions_) {
        if (!text.empty()) text += '\n';
        text += entry.second;
    }
    return text;
}

void MediaTracks::attach(IMFMediaEngineEx* engine) {
    engine_ = engine;
    if (SUCCEEDED(MFGetService(engine, MF_MEDIA_ENGINE_TIMEDTEXT, IID_PPV_ARGS(&text_)))) {
        notify_.Attach(new TrackNotifications());
        if (SUCCEEDED(text_->RegisterNotifications(notify_.Get()))) text_->SetInBandEnabled(TRUE);
    }
}
void MediaTracks::close() {
    if (text_) text_->RegisterNotifications(nullptr);
    text_.Reset();
    notify_.Reset();
    engine_.Reset();
}
std::vector<MediaTrack> MediaTracks::list() const {
    std::vector<MediaTrack> result;
    DWORD count = 0;
    if (engine_) engine_->GetNumberOfStreams(&count);
    for (DWORD i = 0; i < count; ++i) {
        if (!audioStream(engine_.Get(), i)) continue;
        BOOL selected = FALSE;
        engine_->GetStreamSelection(i, &selected);
        result.push_back({i, true, selected != FALSE, attribute(engine_.Get(), i, MF_SD_LANGUAGE),
                          attribute(engine_.Get(), i, MF_SD_STREAM_NAME)});
    }
    ComPtr<IMFTimedTextTrackList> tracks;
    if (text_ && SUCCEEDED(text_->GetTextTracks(&tracks))) {
        for (DWORD i = 0; i < tracks->GetLength(); ++i) {
            ComPtr<IMFTimedTextTrack> track;
            if (FAILED(tracks->GetTrack(i, &track))) continue;
            LPWSTR title = nullptr, language = nullptr;
            track->GetLabel(&title);
            track->GetLanguage(&language);
            result.push_back({track->GetId(), false, track->IsActive() != FALSE, utf8(language), utf8(title)});
            CoTaskMemFree(title);
            CoTaskMemFree(language);
        }
    }
    return result;
}
HRESULT MediaTracks::select(bool audio, int64_t id) {
    if (!engine_ || (audio && id < 0)) return E_INVALIDARG;
    const auto rows = list();
    if (id >= 0 && std::none_of(rows.begin(), rows.end(), [=](const MediaTrack& row) {
        return row.audio == audio && row.id == id;
    })) return E_INVALIDARG;
    const auto set = [&](const MediaTrack& row, bool selected) {
        return audio ? engine_->SetStreamSelection(row.id, selected) : text_->SelectTrack(row.id, selected);
    };
    HRESULT status = S_OK;
    for (const auto& row : rows) {
        if (row.audio != audio || row.selected == (row.id == id)) continue;
        status = set(row, row.id == id);
        if (FAILED(status)) break;
    }
    if (audio && SUCCEEDED(status)) status = engine_->ApplyStreamSelections();
    if (FAILED(status)) {
        for (const auto& row : rows) if (row.audio == audio) set(row, row.selected);
        if (audio) engine_->ApplyStreamSelections();
    }
    return status;
}
