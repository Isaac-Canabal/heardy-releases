#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Distingue la ventana principal de Heardy de cualquier otra ventana Flutter
// (todas comparten el nombre de clase del runner).
constexpr wchar_t kMainWindowProp[] = L"HeardyMainWindow";
constexpr wchar_t kSingleInstanceMutex[] = L"HeardySingleInstance";

BOOL CALLBACK FindMainWindow(HWND hwnd, LPARAM result) {
  if (::GetProp(hwnd, kMainWindowProp) == nullptr) return TRUE;
  *reinterpret_cast<HWND*>(result) = hwnd;
  return FALSE;
}

// EnumWindows incluye ventanas ocultas, que es justo el caso de Heardy
// guardado en la bandeja del sistema.
void ActivateRunningInstance() {
  HWND found = nullptr;
  // La primera instancia puede estar todavia creando su ventana.
  for (int attempt = 0; attempt < 30 && found == nullptr; ++attempt) {
    ::EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&found));
    if (found == nullptr) ::Sleep(100);
  }
  if (found == nullptr) return;
  if (::IsIconic(found)) {
    ::ShowWindow(found, SW_RESTORE);
  } else if (!::IsWindowVisible(found)) {
    ::ShowWindow(found, SW_SHOW);
  }
  ::SetForegroundWindow(found);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Una sola instancia: si ya hay una abierta, se activa esa y esta termina.
  ::SetLastError(ERROR_SUCCESS);
  HANDLE single_instance = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateRunningInstance();
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"heardy", origin, size)) {
    return EXIT_FAILURE;
  }
  ::SetProp(window.GetHandle(), kMainWindowProp, reinterpret_cast<HANDLE>(1));
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
