#!/usr/bin/env bats
# bin/checks-normalize: guarded trims, back rotation, idempotent re-runs.
# Exercises the real tool end-to-end (pdftoppm + magick + img2pdf).

setup() {
  for t in pdftoppm magick img2pdf; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not installed"
  done
  TMP=$(mktemp -d)
  CN="$BATS_TEST_DIRNAME/../bin/checks-normalize"
}

teardown() { rm -rf "$TMP"; }

sheet_page() { # <out.png> <sheetW> <sheetH> [draw ops...] — sheet on gray backing
  local out="$1" sw="$2" sh="$3"; shift 3
  magick -size "$((sw + 200))x$((sh + 174))" xc:'gray(60%)' \
    \( -size "${sw}x${sh}" xc:white -fill black "$@" \) \
    -geometry +100+87 -composite "$out"
}

make_pdf() { # <out.pdf> <page.png...>
  local out="$1"; shift
  img2pdf --imgsize 300dpix300dpi "$@" -o "$out"
}

render_page() { # <pdf> <page> <out.png>
  local d="$TMP/render-$2"
  rm -rf "$d"; mkdir -p "$d"
  pdftoppm -png -r 300 -f "$2" -l "$2" "$1" "$d/q"
  mv "$d"/q-*.png "$3"
}

dims() { magick "$1" -format '%w %h' info:; }

region_dark() { # <png> <crop> — region mean is dark (ink present)
  [ "$(magick "$1" -crop "$2" +repage -format '%[fx:mean<0.5?1:0]' info:)" = "1" ]
}

region_white() { # <png> <crop> — region mean is near-white (no ink)
  [ "$(magick "$1" -crop "$2" +repage -format '%[fx:mean>0.95?1:0]' info:)" = "1" ]
}

near() { # <value> <target> <tolerance>
  local v="$1" t="$2" tol="$3"
  (( v >= t - tol && v <= t + tol ))
}

@test "trims backing; portrait back rotated to landscape" {
  sheet_page "$TMP/front.png" 1800 825 -draw 'rectangle 100,100 1700,725'
  sheet_page "$TMP/back.png" 825 1800 -draw 'rectangle 100,100 300,1700'
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 1 "$TMP/p1.png"
  render_page "$TMP/c.pdf" 2 "$TMP/p2.png"
  read -r w h <<<"$(dims "$TMP/p1.png")"
  near "$w" 1800 12 && near "$h" 825 12      # backing gone, sheet kept
  read -r w h <<<"$(dims "$TMP/p2.png")"
  (( w > h ))                                 # back is landscape
  near "$w" 1800 12 && near "$h" 825 12
}

@test "near-blank back keeps full sheet; long strip is not cropped" {
  sheet_page "$TMP/front.png" 1800 825 -draw 'rectangle 100,100 1700,725'
  # Endorsement strip spanning nearly the full sheet width — the case that
  # used to be stood up and beheaded by -extent.
  sheet_page "$TMP/back.png" 1800 825 -draw 'rectangle 50,287 1750,537'
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 2 "$TMP/p2.png"
  read -r w h <<<"$(dims "$TMP/p2.png")"
  near "$w" 1800 12 && near "$h" 825 12      # sheet, not a 250px sliver
  region_dark "$TMP/p2.png" "100x100+60+337"     # left end of the strip intact
  region_dark "$TMP/p2.png" "100x100+1640+337"   # right end intact
  region_white "$TMP/p2.png" "100x100+850+50"    # above the strip still blank
}

@test "blank front keeps sheet size (no 1x1 page, no poisoned reference)" {
  sheet_page "$TMP/front.png" 1800 825
  sheet_page "$TMP/back.png" 1800 825 -draw 'rectangle 50,287 800,537'
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 1 "$TMP/p1.png"
  render_page "$TMP/c.pdf" 2 "$TMP/p2.png"
  read -r w h <<<"$(dims "$TMP/p1.png")"
  near "$w" 1800 12 && near "$h" 825 12      # blank page stays sheet-sized
  read -r w h <<<"$(dims "$TMP/p2.png")"
  near "$w" 1800 12 && near "$h" 825 12      # back untouched by blank front
}

@test "geometrically idempotent: re-run neither crops, rotates, nor flips" {
  sheet_page "$TMP/front.png" 1800 825 -draw 'rectangle 100,100 1700,725'
  sheet_page "$TMP/back.png" 1800 825 -draw 'rectangle 50,287 800,537'
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 2 "$TMP/r1.png"
  read -r w1 h1 <<<"$(dims "$TMP/r1.png")"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 2 "$TMP/r2.png"
  read -r w2 h2 <<<"$(dims "$TMP/r2.png")"
  near "$w2" "$w1" 8 && near "$h2" "$h1" 8   # no collapse, no rotation
  region_dark "$TMP/r2.png" "400x200+100+337"    # strip still on the LEFT
  region_white "$TMP/r2.png" "400x200+1300+337"  # right half still blank
}

@test "light backing is still trimmed (single-corner test used to miss it)" {
  # Backing at gray(86%) — light exposure renders real backing this light;
  # the old 4-corner <0.85 test skipped these pages and left them untrimmed.
  magick -size 2700x2700 xc:'gray(86%)' \
    \( -size 1800x825 xc:white -fill black -draw 'rectangle 100,100 1700,725' \) \
    -geometry +450+937 -composite "$TMP/front.png"
  magick -size 2700x2700 xc:'gray(86%)' \
    \( -size 1800x825 xc:white -fill black -draw 'rectangle 50,287 1750,537' \) \
    -geometry +450+937 -composite "$TMP/back.png"
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 1 "$TMP/p1.png"
  read -r w h <<<"$(dims "$TMP/p1.png")"
  near "$w" 1800 12 && near "$h" 825 12
  render_page "$TMP/c.pdf" 2 "$TMP/p2.png"
  read -r w h <<<"$(dims "$TMP/p2.png")"
  near "$w" 1800 12 && near "$h" 825 12
}

@test "washed-out sheet blending into backing at 12% fuzz: recovered, stable on re-run" {
  # Sheet only 11% lighter than the backing: the 12% fuzz trim sees through
  # the sheet and finds just the ink — the lower-fuzz retry must find the
  # sheet, and a re-run must not erode or inflate the result.
  magick -size 2700x2700 xc:'gray(89%)' \
    \( -size 1800x825 xc:white -fill black -draw 'rectangle 100,300 1700,500' \) \
    -geometry +450+937 -composite "$TMP/front.png"
  magick -size 2700x2700 xc:'gray(89%)' \
    \( -size 1800x825 xc:white -fill black -draw 'rectangle 100,300 1700,500' \) \
    -geometry +450+937 -composite "$TMP/back.png"
  make_pdf "$TMP/c.pdf" "$TMP/front.png" "$TMP/back.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 1 "$TMP/p1.png"
  read -r w1 h1 <<<"$(dims "$TMP/p1.png")"
  near "$w1" 1800 12 && near "$h1" 825 12   # the sheet, not the 200px ink strip
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  render_page "$TMP/c.pdf" 1 "$TMP/p2.png"
  read -r w2 h2 <<<"$(dims "$TMP/p2.png")"
  near "$w2" "$w1" 8 && near "$h2" "$h1" 8
}

@test "odd page count: warns about pairing, still exits 0" {
  sheet_page "$TMP/p1.png" 1800 825 -draw 'rectangle 100,100 1700,725'
  sheet_page "$TMP/p2.png" 1800 825 -draw 'rectangle 50,287 800,537'
  sheet_page "$TMP/p3.png" 1800 825 -draw 'rectangle 100,100 1700,725'
  make_pdf "$TMP/c.pdf" "$TMP/p1.png" "$TMP/p2.png" "$TMP/p3.png"
  run "$CN" "$TMP/c.pdf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"odd page count"* ]]
}

@test "usage and missing-file exit codes" {
  run "$CN"
  [ "$status" -eq 64 ]
  run "$CN" "$TMP/does-not-exist.pdf"
  [ "$status" -eq 66 ]
}
