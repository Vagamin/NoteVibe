# Сборка и запуск

## Требования

| Платформа | Что нужно |
|---|---|
| все | Flutter 3.47+ (stable), `flutter doctor` без ошибок для нужной платформы |
| Windows | Visual Studio 2022 или Build Tools с нагрузкой «Desktop development with C++» **и компонентом ATL** (`Microsoft.VisualStudio.Component.VC.ATL`); включённый «Режим разработчика» (для symlink плагинов) |
| Android | Android SDK 36, JDK 17, устройство с Android 7+ |
| Linux | `clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libjsoncpp-dev` |
| macOS | Xcode (разрешения на сеть, камеру и `NSCameraUsageDescription` уже добавлены в `macos/Runner`) |

На этой машине уже установлено: Flutter в `C:\src\flutter` (добавлен в PATH пользователя),
JDK Temurin 17, Android SDK 36, компонент ATL, режим разработчика.

## Команды

```powershell
flutter pub get

# Тесты (хранилище, криптография, синхронизация, UI)
flutter test

# Windows
flutter run -d windows
flutter build windows --release     # build\windows\x64\runner\Release\

# Android (телефон подключён по USB с включённой отладкой)
flutter run -d <id>                  # список устройств: flutter devices
flutter build apk --release          # build\app\outputs\flutter-apk\app-release.apk

# Linux / macOS (на соответствующей ОС)
flutter build linux --release
flutter build macos --release
```

## Портативная версия Windows (один файл)

```powershell
powershell -ExecutionPolicy Bypass -File tools\portable\build_portable.ps1
# → release\NoteVibe-<версия>-portable.exe
```

* Внутри exe лежит упакованное приложение вместе с библиотеками VC++. При
  первом запуске оно распаковывается в `%LOCALAPPDATA%\NoteVibe\app\<версия>`,
  при следующих запусках распакованная копия используется повторно.
* Заметки хранятся в папке `NoteVibe-Data` рядом с exe. Если эта папка
  недоступна для записи, используется `%LOCALAPPDATA%\NoteVibe\data`.
* Ключи шифруются Windows DPAPI для текущего пользователя (`keys.dpapi.json`).
  На другом ПК заметки откроются, но устройство придётся сопрячь заново.

## Первое сопряжение

1. Запустите приложение на ПК и на телефоне. Оба устройства должны быть в одной Wi-Fi/LAN-сети.
2. На ПК: **Устройства → Показать код**. Появятся QR-код и 6-значный код (действуют 2 минуты).
3. На телефоне: **Устройства → Сканировать / ввести**, наведите камеру на QR.
   Без камеры: выберите найденное устройство (или укажите IP и порт) и введите код.
4. Готово: заметки начнут синхронизироваться автоматически, когда устройства в одной сети.

## Брандмауэр

При первом запуске Windows спросит разрешение для `notevibe.exe`: разрешите
доступ в **частных** сетях. Если вы отказали или сеть помечена как
общественная, откройте порты вручную (PowerShell от администратора):

```powershell
New-NetFirewallRule -DisplayName "NoteVibe TCP" -Direction Inbound -Protocol TCP -LocalPort 47801 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "NoteVibe UDP" -Direction Inbound -Protocol UDP -LocalPort 47800 -Action Allow -Profile Private
```

На Linux: `sudo ufw allow 47800/udp && sudo ufw allow 47801/tcp`.

## Устранение неполадок

* **Устройства не находят друг друга.** Некоторые роутеры блокируют multicast
  (опция «изоляция клиентов» или «AP isolation»). Укажите IP вручную:
  «Устройства → ⋮ → Указать IP вручную». Адрес ПК показан на экране «Показать код».
* **«Ключ устройства не совпадает».** Другое устройство переустановило
  приложение или сменило ключ. Отвяжите его и выполните сопряжение заново.
* **«Устройство не сопряжено».** Сопряжение удалено на другой стороне. Повторите сопряжение.
* **Сборка Android падает с «Could not close incremental caches».** Это
  известная проблема Kotlin, когда проект и pub-cache лежат на разных дисках.
  В `android/gradle.properties` уже стоит `kotlin.incremental=false`.
* **Где лежат данные.** Windows: `%APPDATA%\com.notevibe\notevibe\notevibe.db`;
  Android: внутренняя память приложения.
