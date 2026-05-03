################################################################
## УТИЛИТА ДЛЯ ПОДБОРА ПАРОЛЯ К 7-ZIP АРХИВУ
##
## Версия:   4.0
## Дата:     2026-05-03
## Автор:    github.com/Balans097
##
## Компиляция: nim c -d:release find7zpass.nim
## Запуск:     ./find7zpass [путь_к_архиву]
##             find7zpass.exe [путь_к_архиву]
##
## Файлы конфигурации:
##   find7zpass.cfg   — основные настройки (путь к архиву, длина перебора, …)
##   wordlist.txt     — паттерны и спецсимволы в двух секциях:
##                        [patterns]  — словесные фрагменты пароля
##                        [specials]  — символы, расставляемые между словами
##
## Модель генерации паролей:
##   Пароль = [sym0] word0 [sym1] word1 [sym2] … wordN [symN+1]
##   Каждый sym выбирается независимо из секции [specials].
##   Пример: #secret_world@2023!
##
## Локализация:
##   Язык интерфейса задаётся параметром lang в find7zpass.cfg (ru / en).
################################################################

import std/[
  os,        # fileExists, commandLineParams, quit
  osproc,    # execCmdEx — запуск внешнего процесса и получение его кода возврата
  strutils,  # join, formatFloat, repeat, strip, splitLines
  sequtils,  # mapIt — трансформация последовательности элементов по индексам
  times,     # epochTime — замер астрономического времени выполнения
]


# ==============================================================================
#  СЕКЦИЯ ЛОКАЛИЗАЦИИ
#
#  Все строки интерфейса хранятся здесь в виде двух наборов констант.
#  Функция getMsg() выбирает нужный набор по коду языка.
# ==============================================================================

type
  ## Перечисление поддерживаемых языков интерфейса.
  Lang = enum
    langRu = "ru"  ## Русский
    langEn = "en"  ## English

  ## Структура, содержащая все строки интерфейса для одного языка.
  ## Добавление нового языка: объявить константу типа Messages и
  ## добавить ветку в getMsg().
  Messages = object
    errArchiveNotFound : string  ## Файл архива не найден
    errUsage           : string  ## Строка подсказки об использовании
    errWordlistNotFound: string  ## Файл wordlist не найден
    errNoPatterns      : string  ## Секция [patterns] пуста или отсутствует
    errNoSpecials      : string  ## Секция [specials] пуста или отсутствует
    errConfigNotFound  : string  ## Файл конфигурации не найден
    errBadMaxComboLen  : string  ## Некорректное значение max_combo_len
    errBadProgressStep : string  ## Некорректное значение progress_step
    hdrCmd             : string  ## Подпись «команда 7-Zip»
    hdrArchive         : string  ## Подпись «архив»
    hdrPatterns        : string  ## Подпись «паттернов»
    hdrSpecials        : string  ## Подпись «спецсимволов»
    hdrMaxLen          : string  ## Подпись «максимальная длина»
    msgComboHeader     : string  ## Заголовок блока перебора (формат: $1 = длина)
    msgProgress        : string  ## Строка прогресса (формат: $1 $2 $3)
    msgFound           : string  ## Пароль найден
    msgTested          : string  ## Проверено комбинаций
    msgElapsed         : string  ## Затрачено времени
    msgNotFound        : string  ## Пароль не найден
    msgHint            : string  ## Совет при неудаче

## Строки на русском языке.
const RU = Messages(
  errArchiveNotFound  : "Ошибка: файл архива не найден: ",
  errUsage            : "Использование: find7zpass [путь_к_архиву]",
  errWordlistNotFound : "Ошибка: файл списка слов не найден: ",
  errNoPatterns       : "Ошибка: секция [patterns] пуста или отсутствует в файле списка слов",
  errNoSpecials       : "Ошибка: секция [specials] пуста или отсутствует в файле списка слов",
  errConfigNotFound   : "Ошибка: файл конфигурации не найден: ",
  errBadMaxComboLen   : "Ошибка: некорректное значение max_combo_len в конфиге",
  errBadProgressStep  : "Ошибка: некорректное значение progress_step в конфиге",
  hdrCmd              : "7-Zip команда : ",
  hdrArchive          : "Архив         : ",
  hdrPatterns         : "Паттернов     : ",
  hdrSpecials         : "Спецсимволов  : ",
  hdrMaxLen           : "Макс. длина   : ",
  msgComboHeader      : "\n[Перебираем комбинации из $1 паттернов]",
  msgProgress         : "  Проверено: $1 | Время: $2 | Текущий: $3",
  msgFound            : "ПАРОЛЬ НАЙДЕН: ",
  msgTested           : "  Проверено комбинаций : ",
  msgElapsed          : "  Затрачено времени    : ",
  msgNotFound         : "Пароль не найден среди ",
  msgHint             : "  Совет: добавьте паттерны/спецсимволы или увеличьте max_combo_len",
)

## Строки на английском языке.
const EN = Messages(
  errArchiveNotFound  : "Error: archive file not found: ",
  errUsage            : "Usage: find7zpass [path_to_archive]",
  errWordlistNotFound : "Error: wordlist file not found: ",
  errNoPatterns       : "Error: [patterns] section is empty or missing in wordlist file",
  errNoSpecials       : "Error: [specials] section is empty or missing in wordlist file",
  errConfigNotFound   : "Error: config file not found: ",
  errBadMaxComboLen   : "Error: invalid max_combo_len value in config",
  errBadProgressStep  : "Error: invalid progress_step value in config",
  hdrCmd              : "7-Zip command : ",
  hdrArchive          : "Archive       : ",
  hdrPatterns         : "Patterns      : ",
  hdrSpecials         : "Specials      : ",
  hdrMaxLen           : "Max length    : ",
  msgComboHeader      : "\n[Trying combinations of $1 patterns]",
  msgProgress         : "  Tested: $1 | Time: $2 | Current: $3",
  msgFound            : "PASSWORD FOUND: ",
  msgTested           : "  Combinations tested : ",
  msgElapsed          : "  Time elapsed        : ",
  msgNotFound         : "Password not found among ",
  msgHint             : "  Hint: add more patterns/specials or increase max_combo_len",
)

proc getMsg(lang: Lang): Messages =
  ## Возвращает набор строк интерфейса для заданного языка.
  case lang
  of langRu: return RU
  of langEn: return EN


# ==============================================================================
#  СЕКЦИЯ КОНФИГУРАЦИИ
#
#  Конфигурационный файл — простой текстовый формат «ключ = значение».
#  Пустые строки и строки, начинающиеся с «#», игнорируются.
#  Все известные параметры описаны в Config ниже.
# ==============================================================================

## Путь к конфигурационному файлу по умолчанию (рядом с исполняемым файлом).
const DEFAULT_CONFIG_PATH = "find7zpass.cfg"

type
  ## Структура с разобранными параметрами конфигурации.
  ## Все поля заполняются значениями по умолчанию, если ключ отсутствует в файле.
  Config = object
    archivePath  : string  ## Путь к 7z-архиву (ключ: archive)
    wordlistPath : string  ## Путь к файлу со списком слов и спецсимволов (ключ: wordlist)
    maxComboLen  : int     ## Макс. число паттернов в одной комбинации (ключ: max_combo_len)
    progressStep : int     ## Шаг вывода прогресса (ключ: progress_step)
    lang         : Lang    ## Язык интерфейса: ru или en (ключ: lang)

proc parseConfig(path: string): Config =
  ## Разбирает конфигурационный файл и возвращает заполненную структуру Config.
  ##
  ## Формат файла:
  ##   # комментарий
  ##   ключ = значение
  ##
  ## Неизвестные ключи молча игнорируются, что позволяет добавлять
  ## пользовательские комментарии-параметры без изменения программы.

  # Значения по умолчанию — используются, если ключ не задан в файле
  result = Config(
    archivePath  : "archive.7z",
    wordlistPath : "wordlist.txt",
    maxComboLen  : 3,
    progressStep : 100,
    lang         : langRu,
  )

  # Читаем файл целиком и разбираем строку за строкой
  let content = readFile(path)
  for rawLine in splitLines(content):
    # Убираем пробелы по краям и пропускаем пустые строки и комментарии
    let line = strip(rawLine)
    if len(line) == 0 or line[0] == '#':
      continue

    # Делим строку по первому знаку «=»; всё, что левее — ключ, правее — значение
    let eqPos = find(line, '=')
    if eqPos < 0:
      continue  # нет знака «=» — строка не является параметром

    let
      key = strip(line[0 ..< eqPos])
      val = strip(line[eqPos + 1 .. ^1])

    case key
    of "archive":
      result.archivePath = val
    of "wordlist":
      result.wordlistPath = val
    of "max_combo_len":
      result.maxComboLen = parseInt(val)
    of "progress_step":
      result.progressStep = parseInt(val)
    of "lang":
      case val
      of "en": result.lang = langEn
      else:    result.lang = langRu
    else:
      discard  # неизвестный ключ — игнорируем


# ==============================================================================
#  СЕКЦИЯ ЗАГРУЗКИ WORDLIST
#
#  Файл wordlist.txt имеет формат с именованными секциями:
#
#    [patterns]       ← маркер начала секции словесных паттернов
#    hello
#    world
#    2024
#
#    [specials]       ← маркер начала секции спецсимволов
#    <empty>          ← кодовое слово для пустой строки (нет символа)
#    _
#    @
#    !
#
#  Строки, начинающиеся с «#», и пустые строки в обеих секциях игнорируются.
#  Порядок секций в файле не важен.
#  Маркер секции — строка вида «[имя]», без пробелов внутри скобок.
# ==============================================================================

type
  ## Результат разбора wordlist-файла.
  ## Передаётся в main() и используется независимо для генерации комбинаций.
  Wordlist = object
    patterns : seq[string]  ## Словесные паттерны из секции [patterns]
    specials : seq[string]  ## Спецсимволы из секции [specials] (пустая строка включена)

proc loadWordlist(path: string): Wordlist =
  ## Читает wordlist-файл с двумя секциями и возвращает заполненную структуру Wordlist.
  ##
  ## Алгоритм: однопроходное чтение строк.
  ## Переменная `section` хранит имя текущей активной секции.
  ## При встрече строки «[имя]» — переключаемся на новую секцию.
  ## Все прочие непустые и некомментарные строки добавляются в активную секцию.
  result = Wordlist(patterns: @[], specials: @[])

  var section = ""  # имя текущей активной секции; "" = вне секций

  let content = readFile(path)
  for rawLine in splitLines(content):
    let line = strip(rawLine)

    # Пропускаем пустые строки и комментарии
    if len(line) == 0 or line[0] == '#':
      continue

    # Проверяем, не является ли строка маркером секции вида «[имя]»
    if line[0] == '[' and line[^1] == ']':
      # Извлекаем имя секции между скобками и переключаем контекст
      section = line[1 ..< len(line) - 1]
      continue

    # Обрабатываем строку в зависимости от активной секции
    case section
    of "patterns":
      # Кодовое слово <hash> → символ «#» (актуально если паттерн начинается с #)
      if line == "<hash>":
        add(result.patterns, "#")
      else:
        add(result.patterns, line)
    of "specials":
      # Специальное кодовое слово <empty> → пустая строка («нет символа»)
      # Специальное кодовое слово <hash>  → символ «#» (иначе парсер съест его как комментарий)
      if line == "<empty>":
        add(result.specials, "")
      elif line == "<hash>":
        add(result.specials, "#")
      else:
        add(result.specials, line)
    else:
      discard  # строка вне известных секций — игнорируем

  # Гарантируем присутствие пустой строки в specials:
  # без неё невозможно получить пароль без символа в какой-либо позиции.
  # Если пользователь не добавил <empty> явно — добавляем автоматически.
  var hasEmpty = false
  for s in result.specials:
    if s == "":
      hasEmpty = true
      break
  if not hasEmpty:
    add(result.specials, "")


# ==============================================================================
#  СЕКЦИЯ ПОИСКА 7-ZIP И ПРОВЕРКИ ПАРОЛЕЙ
# ==============================================================================

proc get7zCmd(): string =
  ## Возвращает команду запуска 7-Zip, подходящую для текущей ОС.
  ## На Windows ищет исполняемый файл по стандартным путям установки;
  ## если не найден — рассчитывает на то, что 7z.exe прописан в PATH.
  ## На Linux и macOS достаточно просто «7z» (пакет p7zip).
  when defined(windows):
    const windowsPaths = [
      r"C:\Program Files\7-Zip\7z.exe",
      r"C:\Program Files (x86)\7-Zip\7z.exe",
      "7z.exe",  # крайний случай: 7z.exe лежит рядом или прописан в PATH
    ]
    for p in windowsPaths:
      if fileExists(p):
        return p
    return "7z.exe"
  else:
    return "7z"

proc tryPassword(sevenZip, archive, password: string): bool =
  ## Проверяет один пароль, запуская 7-Zip в режиме тестирования архива.
  ##
  ## Флаг «t» (test) проверяет целостность архива без извлечения файлов на диск —
  ## это быстрее и не засоряет файловую систему.
  ## Флаг «-y» подавляет все интерактивные вопросы 7-Zip.
  ##
  ## Код возврата 0 означает успех (пароль верный и архив не повреждён).
  let cmd = sevenZip & " t -p\"" & password & "\" -y \"" & archive & "\""
  let (_, exitCode) = execCmdEx(cmd)
  return exitCode == 0


# ==============================================================================
#  СЕКЦИЯ ГЕНЕРАТОРА КОМБИНАЦИЙ СЛОВ
# ==============================================================================

iterator combos(patterns: seq[string], length: int): seq[string] =
  ## Итератор, порождающий все комбинации с повторениями из `patterns` длиной `length`.
  ##
  ## Принцип работы — счётчик в системе счисления с основанием len(patterns):
  ##   indices = [0, 0, 0]  →  [pat0, pat0, pat0]
  ##   indices = [0, 0, 1]  →  [pat0, pat0, pat1]
  ##   …
  ##   indices = [n-1, n-1, n-1]  →  [patN, patN, patN]
  ##
  ## После последней комбинации pos уходит в -1 и цикл завершается.
  let n = len(patterns)

  # indices[i] — текущий индекс паттерна на позиции i в комбинации слов
  var indices = newSeq[int](length)  # инициализируется нулями

  while true:
    yield mapIt(indices, patterns[it])

    # Инкрементируем «счётчик» с младшего разряда (rightmost-first)
    var pos = length - 1
    while pos >= 0:
      indices[pos] += 1
      if indices[pos] < n:
        break
      indices[pos] = 0
      dec pos

    if pos < 0:
      break  # все разряды переполнились — комбинации слов исчерпаны


# ==============================================================================
#  СЕКЦИЯ ГЕНЕРАТОРА РАССТАНОВОК СПЕЦСИМВОЛОВ
#
#  Для комбинации из N слов существует N+1 позиций для спецсимволов:
#
#    [sym0] word0 [sym1] word1 [sym2] … word(N-1) [symN]
#
#  Каждый sym независимо выбирается из списка specials (включая пустую строку).
#  Итератор перебирает все (len(specials))^(N+1) вариантов расстановки.
#
#  Пример для N=2 слова, specials = ["", "_", "@"]:
#    ["", "", ""]   →  word0word1
#    ["", "", "@"]  →  word0word1@
#    ["", "_", ""]  →  word0_word1
#    ["@", "_", "!"] →  @word0_word1!
#    …
# ==============================================================================

iterator symPlacements(specials: seq[string], slots: int): seq[string] =
  ## Итератор, порождающий все расстановки спецсимволов для `slots` позиций.
  ## `slots` = число слов + 1 (позиция перед первым словом,
  ##           между каждой парой слов, позиция после последнего слова).
  ##
  ## Внутренний счётчик аналогичен combos: система счисления с основанием
  ## len(specials), разряды перебираются от младшего к старшему.
  let s = len(specials)

  # placement[i] — индекс спецсимвола для i-й позиции
  var placement = newSeq[int](slots)  # инициализируется нулями (→ пустые строки)

  while true:
    yield mapIt(placement, specials[it])

    # Инкрементируем счётчик позиций с последней позиции
    var pos = slots - 1
    while pos >= 0:
      placement[pos] += 1
      if placement[pos] < s:
        break
      placement[pos] = 0
      dec pos

    if pos < 0:
      break  # все позиции переполнились — расстановки исчерпаны


proc assemblePassword(words: seq[string], syms: seq[string]): string =
  ## Собирает итоговый пароль из слов и расставленных между ними спецсимволов.
  ##
  ## Структура: syms[0] + words[0] + syms[1] + words[1] + … + words[N-1] + syms[N]
  ##
  ## Длина syms всегда равна len(words)+1 — это гарантируется вызывающим кодом.
  ## Пример: words=["secret","world","2023"], syms=["#","_","@","!"]
  ##         → "#secret_world@2023!"
  result = syms[0]
  for i in 0 ..< len(words):
    result = result & words[i] & syms[i + 1]


# ==============================================================================
#  ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ==============================================================================

proc formatTime(seconds: float): string =
  ## Форматирует количество секунд в читаемую строку вида «1m 23s» или «4.7s».
  if seconds < 60.0:
    return formatFloat(seconds, ffDecimal, 1) & "s"
  let
    m = int(seconds) div 60
    s = int(seconds) mod 60
  return $m & "m " & $s & "s"


# ==============================================================================
#  ТОЧКА ВХОДА
# ==============================================================================

proc main() =
  # ── 1. Определяем путь к конфигурационному файлу ──────────────────────────
  # Если первый аргумент командной строки оканчивается на «.cfg» — это конфиг;
  # иначе считаем первый аргумент путём к архиву (совместимость с v1.0).
  let cmdArgs = commandLineParams()

  var
    configPath      = DEFAULT_CONFIG_PATH
    archiveOverride = ""  # аргумент командной строки может переопределить archive из конфига

  if len(cmdArgs) > 0:
    if endsWith(cmdArgs[0], ".cfg"):
      configPath = cmdArgs[0]
    else:
      # Передан путь к архиву напрямую — режим совместимости с v1.0
      archiveOverride = cmdArgs[0]

  # ── 2. Загружаем конфиг ───────────────────────────────────────────────────
  if not fileExists(configPath):
    # Конфиг не найден — выводим ошибку на двух языках сразу (ещё не знаем язык)
    echo "Error: config file not found: " & configPath
    echo "Ошибка: файл конфигурации не найден: " & configPath
    quit(1)

  var cfg: Config
  try:
    cfg = parseConfig(configPath)
  except ValueError as e:
    echo "Config parse error: " & e.msg
    quit(1)

  # Аргумент командной строки имеет приоритет над значением в конфиге
  if len(archiveOverride) > 0:
    cfg.archivePath = archiveOverride

  # С этого момента используем только локализованные строки
  let msg = getMsg(cfg.lang)

  # ── 3. Проверяем наличие архива ───────────────────────────────────────────
  if not fileExists(cfg.archivePath):
    echo msg.errArchiveNotFound & cfg.archivePath
    echo msg.errUsage
    quit(1)

  # ── 4. Загружаем wordlist ─────────────────────────────────────────────────
  # Один файл содержит обе секции: [patterns] и [specials].
  if not fileExists(cfg.wordlistPath):
    echo msg.errWordlistNotFound & cfg.wordlistPath
    quit(1)

  let wl = loadWordlist(cfg.wordlistPath)

  if len(wl.patterns) == 0:
    echo msg.errNoPatterns
    quit(1)
  if len(wl.specials) == 0:
    echo msg.errNoSpecials
    quit(1)

  # ── 5. Дополнительная валидация конфига ──────────────────────────────────
  if cfg.maxComboLen < 1:
    echo msg.errBadMaxComboLen
    quit(1)
  if cfg.progressStep < 1:
    echo msg.errBadProgressStep
    quit(1)

  # ── 7. Выводим шапку ──────────────────────────────────────────────────────
  let sevenZip = get7zCmd()

  echo msg.hdrCmd      & sevenZip
  echo msg.hdrArchive  & cfg.archivePath
  echo msg.hdrPatterns & $len(wl.patterns)
  echo msg.hdrSpecials & $len(wl.specials) & " (incl. empty)"
  echo msg.hdrMaxLen   & $cfg.maxComboLen & " patterns"
  echo repeat("=", 55)

  # ── 8. Основной цикл перебора ─────────────────────────────────────────────
  #
  # Структура трёхуровневого перебора:
  #   comboLen  — длина текущей комбинации слов (1 … max_combo_len)
  #     combo   — конкретная последовательность слов этой длины
  #       syms  — конкретная расстановка спецсимволов для этой комбинации
  #
  # Общее число кандидатов для comboLen=N:
  #   P(N) × S^(N+1),  где P(N) = len(wl.patterns)^N, S = len(wl.specials)
  #
  let startTime = epochTime()

  var
    tested = 0     # счётчик проверенных паролей
    found  = false # флаг: пароль найден

  # Метка «search» позволяет выйти из всех вложенных циклов одной командой
  # «break search» при нахождении верного пароля.
  block search:
    for comboLen in 1 .. cfg.maxComboLen:
      echo format(msg.msgComboHeader, $comboLen)

      for combo in combos(wl.patterns, comboLen):
        # slots = число позиций для спецсимволов = число слов + 1
        # (одна позиция перед первым словом, одна после последнего,
        #  и по одной между каждой парой соседних слов)
        let slots = comboLen + 1

        for syms in symPlacements(wl.specials, slots):
          # Сборка: syms[0]+word0+syms[1]+word1+…+word(N-1)+syms[N]
          let password = assemblePassword(combo, syms)
          inc tested

          # Периодически выводим строку прогресса
          if tested mod cfg.progressStep == 0:
            let elapsed = epochTime() - startTime
            echo format(msg.msgProgress, $tested, formatTime(elapsed), password)

          if tryPassword(sevenZip, cfg.archivePath, password):
            let elapsed = epochTime() - startTime
            echo "\n" & repeat("=", 55)
            echo msg.msgFound & password
            echo msg.msgTested & $tested
            echo msg.msgElapsed & formatTime(elapsed)
            echo repeat("=", 55)
            found = true
            break search  # выходим из всех вложенных циклов

  # ── 9. Итоговое сообщение ─────────────────────────────────────────────────
  if not found:
    let elapsed = epochTime() - startTime
    echo "\n" & repeat("=", 55)
    echo msg.msgNotFound & $tested & " combinations"
    echo msg.msgElapsed & formatTime(elapsed)
    echo msg.msgHint
    echo repeat("=", 55)


main()
