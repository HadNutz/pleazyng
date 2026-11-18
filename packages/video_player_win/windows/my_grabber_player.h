#pragma once

#include "media_tracks.h"
#include <windows.h>
#include <mfapi.h>
#include <mfmediaengine.h>
#include <dxgi1_2.h>
#include <d3d11.h>
#include <dcomp.h>
#include <atomic>

#include <iostream>
#include <functional>
#include <mutex>

#include <wrl/client.h>

class MyPlayerCallback : public IUnknown
{
public:
	virtual void OnProcessFrame(ID3D11Texture2D* texture) = 0;
};

class MyPlayer : public IMFMediaEngineNotify
{
public:
	STDMETHODIMP QueryInterface(REFIID riid, void** ppv);
	inline STDMETHODIMP_(ULONG) AddRef() {
		return InterlockedIncrement(&m_cRef);
	}
	STDMETHODIMP_(ULONG) Release() {
		ULONG uCount = InterlockedDecrement(&m_cRef);
		if (uCount == 0) delete this;
		return uCount;
	}
private:
	long m_cRef = 1;

public:
    MediaTracks tracks;
    bool CreatePlane(HWND parent);
    HRESULT PlacePlane(int x, int y, int width, int height);
    void HidePlane();
    void DestroyPlane();
    bool HasPlane() const { return m_plane != nullptr; }

	HRESULT OpenURL(const WCHAR* pszFileName, MyPlayerCallback* playerCallback, HWND hwndVideo, std::vector<std::wstring> httpHeaders, std::function<void(bool)> loadCallback);
	HRESULT Play(LONGLONG ms = -1);
	HRESULT Pause();
	void Shutdown();

	LONGLONG GetDuration();
	LONGLONG GetCurrentPosition();
	HRESULT Seek(LONGLONG ms);
	SIZE GetVideoSize();

	HRESULT SetPlaybackSpeed(float fRate);

	HRESULT GetVolume(float* pVol);
	HRESULT SetVolume(float vol);

	MyPlayer(IDXGIAdapter* adapter);
	virtual ~MyPlayer();

	void priv__videoThreadFunc();

protected:
	virtual void OnPlayerEvent(DWORD event) {};

	DWORD m_VideoWidth;
	DWORD m_VideoHeight;

private:
    HWND m_plane = nullptr;
    Microsoft::WRL::ComPtr<IDCompositionDevice> m_composition;
    Microsoft::WRL::ComPtr<IDCompositionTarget> m_target;
    Microsoft::WRL::ComPtr<IDCompositionVisual> m_visual;
    HRESULT AttachSwapchain();
    void FinishOpen(bool success);
    std::mutex m_openMutex;
    Microsoft::WRL::ComPtr<ID3D11Device> pDX11Device;
	HRESULT initD3D11();
	HRESULT initTexture();
	HRESULT EventNotify(DWORD meEvent, DWORD_PTR param1, DWORD param2);
	HRESULT startVideoThread();
	LONGLONG updateFrame();
	void printErrorMessage(DWORD_PTR param1);

	Microsoft::WRL::ComPtr<MyPlayerCallback> m_frameCallback;
	std::function<void(bool)> m_loadCallback;

    Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> m_pDXGIManager;
	Microsoft::WRL::ComPtr<IDXGIAdapter> m_adapter;
    Microsoft::WRL::ComPtr<IMFMediaEngine> m_pEngine;
    Microsoft::WRL::ComPtr<IMFMediaEngineEx> m_pEngineEx;
	Microsoft::WRL::ComPtr<ID3D11Texture2D> m_pTexture;

	std::mutex m_mutex;
	bool m_hasVideo = false;
	LONGLONG m_maxFrameInterval = 10;

	BOOL m_isPlaying = FALSE;
	BOOL m_isEnded = FALSE;
	HANDLE m_playingEvent = NULL; // win32 event
	LONGLONG m_seekingToPts = -1; // seeking pts if seeking
	std::atomic<bool> m_isShutdown;

    RECT m_frameRectDst = {};
	HANDLE m_threadHandle = NULL;
};
