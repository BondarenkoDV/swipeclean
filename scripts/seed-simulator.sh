#!/bin/zsh
# Наполняет медиатеку симулятора фото и видео для ручной проверки и UI-тестов
# и выдаёт приложению доступ к фото, контактам и календарю.
#
#   scripts/seed-simulator.sh <UDID> [--erase]
#
# --erase сначала стирает симулятор целиком (simctl erase), чтобы не копить
# повторные наборы: UI-тесты при каждом прогоне удаляют одно фото.
#
# Набор (из картинок и роликов, которые есть в macOS):
#   12 обычных фото (JPEG и HEIC),
#   3 точных дубля (один файл добавлен дважды),
#   2 почти-дубля: пересжатие JPEG с качеством 40 и уменьшение до 80 %,
#   серия из 4 похожих кадров (небольшие кропы одного кадра),
#   серия из 3 кадров с лицом (кропы превью шаблона из Photos) для выбора лучшего кадра по лицам,
#   3 сильно размытых фото, 3 PNG размером со скриншот iPhone (1179×2556),
#   2 коротких видео, одно добавлено дважды.
# В медиатеке симулятора есть ещё несколько стоковых фото Apple.
set -euo pipefail

UDID=${1:?"Использование: $0 <UDID> [--erase]"}
ERASE=${2:-}
# Bundle id из Config/Signing.xcconfig, а если есть Config/Local.xcconfig — из него.
CONFIG=${0:A:h}/../Config
BUNDLE_ID=$(cat "$CONFIG/Signing.xcconfig" "$CONFIG/Local.xcconfig"(N) \
  | awk -F '[[:space:]]*=[[:space:]]*' '/^APP_BUNDLE_ID/ {id = $2} END {print id}')

WORK=$(mktemp -d -t swipeclean-seed)
trap 'rm -rf "$WORK"' EXIT
MEDIA=$WORK/media
mkdir -p "$MEDIA" "$WORK/tmp"

# Фотографии из macOS. Пути зависят от версии системы, поэтому берём те, что есть.
candidates=(
  /System/Library/PrivateFrameworks/Portrait.framework/Versions/A/Resources/backgrounds/image/*.heic(N)
  /System/Library/Wallpapers/.default/DefaultAerial.jpg(N)
  /System/Library/PrivateFrameworks/SystemDesktopAppearance.framework/Versions/A/Resources/DefaultBackground.jpg(N)
  "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic"(N)
  /System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/Tahoe*.heic(N)
  /System/Applications/Chess.app/Contents/Resources/Board{Wood,Marble,Metal}.jpg(N)
)
size() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w, h}'; }

# Нужно 24 разных кадра. Небольшие исходники идут целиком, большие (от 3000 px) — четвертями:
# сначала первые четверти всех больших, потом вторые и так далее, чтобы соседние кадры были разными.
pool=()
large=()
for f in "${candidates[@]}"; do
  [[ -f $f ]] || continue
  read w h <<< "$(size "$f")"
  if (( w >= 3000 || h >= 3000 )); then large+=("$f"); else pool+=("$f|"); fi
done
for q in 1 2 3 4; do
  for f in "${large[@]}"; do pool+=("$f|q$q"); done
done
if (( ${#pool} < 24 )); then
  echo "В системе нашлось только ${#pool} подходящих кадров из 24." >&2
  exit 1
fi
next=1
take() { # следующий кадр из пула -> JPEG $1 с длинной стороной не больше 3024
  local entry=${pool[$next]}
  next=$((next + 1))
  local src=${entry%%|*} part=${entry#*|} w h resize=()
  if [[ -n $part ]]; then
    read w h <<< "$(size "$src")"
    local cw=$((w / 2)) ch=$((h / 2)) q=${part#q}
    sips -c $ch $cw --cropOffset $(( (q - 1) / 2 * ch )) $(( (q - 1) % 2 * cw )) "$src" --out "$WORK/tmp/quarter.${src:e}" >/dev/null
    src=$WORK/tmp/quarter.${src:e}
  fi
  read w h <<< "$(size "$src")"
  (( w > 3024 || h > 3024 )) && resize=(-Z 3024)
  sips $resize -s format jpeg -s formatOptions 90 "$src" --out "$1" >/dev/null
}

# 12 обычных фото, последнее в HEIC.
for i in {01..12}; do take "$MEDIA/photo$i.jpg"; done
sips -s format heic "$MEDIA/photo12.jpg" --out "$MEDIA/photo12.heic" >/dev/null && rm "$MEDIA/photo12.jpg"

# 3 точных дубля: файл добавляется дважды.
for name in dupA dupB dupC; do take "$MEDIA/$name.jpg"; done
sips -s format heic "$MEDIA/dupB.jpg" --out "$MEDIA/dupB.heic" >/dev/null && rm "$MEDIA/dupB.jpg"

# 2 почти-дубля: пересжатие и уменьшение до 80 %.
take "$MEDIA/nearQ_orig.jpg"
sips -s format jpeg -s formatOptions 40 "$MEDIA/nearQ_orig.jpg" --out "$MEDIA/nearQ_q40.jpg" >/dev/null
take "$MEDIA/nearR_orig.jpg"
read w h <<< "$(size "$MEDIA/nearR_orig.jpg")"
sips -z $((h * 4 / 5)) $((w * 4 / 5)) "$MEDIA/nearR_orig.jpg" --out "$MEDIA/nearR_80.jpg" >/dev/null

# Серия из 4 похожих кадров: кропы одного кадра со сдвигом 0–4 %, итог одного размера.
take "$WORK/tmp/seq.jpg"
read w h <<< "$(size "$WORK/tmp/seq.jpg")"
for n in 1 2 3 4; do
  shift_pct=$(( (n - 1) * 15 ))   # десятые доли процента: 0; 1,5; 3; 4,5 %
  cw=$(( w * (1000 - shift_pct) / 1000 )) ch=$(( h * (1000 - shift_pct) / 1000 ))
  sips -c $ch $cw --cropOffset $(( (h - ch) / 2 )) $(( (w - cw) / 3 )) "$WORK/tmp/seq.jpg" --out "$WORK/tmp/seq$n.jpg" >/dev/null
  sips -z $(( h * 3 / 4 )) $(( w * 3 / 4 )) -s formatOptions 88 "$WORK/tmp/seq$n.jpg" --out "$MEDIA/seq$n.jpg" >/dev/null
done

# Серия из 3 кадров с лицом: в macOS нет обычных фото людей, но в превью шаблонов фотокниг и открыток Photos
# есть снимки с крупным лицом. Кропы со сдвигом 0; 2,5; 5 % (чтобы не стать дублями), увеличенные вдвое,
# чтобы лицо было крупнее. Если таких превью в системе нет, серия пропускается.
previews="/System/Library/Templates/Data/Library/Application Support/Apple/Photos/Print Products/Previews"
faces=("$previews"/*.pppreview/Contents/Resources/{ModernLines-Large,PictureCard-Postcard-V,Journal-Large}_*.png(N))
face_files=()
if (( ${#faces} > 0 )); then
  read w h <<< "$(size "${faces[1]}")"
  for n in 1 2 3; do
    shift_pct=$(( (n - 1) * 25 ))   # десятые доли процента: 0; 2,5; 5 %
    cw=$(( w * (1000 - shift_pct) / 1000 )) ch=$(( h * (1000 - shift_pct) / 1000 ))
    sips -c $ch $cw --cropOffset $(( (h - ch) / 2 )) $(( (w - cw) / 2 )) "${faces[1]}" --out "$WORK/tmp/face$n.png" >/dev/null
    sips -z $(( h * 2 )) $(( w * 2 )) -s format jpeg -s formatOptions 90 "$WORK/tmp/face$n.png" --out "$MEDIA/face$n.jpg" >/dev/null
    face_files+=("$MEDIA/face$n.jpg")
  done
else
  echo "Внимание: превью Photos с лицами не нашлись — серии с лицом не будет." >&2
fi

# 3 сильно размытых: уменьшение до 64 px и обратно.
for n in 1 2 3; do
  take "$WORK/tmp/blur$n.jpg"
  read w h <<< "$(size "$WORK/tmp/blur$n.jpg")"
  sips -Z 64 "$WORK/tmp/blur$n.jpg" --out "$WORK/tmp/blur${n}_small.jpg" >/dev/null
  sips -z $h $w "$WORK/tmp/blur${n}_small.jpg" --out "$MEDIA/blur$n.jpg" >/dev/null
done

# 3 PNG размером со скриншот iPhone. Система не помечает их как скриншоты (это делает только
# сама iOS при снимке экрана), поэтому в «Скриншоты» и «Старые скриншоты» они не попадают.
for n in 1 2 3; do
  take "$WORK/tmp/shot$n.jpg"
  read w h <<< "$(size "$WORK/tmp/shot$n.jpg")"
  cw=$(( h * 1179 / 2556 ))
  (( cw > w )) && cw=$w
  sips -c $h $cw "$WORK/tmp/shot$n.jpg" --out "$WORK/tmp/shot${n}_crop.jpg" >/dev/null
  sips -z 2556 1179 -s format png "$WORK/tmp/shot${n}_crop.jpg" --out "$MEDIA/screenshot$n.png" >/dev/null
done

# 2 коротких видео из роликов macOS.
movies=(
  "/System/Library/Desktop Pictures/.wallpapers/Tahoe Day/Tahoe Day.mov"(N)
  "/System/Library/Desktop Pictures/.wallpapers/Sonoma/"*.mov(N)
  /System/Library/CoreServices/ControlCenter.app/Contents/Resources/BentoGalleryIntroduction.mov(N)
)
videos=()
for m in "${movies[@]}"; do
  (( ${#videos} >= 2 )) && break
  [[ -f $m ]] || continue
  n=$(( ${#videos} + 1 ))
  ext=$([[ $n == 1 ]] && echo mov || echo mp4)
  if avconvert -s "$m" -p Preset1280x720 -o "$MEDIA/video$n.$ext" --start 1 --duration $(( n == 1 ? 4 : 3 )) --replace >/dev/null 2>&1; then
    videos+=("$MEDIA/video$n.$ext")
  fi
done
(( ${#videos} < 2 )) && echo "Внимание: видео сделано ${#videos} из 2 — в системе нет подходящих роликов." >&2

if [[ $ERASE == --erase ]]; then
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

cd "$MEDIA"
add() { xcrun simctl addmedia "$UDID" "$@"; }
add photo*.jpg photo12.heic
add dupA.jpg dupB.heic dupC.jpg
add dupA.jpg dupB.heic dupC.jpg
add nearQ_orig.jpg nearQ_q40.jpg nearR_orig.jpg nearR_80.jpg
add seq1.jpg seq2.jpg seq3.jpg seq4.jpg
if (( ${#face_files} > 0 )); then
  add "${face_files[@]}"
fi
add blur1.jpg blur2.jpg blur3.jpg
add screenshot1.png screenshot2.png screenshot3.png
if (( ${#videos} > 0 )); then
  add "${videos[@]}"
  add "${videos[1]}"
fi

xcrun simctl privacy "$UDID" grant photos $BUNDLE_ID
# Контакты и календарь нужны чистке контактов и старых событий. Тестовые записи создаёт само приложение
# при запуске с -seedContacts и -seedCalendar, системные окна доступа в тестах тогда не появляются.
xcrun simctl privacy "$UDID" grant contacts $BUNDLE_ID
xcrun simctl privacy "$UDID" grant calendar $BUNDLE_ID
echo "Добавлено: $(ls "$MEDIA" | grep -vc video) файлов фото (+3 повтора дублей) и ${#videos} видео (+1 повтор). Доступ к фото, контактам и календарю выдан."
