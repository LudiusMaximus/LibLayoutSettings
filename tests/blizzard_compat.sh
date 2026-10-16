#!/usr/bin/env bash
# Checks the parts of Blizzard's edit mode the library depends on, across clients
# or across a patch, in a checkout of https://github.com/Gethe/wow-ui-source.
#
# Usage: blizzard_compat.sh <wow-ui-source> [base] [ref ...]
#
#   blizzard_compat.sh ../wow-ui-source
#       every classic client and WoW Forever, compared with retail
#
#   blizzard_compat.sh ../wow-ui-source origin/live~1 origin/live
#       what the latest retail build changed, after a patch
#
# What the library uses is read out of LibLayoutSettings.lua itself, so a hook or
# template added there is covered without touching this file:
#
#   - every hooked or called EditModeManagerFrame method must exist,
#   - every template, mixin, font object and edit mode event it names must
#     exist, and every child or field of the manager it reaches for, a button
#     say, and every edit mode dialog with the children it reaches for. A name it
#     only uses after looking it up in _G is one it can do without, and is left
#     out,
#   - and the bodies of those methods, plus the few whose order the library relies
#     on without hooking them, are compared with the base. A difference is not
#     necessarily a break, so it is reported for a person to read.
#
# The stubbed manager in session_test.lua copies these bodies' call order. When
# one of them changes, that stub may need to change with it.
#
# Exits 1 if anything the library needs is missing, 0 otherwise.

set -uo pipefail

repo=${1:?usage: blizzard_compat.sh <wow-ui-source> [base] [ref ...]}
base=${2:-origin/live}
shift $(( $# < 2 ? $# : 2 ))
refs=("$@")
[ ${#refs[@]} -gt 0 ] || refs=(origin/forever origin/classic origin/classic_anniversary origin/classic_era)

lib="$(dirname "${BASH_SOURCE[0]}")/../LibLayoutSettings.lua"
manager=Interface/AddOns/Blizzard_EditMode/Shared/EditModeManager.lua

src=$(tr -d '\r' < "$lib")
methods=$( { printf '%s\n' "$src" | grep -oE 'hooksecurefunc\(EditModeManagerFrame, *"[A-Za-z]+"' | grep -oE '"[A-Za-z]+"' | tr -d '"'
             printf '%s\n' "$src" | grep -oE 'EditModeManagerFrame:[A-Za-z]+\(' | sed -E 's/.*:([A-Za-z]+)\(/\1/'; } | sort -u)
templates=$(printf '%s\n' "$src" | grep -oE '"[A-Za-z]+(Template|ScrollBar)"' | tr -d '"' | sort -u)
mixins=$(printf '%s\n' "$src" | grep -oE '\b(EditMode[A-Za-z]*Mixin|MinimalSlider[A-Za-z]*Mixin|DropdownButtonMixin|CreateMinimalSliderFormatter|ScrollUtil)\b' | sort -u)
events=$(printf '%s\n' "$src" | grep -oE 'RegisterCallback\("EditMode\.[A-Za-z]+"' | grep -oE 'EditMode\.[A-Za-z]+' | sort -u)
# Names the library looks up in _G before using them, which it can do without.
optional=$(printf '%s\n' "$src" | grep -oE '_G\.[A-Za-z0-9_]+' | sed 's/^_G\.//' | sort -u)
fonts=$(printf '%s\n' "$src" | grep -oE '"(GameFont|ChatFont|SystemFont)[A-Za-z0-9_]+"' | tr -d '"' | sort -u \
        | grep -vxF -f <(printf '%s\n' $optional))
# Fields read off the manager that are not its methods: child frames.
children=$(printf '%s\n' "$src" | grep -oE 'EditModeManagerFrame\.[A-Z][A-Za-z]+' | sed 's/.*\.//' | sort -u \
           | grep -vxF -f <(printf '%s\n' $methods))
# And its plain fields, which the manager sets on itself.
fields=$(printf '%s\n' "$src" | grep -oE 'EditModeManagerFrame\.[a-z][A-Za-z]+' | sed 's/.*\.//' | sort -u)
# Edit mode's named dialogs, and the children of the unsaved changes dialog, which
# the library reaches through a local called unsaved.
dialogs=$(printf '%s\n' "$src" | grep -oE '\bEditMode[A-Za-z]*Dialog\b' | sort -u)
unsavedChildren=$(printf '%s\n' "$src" | grep -oE '\bunsaved\.[A-Z][A-Za-z]+' | sed 's/.*\.//' | sort -u)
# Fields read off Blizzard's settings dialog, through a local called blizzardDialog.
# Missing one reads as nil, so its loss would go unnoticed in the game.
dialogFields=$(printf '%s\n' "$src" | grep -oE '\bblizzardDialog\.[a-z][A-Za-z]+' | sed 's/.*\.//' | sort -u)

# Not hooked, but the library relies on what they do and in which order: saving
# fires EditMode.SavedLayouts, entering and leaving fire Enter and Exit, and
# switching layouts clears the selection. OnLoad, because it hands the Revert All
# Changes button a closure over RevertAllChanges, which is why the library hooks
# the button as well as the method. SaveLayoutChanges, because on a preset it asks
# for a new layout whatever changed, which is why Save gets covered there.
relied_on="SaveLayouts SaveLayoutChanges SelectLayout EnterEditMode ExitEditMode OnLoad"
compared=$(printf '%s\n' $methods $relied_on | sort -u)

body() {   # ref, method: the method's body with whitespace collapsed
  git -C "$repo" show "$1:$manager" 2>/dev/null \
    | awk -v start="function EditModeManagerFrameMixin:$2(" 'index($0, start) == 1 { on = 1 } on { print } on && /^end/ { exit }' \
    | tr -s ' \t\r\n' ' '
}

status=0
echo "LibLayoutSettings uses $(echo $methods | wc -w) manager methods, $(echo $templates | wc -w) templates," \
     "$(echo $mixins | wc -w) mixins and helpers, $(echo $fonts | wc -w) font objects, $(echo $events | wc -w) events," \
     "$(echo $children | wc -w) of the manager's children and $(echo $fields | wc -w) of its fields," \
     "$(echo $dialogs | wc -w) dialogs, $(echo $unsavedChildren | wc -w) children of the unsaved changes dialog" \
     "and $(echo $dialogFields | wc -w) field of the settings dialog."
echo "Base: $base  ($(git -C "$repo" log -1 --format=%s "$base" 2>/dev/null))"
echo

for ref in "${refs[@]}"; do
  if ! git -C "$repo" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
    echo "=== $ref: no such ref"; status=1; continue
  fi
  echo "=== $ref  ($(git -C "$repo" log -1 --format=%s "$ref"))"

  missing=()
  for m in $methods; do
    git -C "$repo" grep -q "function EditModeManagerFrameMixin:$m(" "$ref" -- 'Interface/*.lua' || missing+=("$m()")
  done
  for t in $templates; do
    git -C "$repo" grep -q "name=\"$t\"" "$ref" -- 'Interface/*.xml' || missing+=("$t")
  done
  for x in $mixins; do
    git -C "$repo" grep -qw "$x" "$ref" -- 'Interface/*.lua' || missing+=("$x")
  done
  for f in $fonts; do
    git -C "$repo" grep -qE "name=\"$f\"|CreateFont\(\"$f\"" "$ref" -- 'Interface/*.xml' 'Interface/*.lua' || missing+=("$f")
  done
  for e in $events; do
    git -C "$repo" grep -qF "\"$e\"" "$ref" -- 'Interface/*.lua' || missing+=("$e")
  done
  for c in $children $unsavedChildren; do
    git -C "$repo" grep -qF "parentKey=\"$c\"" "$ref" -- 'Interface/AddOns/Blizzard_EditMode/*.xml' || missing+=("$c")
  done
  for f in $fields $dialogFields; do
    git -C "$repo" grep -qE "self\.$f = " "$ref" -- 'Interface/AddOns/Blizzard_EditMode/*.lua' || missing+=("$f")
  done
  for d in $dialogs; do
    git -C "$repo" grep -qF "name=\"$d\"" "$ref" -- 'Interface/AddOns/Blizzard_EditMode/*.xml' || missing+=("$d")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    echo "   everything the library uses is there"
  else
    echo "   MISSING: ${missing[*]}"
    status=1
  fi

  differs=()
  for m in $compared; do
    [ "$(body "$base" "$m")" = "$(body "$ref" "$m")" ] || differs+=("$m")
  done
  if [ ${#differs[@]} -eq 0 ]; then
    echo "   all $(echo $compared | wc -w) method bodies identical to the base"
  else
    echo "   differs from the base, read before trusting: ${differs[*]}"
    echo "      git -C $repo diff -w $base $ref -- $manager"
  fi
  echo
done

exit $status
