#!/bin/zsh
# Собирает неподписанный SwipeClean.ipa для установки через Sideloadly или AltStore:
# они сами подписывают его Apple ID того, кто устанавливает.
#
#   scripts/build-ipa.sh
#
# Результат: build/ipa/SwipeClean.ipa. Подпись и команда разработчика не нужны.
set -euo pipefail

cd "${0:A:h}/.."
ROOT=$PWD
OUT=build/ipa
ARCHIVE=$OUT/SwipeClean.xcarchive
# Идентификатор по умолчанию, а не из Config/Local.xcconfig: файл уходит на чужие телефоны.
BUNDLE_ID=$(awk -F '[[:space:]]*=[[:space:]]*' '/^APP_BUNDLE_ID/ {print $2; exit}' Config/Signing.xcconfig)

xcodegen generate
mkdir -p "$OUT"
xcodebuild archive \
  -project SwipeClean.xcodeproj -scheme SwipeClean -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  APP_BUNDLE_ID="$BUNDLE_ID"

# .ipa — это zip с папкой Payload/<имя>.app внутри.
STAGE=$(mktemp -d -t swipeclean-ipa)
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Payload"
ditto "$ARCHIVE/Products/Applications/SwipeClean.app" "$STAGE/Payload/SwipeClean.app"
rm -f "$OUT/SwipeClean.ipa"
(cd "$STAGE" && ditto -c -k --keepParent --norsrc Payload "$ROOT/$OUT/SwipeClean.ipa")

echo "Готово: $OUT/SwipeClean.ipa ($(du -h "$OUT/SwipeClean.ipa" | cut -f1))"
