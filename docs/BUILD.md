# Сборка и запуск

## Требования

| Платформа | Что нужно |
|---|---|
| все | Flutter 3.47+ (stable), `flutter doctor` без ошибок для нужной платформы |
| Windows | Visual Studio 2022 или Build Tools с нагрузкой «Desktop development with C++» и компонентом ATL (`Microsoft.VisualStudio.Component.VC.ATL`); включённый режим разработчика (для symlink плагинов) |
| Android | Android SDK 36, JDK 17, устройство с Android 7+ |

Linux и macOS в проект не входят: папки `linux/` и `macos/` есть, но сборки
не проверялись и в релизах не публикуются.

## Команды

```powershell
flutter pub get

# Тесты (хранилище, миграции, криптография, синхронизация)
flutter test --no-pub --concurrency=1

# Windows
flutter run -d windows
flutter build windows --release --no-pub      # build\windows\x64\runner\Release\

# Android (телефон по USB с отладкой)
flutter run -d <id>                           # список: flutter devices
flutter build apk --release --split-per-abi --no-pub
```

Флаг `--concurrency=1` нужен: тесты синхронизации открывают сокеты на
фиксированных портах, параллельный запуск даёт ложные падения.

## Портативная версия Windows (один файл)

```powershell
flutter build windows --release --no-pub
powershell -ExecutionPolicy Bypass -File tools\portable\build_portable.ps1 -SkipFlutterBuild
# → release\NoteVibe-<версия>-portable.exe
```

* Внутри exe лежит приложение вместе с библиотеками VC++. При первом запуске
  оно распаковывается в `%LOCALAPPDATA%\NoteVibe\app\<версия>`.
* Заметки хранятся в папке `NoteVibe-Data` рядом с exe. Если она недоступна
  для записи, используется `%LOCALAPPDATA%\NoteVibe\data`.
* Ключи шифруются Windows DPAPI для текущего пользователя (`keys.dpapi.json`).
  На другом ПК заметки откроются, но устройство придётся сопрячь заново.

## Подпись релизных APK

Релизные APK подписываются ключом из `android/key.properties` (файл не в git).
Ключ и пароли нужно хранить отдельно: без них обновление поверх уже
установленного приложения невозможно.

## Брандмауэр

При первом запуске Windows спросит разрешение для `notevibe.exe`: разрешите
доступ в частных сетях. Если отказали, откройте порты вручную (PowerShell от администратора):

```powershell
New-NetFirewallRule -DisplayName "NoteVibe TCP" -Direction Inbound -Protocol TCP -LocalPort 47801 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "NoteVibe UDP" -Direction Inbound -Protocol UDP -LocalPort 47800 -Action Allow -Profile Private
```

## Устранение неполадок

* **Устройства не находят друг друга.** Роутер может блокировать multicast
  («изоляция клиентов», «AP isolation»). Укажите IP вручную: «Устройства → ⋮ →
  Указать IP вручную». Адрес ПК показан на экране «Показать код».
* **«Ключ устройства не совпадает».** Другое устройство переустановило
  приложение или сменило ключ. Отвяжите его и выполните сопряжение заново.
* **«Устройство не сопряжено».** Сопряжение удалено на другой стороне. Повторите сопряжение.
* **Список заметок пустой или серый после обновления.** Обычно ошибка схемы
  базы. Сначала сохраните копию папки с данными, затем обновитесь до последней
  версии и пришлите текст ошибки, если не помогло.
* **Сборка Android падает с «Could not close incremental caches».** Проект и
  pub-cache на разных дисках. В `android/gradle.properties` уже стоит `kotlin.incremental=false`.
* **Где лежат данные.** Windows portable: `NoteVibe-Data` рядом с exe. Установленная
  версия: `%APPDATA%\com.notevibe\notevibe\notevibe.db`. Android: внутренняя память приложения.
