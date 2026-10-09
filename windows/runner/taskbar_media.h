#ifndef RUNNER_TASKBAR_MEDIA_H_
#define RUNNER_TASKBAR_MEDIA_H_

#include <windows.h>
#include <shobjidl.h>

#include <functional>
#include <string>

// Thumbnail-toolbar buttons (Previous / Play-Pause / Next) on the taskbar
// preview plus global media-key hotkeys. Must live on the window's UI thread.
class TaskbarMedia {
 public:
  struct Tooltips {
    std::wstring previous, next, play, pause;
  };

  // |on_action| receives "previous", "playPause" or "next".
  TaskbarMedia(HWND window, std::function<void(const char*)> on_action);
  ~TaskbarMedia();

  // Returns true only if all three media-key hotkeys were registered.
  bool Init(const Tooltips& tooltips);
  void SetPlaying(bool playing);
  void Dispose();

  // Returns true if the message was consumed (|result| is then valid).
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result);

 private:
  void AddButtons();
  void UpdatePlayButton();
  void DestroyIcons();

  HWND window_;
  std::function<void(const char*)> on_action_;
  UINT button_created_msg_;
  ITaskbarList3* taskbar_ = nullptr;
  bool initialized_ = false;
  bool button_created_ = false;
  bool playing_ = false;
  Tooltips tooltips_;
  HICON icon_prev_ = nullptr, icon_next_ = nullptr, icon_play_ = nullptr,
        icon_pause_ = nullptr;
};

#endif  // RUNNER_TASKBAR_MEDIA_H_
