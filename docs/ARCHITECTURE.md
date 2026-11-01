# Архитектура NoteVibe

## Стек и почему он

| Слой | Технология | Причина |
|---|---|---|
| UI | Flutter 3.47 (Material 3) | Один код и один внешний вид для Android, Windows, Linux и macOS |
| Состояние | Riverpod 3 | Модульность, лёгкая подмена зависимостей в тестах |
| Хранение | SQLite через `package:sqlite3` | Встроенный SQLite на всех платформах, транзакции, WAL, тесты на базе в памяти |
| Редактор | flutter_quill 11 | Формат Delta (JSON), чек-листы, встроенные Ctrl+B/I/U, undo/redo |
| Криптография | `cryptography` (чистый Dart) | X25519, HKDF-SHA256, ChaCha20-Poly1305 и Argon2id одинаково работают везде |
| Ключи | flutter_secure_storage | Android Keystore, Windows DPAPI, macOS Keychain, Linux libsecret |
| Сеть | `dart:io` (UDP + TCP) | Работает без нативного кода на всех настольных ОС и Android |
| QR | qr_flutter, mobile_scanner | Показ QR на любой платформе, сканирование на Android и macOS |

## Структура

```
lib/
  main.dart                     запуск, тема, локализация
  domain/                       чистые модели без Flutter
    note.dart                   Note + сериализация для передачи по сети
    version_vector.dart         векторы версий (сравнение, слияние)
    conflict.dart, peer.dart
  data/
    schema.dart                 миграции SQLite (PRAGMA user_version)
    note_store.dart             CRUD, журнал изменений, поиск, применение
                                удалённых изменений, конфликты, устройства, настройки
  sync/                         чистый Dart, полностью покрыт тестами
    transport/frame_channel.dart   кадры с префиксом длины поверх TCP; канал в памяти для тестов
    crypto/keys.dart               идентичность устройства, хранилище ключей
    crypto/secure_channel.dart     рукопожатие и шифрованный канал
    discovery/lan_discovery.dart   UDP-маяки (multicast + broadcast)
    pairing/pairing.dart           QR-полезная нагрузка, одноразовые коды
    engine/sync_engine.dart        протокол обмена изменениями
    sync_service.dart              оркестрация: сервер, автосинхронизация, повторы, статусы
  ui/
    providers.dart              DI и состояние (Riverpod)
    theme/  layout/  notes_list/  editor/  conflicts/  devices/  settings/  widgets/
test/
  data/      хранилище
  sync/      криптография, движок, сервис через настоящий TCP
  widget/    интерфейс
```

Зависимости направлены строго внутрь: `ui → sync/data → domain`. Слой `sync`
не знает о Flutter, поэтому новый транспорт (Bluetooth, Wi-Fi Direct) — это
новая реализация `FrameChannel`, без изменений в движке.

## Модели данных (SQLite)

```sql
notes(
  id TEXT PK,             -- UUID v4
  title, content,         -- content = Quill Delta JSON
  plain, search,          -- текст для превью и поиска (lower-case)
  created, updated,       -- мс от эпохи
  vv TEXT,                -- вектор версий {"deviceId": counter}
  dev TEXT,               -- устройство, создавшее эту версию
  deleted INT,            -- метка удаления (tombstone), удаление тоже синхронизируется
  seq INT,                -- локальный монотонный номер последнего изменения (курсор синхронизации)
  src TEXT,               -- от какого устройства получена версия (чтобы не отправлять её обратно)
  dismissed TEXT          -- ключи отклонённых конфликтных версий
)
change_log(seq PK AUTOINCREMENT, note_id, op, vv, device, at)   -- журнал всех изменений
conflicts(id, note_id, loser_key, payload, detected)            -- альтернативные версии
peers(device_id PK, name, public_key, paired, last_sync, addr, port, epoch, recv_cursor)
settings(key PK, value)
```

* Каждое локальное изменение выполняется одной транзакцией: обновляется
  заметка, к вектору версий добавляется `+1` для своего устройства,
  дописывается запись в `change_log`, назначается новый `seq`.
* База работает в режиме WAL, поэтому сбой или аварийное завершение не портят данные.
* Публичные ключи устройств дублируются в защищённом хранилище ОС. При
  рукопожатии используется именно эта копия, поэтому подмена файла базы не
  позволит выдать себя за сопряжённое устройство.
* Закрытый ключ устройства хранится **только** в защищённом хранилище ОС.

## Автосохранение

Редактор сохраняет изменения через 500 мс после последнего нажатия, а также
при уходе со страницы, сворачивании или закрытии приложения. Если заметку
изменили удалённо, а у пользователя нет несохранённых правок, редактор
перезагружает её на лету.
