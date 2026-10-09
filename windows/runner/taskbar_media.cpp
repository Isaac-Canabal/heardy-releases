#include "taskbar_media.h"

#include <cmath>
#include <vector>

namespace {

constexpr UINT kIdPrevious = 0, kIdPlayPause = 1, kIdNext = 2;
constexpr int kHotkeyBase = 0xB001;  // 3 consecutive ids

enum class Glyph { kPrevious, kNext, kPlay, kPause };

bool InRect(double x, double y, double x0, double x1, double y0, double y1) {
  return x >= x0 && x <= x1 && y >= y0 && y <= y1;
}

// Shapes in a unit square.
bool Covered(Glyph g, double x, double y) {
  switch (g) {
    case Glyph::kPrevious:
      return InRect(x, y, .18, .28, .2, .8) ||
             (x >= .35 && x <= .8 && std::fabs(y - .5) <= (x - .35) / .45 * .3);
    case Glyph::kNext:
      return Covered(Glyph::kPrevious, 1 - x, y);
    case Glyph::kPlay:
      return x >= .25 && x <= .8 && std::fabs(y - .5) <= (.8 - x) / .55 * .3;
    case Glyph::kPause:
      return InRect(x, y, .25, .42, .2, .8) || InRect(x, y, .58, .75, .2, .8);
  }
  return false;
}

// White glyph on transparent, 4x4 supersampled, premultiplied ARGB.
HICON MakeIcon(Glyph glyph, int size) {
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = size;
  bi.bmiHeader.biHeight = -size;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  ReleaseDC(nullptr, dc);
  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  if (!color || !mask || !bits) {
    if (color) DeleteObject(color);
    if (mask) DeleteObject(mask);
    return nullptr;
  }
  auto* px = static_cast<uint32_t*>(bits);
  for (int row = 0; row < size; ++row) {
    for (int col = 0; col < size; ++col) {
      int hits = 0;
      for (int sy = 0; sy < 4; ++sy)
        for (int sx = 0; sx < 4; ++sx)
          hits += Covered(glyph, (col + (sx + .5) / 4) / size,
                          (row + (sy + .5) / 4) / size);
      uint32_t a = static_cast<uint32_t>(hits * 255 / 16);
      px[row * size + col] = (a << 24) | (a << 16) | (a << 8) | a;
    }
  }
  ICONINFO info = {TRUE, 0, 0, mask, color};
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(color);
  DeleteObject(mask);
  return icon;
}

void CopyTip(wchar_t (&dst)[260], const std::wstring& src) {
  wcsncpy_s(dst, src.c_str(), _TRUNCATE);
}

}  // namespace

TaskbarMedia::TaskbarMedia(HWND window,
                           std::function<void(const char*)> on_action)
    : window_(window),
      on_action_(std::move(on_action)),
      button_created_msg_(RegisterWindowMessageW(L"TaskbarButtonCreated")) {}

TaskbarMedia::~TaskbarMedia() { Dispose(); }

bool TaskbarMedia::Init(const Tooltips& tooltips) {
  tooltips_ = tooltips;
  if (initialized_) {
    UpdatePlayButton();
    return true;
  }
  initialized_ = true;

  UINT dpi = GetDpiForWindow(window_);
  int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi ? dpi : 96);
  icon_prev_ = MakeIcon(Glyph::kPrevious, size);
  icon_next_ = MakeIcon(Glyph::kNext, size);
  icon_play_ = MakeIcon(Glyph::kPlay, size);
  icon_pause_ = MakeIcon(Glyph::kPause, size);

  // All-or-nothing: a partial set would leave some keys global and others
  // in-app only, which the Dart side cannot distinguish.
  const UINT keys[3] = {VK_MEDIA_PREV_TRACK, VK_MEDIA_PLAY_PAUSE,
                        VK_MEDIA_NEXT_TRACK};
  bool all = true;
  for (int i = 0; i < 3; ++i) {
    if (!RegisterHotKey(window_, kHotkeyBase + i, MOD_NOREPEAT, keys[i])) {
      all = false;
    }
  }
  if (!all) {
    for (int i = 0; i < 3; ++i) UnregisterHotKey(window_, kHotkeyBase + i);
  }

  // The taskbar button may already exist (message arrived before Dart's init).
  if (button_created_) AddButtons();
  return all;
}

void TaskbarMedia::AddButtons() {
  if (taskbar_) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  // COM is already initialized (STA) by main.cpp.
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&taskbar_))) ||
      !taskbar_ || FAILED(taskbar_->HrInit())) {
    if (taskbar_) taskbar_->Release();
    taskbar_ = nullptr;
    return;
  }
  THUMBBUTTON b[3] = {};
  const struct {
    UINT id;
    HICON icon;
    const std::wstring* tip;
  } spec[3] = {{kIdPrevious, icon_prev_, &tooltips_.previous},
               {kIdPlayPause, playing_ ? icon_pause_ : icon_play_,
                playing_ ? &tooltips_.pause : &tooltips_.play},
               {kIdNext, icon_next_, &tooltips_.next}};
  for (int i = 0; i < 3; ++i) {
    b[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    b[i].iId = spec[i].id;
    b[i].hIcon = spec[i].icon;
    b[i].dwFlags = THBF_ENABLED;  // no THBF_DISMISSONCLICK: keep preview open
    CopyTip(b[i].szTip, *spec[i].tip);
  }
  // Fails with E_INVALIDARG if the buttons already exist for this taskbar
  // button (only one add per taskbar button); that is harmless.
  taskbar_->ThumbBarAddButtons(window_, 3, b);
}

void TaskbarMedia::UpdatePlayButton() {
  if (!taskbar_) return;
  THUMBBUTTON b = {};
  b.dwMask = THB_ICON | THB_TOOLTIP;
  b.iId = kIdPlayPause;
  b.hIcon = playing_ ? icon_pause_ : icon_play_;
  CopyTip(b.szTip, playing_ ? tooltips_.pause : tooltips_.play);
  taskbar_->ThumbBarUpdateButtons(window_, 1, &b);
}

void TaskbarMedia::SetPlaying(bool playing) {
  playing_ = playing;
  UpdatePlayButton();
}

bool TaskbarMedia::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                 LRESULT* result) {
  if (message == button_created_msg_ && button_created_msg_ != 0) {
    // Sent again if explorer.exe restarts; a fresh add restores the buttons.
    button_created_ = true;
    if (initialized_) AddButtons();
    *result = 0;
    return true;
  }
  if (!initialized_) return false;
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    switch (LOWORD(wparam)) {
      case kIdPrevious: on_action_("previous"); break;
      case kIdPlayPause: on_action_("playPause"); break;
      case kIdNext: on_action_("next"); break;
      default: return false;
    }
    *result = 0;
    return true;
  }
  if (message == WM_HOTKEY && wparam >= kHotkeyBase &&
      wparam < kHotkeyBase + 3) {
    static const char* const actions[3] = {"previous", "playPause", "next"};
    on_action_(actions[wparam - kHotkeyBase]);
    *result = 0;
    return true;
  }
  return false;
}

void TaskbarMedia::DestroyIcons() {
  for (HICON* i : {&icon_prev_, &icon_next_, &icon_play_, &icon_pause_}) {
    if (*i) DestroyIcon(*i);
    *i = nullptr;
  }
}

void TaskbarMedia::Dispose() {
  if (initialized_) {
    for (int i = 0; i < 3; ++i) UnregisterHotKey(window_, kHotkeyBase + i);
    initialized_ = false;
  }
  if (taskbar_) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
  DestroyIcons();
}
