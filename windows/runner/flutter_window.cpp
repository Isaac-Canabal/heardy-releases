#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {
std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], n);
  return w;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "heardy/taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  taskbar_media_ = std::make_unique<TaskbarMedia>(
      GetHandle(), [this](const char* action) {
        taskbar_channel_->InvokeMethod(
            "onAction", std::make_unique<flutter::EncodableValue>(action));
      });
  taskbar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "init") {
          TaskbarMedia::Tooltips tips;
          if (const auto* m =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto get = [m](const char* key) {
              auto it = m->find(flutter::EncodableValue(key));
              const auto* s = it == m->end()
                                  ? nullptr
                                  : std::get_if<std::string>(&it->second);
              return s ? Utf8ToWide(*s) : std::wstring();
            };
            tips = {get("previous"), get("next"), get("play"), get("pause")};
          }
          bool hotkeys = taskbar_media_->Init(tips);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("hotkeysRegistered"),
               flutter::EncodableValue(hotkeys)}}));
        } else if (call.method_name() == "setPlaying") {
          if (const auto* b = std::get_if<bool>(call.arguments())) {
            taskbar_media_->SetPlaying(*b);
          }
          result->Success();
        } else if (call.method_name() == "dispose") {
          taskbar_media_->Dispose();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (taskbar_media_) {
    taskbar_media_->Dispose();
  }
  taskbar_channel_ = nullptr;
  taskbar_media_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  LRESULT taskbar_result = 0;
  if (taskbar_media_ &&
      taskbar_media_->HandleMessage(message, wparam, lparam, &taskbar_result)) {
    return taskbar_result;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
