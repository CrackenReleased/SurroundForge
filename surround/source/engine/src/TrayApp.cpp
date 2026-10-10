// SurroundForge Native Win32 System Tray Application
// Replaces PowerShell Tray.ps1 with a zero-overhead, sub-millisecond native Win32 process.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <strsafe.h>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "ole32.lib")

namespace {

constexpr UINT WM_TRAYICON = WM_USER + 1;
constexpr UINT ID_TRAY_STATUS = 1001;
constexpr UINT ID_TRAY_RESTART = 1002;
constexpr UINT ID_TRAY_SETUP = 1003;
constexpr UINT ID_TRAY_AUTORUN = 1004;
constexpr UINT ID_TRAY_EXIT = 1005;
constexpr UINT TIMER_STATUS_POLL = 1;

NOTIFYICONDATAW g_nid{};
HWND g_hWnd = nullptr;
std::wstring g_rootPath;
std::wstring g_statusText = L"SurroundForge: Checking...";
bool g_isRunning = false;

std::wstring GetExecutableDir() {
    wchar_t buffer[MAX_PATH];
    GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer);
    size_t pos = path.find_last_of(L"\\/");
    return (pos != std::wstring::npos) ? path.substr(0, pos) : L"";
}

std::wstring GetProjectRoot() {
    std::wstring dir = GetExecutableDir();
    size_t pos = dir.rfind(L"\\source\\engine\\build\\Release");
    if (pos != std::wstring::npos) return dir.substr(0, pos);
    pos = dir.rfind(L"\\Runtime");
    if (pos != std::wstring::npos) return dir.substr(0, pos);
    return dir;
}

void UpdateTrayTooltip(const std::wstring& text) {
    StringCchCopyW(g_nid.szTip, ARRAYSIZE(g_nid.szTip), text.c_str());
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

void CheckEngineHealth() {
    std::wstring healthPath = g_rootPath + L"\\surround\\engine-health.json";
    std::ifstream file(healthPath);
    if (!file.is_open()) {
        healthPath = g_rootPath + L"\\engine-health.json";
        file.open(healthPath);
    }

    if (file.is_open()) {
        std::stringstream buffer;
        buffer << file.rdbuf();
        std::string json = buffer.str();
        file.close();

        if (json.find("\"status\":\"ready\"") != std::string::npos ||
            json.find("\"status\": \"ready\"") != std::string::npos) {
            g_isRunning = true;
            g_statusText = L"SurroundForge: Active (48 kHz 5.1 Surround)";
            UpdateTrayTooltip(g_statusText);
            return;
        }
    }

    g_isRunning = false;
    g_statusText = L"SurroundForge: Stopped / Standby";
    UpdateTrayTooltip(g_statusText);
}

void RestartAudio() {
    std::wstring restartCmd = g_rootPath + L"\\surround\\Restart 5.1.cmd";
    if (GetFileAttributesW(restartCmd.c_str()) == INVALID_FILE_ATTRIBUTES) {
        restartCmd = g_rootPath + L"\\Restart 5.1.cmd";
    }

    STARTUPINFOW si{ sizeof(si) };
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};

    std::wstring cmd = L"cmd.exe /c \"" + restartCmd + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(0);

    if (CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, g_rootPath.c_str(), &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        UpdateTrayTooltip(L"SurroundForge: Restarting audio...");
    }
}

void OpenSetup() {
    std::wstring setupScript = g_rootPath + L"\\surround\\Setup.ps1";
    if (GetFileAttributesW(setupScript.c_str()) == INVALID_FILE_ATTRIBUTES) {
        setupScript = g_rootPath + L"\\Setup.ps1";
    }

    std::wstring cmd = L"powershell.exe -ExecutionPolicy Bypass -File \"" + setupScript + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(0);

    STARTUPINFOW si{ sizeof(si) };
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, 0, nullptr, g_rootPath.c_str(), &si, &pi)) {
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

constexpr UINT ID_TRAY_STOP_EXIT = 1006;

HICON CreateSonicAnvilIcon() {
    constexpr int kSize = 32;
    HDC screenDc = GetDC(nullptr);
    HDC memDc = CreateCompatibleDC(screenDc);
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(BITMAPV5HEADER);
    bi.bV5Width = kSize;
    bi.bV5Height = -kSize;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask   = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask  = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HBITMAP colorBmp = CreateDIBSection(screenDc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
    HBITMAP maskBmp = CreateBitmap(kSize, kSize, 1, 1, nullptr);
    HGDIOBJ oldBmp = SelectObject(memDc, colorBmp);

    HBRUSH bgBrush = CreateSolidBrush(RGB(13, 17, 23));
    HPEN cyanPen = CreatePen(PS_SOLID, 2, RGB(0, 228, 196));
    HGDIOBJ oldBrush = SelectObject(memDc, bgBrush);
    HGDIOBJ oldPen = SelectObject(memDc, cyanPen);
    Ellipse(memDc, 1, 1, 31, 31);
    Arc(memDc, 4, 4, 28, 28, 26, 6, 6, 26);

    POINT anvil[] = {
        {5, 14}, {11, 14}, {12, 13}, {25, 13}, {24, 15},
        {20, 17}, {19, 20}, {22, 23}, {22, 25}, {18, 25},
        {16, 23}, {14, 25}, {10, 25}, {10, 23}, {13, 20},
        {12, 17}, {8, 16}
    };
    HBRUSH goldBrush = CreateSolidBrush(RGB(255, 182, 48));
    HPEN goldPen = CreatePen(PS_SOLID, 1, RGB(255, 218, 110));
    SelectObject(memDc, goldBrush);
    SelectObject(memDc, goldPen);
    Polygon(memDc, anvil, ARRAYSIZE(anvil));

    SelectObject(memDc, oldBrush);
    SelectObject(memDc, oldPen);
    DeleteObject(goldBrush);
    DeleteObject(goldPen);
    DeleteObject(bgBrush);
    DeleteObject(cyanPen);
    SelectObject(memDc, oldBmp);
    DeleteDC(memDc);
    ReleaseDC(nullptr, screenDc);

    DWORD* pixel = static_cast<DWORD*>(bits);
    for (int i = 0; i < kSize * kSize; ++i) {
        if ((pixel[i] & 0x00FFFFFF) != 0) pixel[i] |= 0xFF000000;
    }

    ICONINFO ii{};
    ii.fIcon = TRUE;
    ii.hbmMask = maskBmp;
    ii.hbmColor = colorBmp;
    HICON hIcon = CreateIconIndirect(&ii);
    DeleteObject(colorBmp);
    DeleteObject(maskBmp);
    return hIcon ? hIcon : LoadIconW(nullptr, reinterpret_cast<LPCWSTR>(IDI_APPLICATION));
}

void StopAudioAndExit(HWND hWnd) {
    std::wstring stopCmd = g_rootPath + L"\\surround\\Stop 5.1.cmd";
    if (GetFileAttributesW(stopCmd.c_str()) == INVALID_FILE_ATTRIBUTES) {
        stopCmd = g_rootPath + L"\\Stop 5.1.cmd";
    }
    STARTUPINFOW si{ sizeof(si) };
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"cmd.exe /c \"" + stopCmd + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(0);
    if (CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, g_rootPath.c_str(), &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 10000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
    DestroyWindow(hWnd);
}

void ShowContextMenu(HWND hWnd, POINT pt) {
    HMENU hMenu = CreatePopupMenu();
    if (!hMenu) return;

    InsertMenuW(hMenu, 0, MF_BYPOSITION | MF_STRING | MF_GRAYED, ID_TRAY_STATUS, g_statusText.c_str());
    InsertMenuW(hMenu, 1, MF_BYPOSITION | MF_SEPARATOR, 0, nullptr);
    InsertMenuW(hMenu, 2, MF_BYPOSITION | MF_STRING, ID_TRAY_RESTART, L"&Restart 5.1 Audio");
    InsertMenuW(hMenu, 3, MF_BYPOSITION | MF_STRING, ID_TRAY_SETUP, L"&Configure Setup...");
    InsertMenuW(hMenu, 4, MF_BYPOSITION | MF_SEPARATOR, 0, nullptr);
    InsertMenuW(hMenu, 5, MF_BYPOSITION | MF_STRING, ID_TRAY_STOP_EXIT, L"&Stop 5.1 Audio && Close");
    InsertMenuW(hMenu, 6, MF_BYPOSITION | MF_STRING, ID_TRAY_EXIT, L"E&xit Tray (Audio Continues)");

    SetForegroundWindow(hWnd);
    TrackPopupMenu(hMenu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hWnd, nullptr);
    DestroyMenu(hMenu);
}

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_TRAYICON:
        if (LOWORD(lParam) == WM_RBUTTONUP || LOWORD(lParam) == WM_LBUTTONUP) {
            POINT pt;
            GetCursorPos(&pt);
            ShowContextMenu(hWnd, pt);
        }
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case ID_TRAY_RESTART:
            RestartAudio();
            break;
        case ID_TRAY_SETUP:
            OpenSetup();
            break;
        case ID_TRAY_STOP_EXIT:
            StopAudioAndExit(hWnd);
            break;
        case ID_TRAY_EXIT:
            DestroyWindow(hWnd);
            break;
        }
        return 0;

    case WM_TIMER:
        if (wParam == TIMER_STATUS_POLL) {
            CheckEngineHealth();
        }
        return 0;

    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, PWSTR, int) {
    g_rootPath = GetProjectRoot();

    // Prevent duplicate instances
    HANDLE hMutex = CreateMutexW(nullptr, TRUE, L"Global\\SurroundForge_Tray_Instance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (hMutex) CloseHandle(hMutex);
        return 0;
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(WNDCLASSEXW);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.lpszClassName = L"SurroundForgeTrayClass";
    RegisterClassExW(&wc);

    g_hWnd = CreateWindowExW(0, wc.lpszClassName, L"SurroundForge Tray", WS_OVERLAPPEDWINDOW,
                             0, 0, 0, 0, nullptr, nullptr, hInstance, nullptr);
    if (!g_hWnd) return 1;

    HICON hIcon = CreateSonicAnvilIcon();

    g_nid.cbSize = sizeof(NOTIFYICONDATAW);
    g_nid.hWnd = g_hWnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAYICON;
    g_nid.hIcon = hIcon;
    StringCchCopyW(g_nid.szTip, ARRAYSIZE(g_nid.szTip), L"SurroundForge 5.1");
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    CheckEngineHealth();
    SetTimer(g_hWnd, TIMER_STATUS_POLL, 3000, nullptr);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (hMutex) {
        ReleaseMutex(hMutex);
        CloseHandle(hMutex);
    }
    return static_cast<int>(msg.wParam);
}
