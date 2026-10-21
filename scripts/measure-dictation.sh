#!/bin/bash
# Baseline measurements for AA-206 (long dictations finish as fast as short
# ones) and AA-208 (dictionary words recognised). Run on the Mac with
# FluidWispr open and dictation working:
#
#   bash scripts/measure-dictation.sh            # both parts
#   bash scripts/measure-dictation.sh timing     # AA-206 only
#   bash scripts/measure-dictation.sh words      # AA-208 only
#
# Part 1 reads key-up-to-text times from FluidWispr's own log
# (~/Library/Logs/Fluid/Fluid.log, DICTATION_SUMMARY lines). Part 2 asks you
# to dictate sentences into this terminal and counts how many of your words
# came out spelled right. Nothing is recorded or sent anywhere; the results
# are printed and saved to the Desktop.
#
# ROUNDS=5 bash scripts/measure-dictation.sh   # more rounds per length (default 3)

set -euo pipefail

LOG="$HOME/Library/Logs/Fluid/Fluid.log"
ROUNDS="${ROUNDS:-3}"
MODE="${1:-all}"
OUT="$HOME/Desktop/fluidwispr-measure-$(date +%Y%m%d-%H%M).txt"
REPORT=""

SHORT_TEXT="Can you send me the notes from this morning's call before lunch?"
LONG_TEXT="I wanted to give you a quick update on the project. We finished the first round of testing yesterday, and most of it went well. The microphone now recovers on its own when you plug in headphones, and the cleanup step is faster than it was last week. There are still two things I'm not happy with. First, long dictations take noticeably longer to appear than short ones, which feels slow when you've been talking for a while. Second, names and technical words still come out wrong more often than I'd like. I'm going to measure both today so we have real numbers to compare against after the next round of changes. If anything looks off on your side, let me know and I'll add it to the list."

note() { REPORT="${REPORT}$1"$'\n'; echo "$1"; }

median() {
    sort -n | awk '{ v[NR] = $1 } END { if (NR == 0) { print "n/a"; exit } if (NR % 2) print v[(NR + 1) / 2]; else print int((v[NR / 2] + v[NR / 2 + 1]) / 2) }'
}

log_lines() {
    if [ -f "$LOG" ]; then wc -l < "$LOG" | tr -d ' '; else echo 0; fi
}

# Waits up to 90 s for a DICTATION_SUMMARY line written after line $1.
wait_for_summary() {
    local start="$1" waited=0 now line
    while [ "$waited" -lt 90 ]; do
        now="$(log_lines)"
        # The log rotated to Fluid.log.1; read the new file from the top.
        if [ "$now" -lt "$start" ]; then start=0; fi
        line="$(tail -n "+$((start + 1))" "$LOG" 2>/dev/null | grep 'DICTATION_SUMMARY' | tail -n 1 || true)"
        if [ -n "$line" ]; then
            echo "$line"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

field() {
    echo "$1" | grep -o "$2=-\{0,1\}[0-9]*" | head -n 1 | cut -d= -f2
}

countdown() {
    local seconds="$1"
    while [ "$seconds" -gt 0 ]; do
        printf '\r  keep talking... %2ds ' "$seconds"
        sleep 1
        seconds=$((seconds - 1))
    done
    printf '\r  RELEASE THE HOTKEY NOW.            \n'
}

run_timing() {
    if [ ! -f "$LOG" ]; then
        echo "Can't find $LOG. Open FluidWispr and do one dictation first, then run this again."
        exit 1
    fi
    note "== AA-206: key-up to text, short vs long dictation =="
    note "Rounds per length: $ROUNDS"
    echo
    echo "Dictate into this terminal window. When the script says GO, hold your"
    echo "dictation hotkey and read the text aloud. Release when it says RELEASE;"
    echo "the script waits for the text to land."

    local length seconds text i start line asr ready outcome
    local short_ready="" short_asr="" long_ready="" long_asr=""
    for length in short long; do
        if [ "$length" = short ]; then seconds=5; text="$SHORT_TEXT"; else seconds=60; text="$LONG_TEXT"; fi
        i=1
        while [ "$i" -le "$ROUNDS" ]; do
            echo
            echo "--- $length dictation, round $i of $ROUNDS (about ${seconds} s) ---"
            echo "Read this aloud, repeating it if you finish early:"
            echo
            echo "$text" | fold -s -w 78 | sed 's/^/    /'
            echo
            read -r -p "Press Enter when ready... " _
            start="$(log_lines)"
            echo "  GO: hold the hotkey and start talking."
            countdown "$seconds"
            if ! line="$(wait_for_summary "$start")"; then
                note "  $length round $i: no timing line in the log within 90 s, skipped."
                i=$((i + 1))
                continue
            fi
            # The dictated text lands on the prompt line; Enter clears it.
            read -r -p "  Text landed. Press Enter to continue: " _
            asr="$(field "$line" asrMs)"
            ready="$(field "$line" readyMs)"
            outcome="$(echo "$line" | grep -o 'outcome=[^ ]*' | cut -d= -f2)"
            note "  $length round $i: key-up to text ${ready} ms (speech model ${asr} ms, outcome ${outcome})"
            if [ "$length" = short ]; then
                short_ready="$short_ready$ready"$'\n'; short_asr="$short_asr$asr"$'\n'
            else
                long_ready="$long_ready$ready"$'\n'; long_asr="$long_asr$asr"$'\n'
            fi
            i=$((i + 1))
        done
    done

    local sr la sa lr
    sr="$(printf '%s' "$short_ready" | grep -v '^$' | median)"
    lr="$(printf '%s' "$long_ready" | grep -v '^$' | median)"
    sa="$(printf '%s' "$short_asr" | grep -v '^$' | median)"
    la="$(printf '%s' "$long_asr" | grep -v '^$' | median)"
    note ""
    note "Median key-up to text: 5 s dictation ${sr} ms, 60 s dictation ${lr} ms"
    note "Median speech model time: 5 s dictation ${sa} ms, 60 s dictation ${la} ms"
    if [ "$sr" != "n/a" ] && [ "$lr" != "n/a" ]; then
        note "Gap (60 s minus 5 s): $((lr - sr)) ms. AA-206 target: 100 ms or less."
    fi
    note ""
}

run_words() {
    note "== AA-208: dictionary words =="
    echo
    echo "Type the names and jargon FluidWispr gets wrong, separated by commas."
    echo "Use the spelling you want to see, for example: Alec, Cerebras, FluidWispr, Parakeet"
    local raw
    read -r -p "> " raw
    local words=()
    local IFS_SAVE="$IFS"
    IFS=','
    for w in $raw; do
        w="$(echo "$w" | sed 's/^ *//; s/ *$//')"
        [ -n "$w" ] && words+=("$w")
    done
    IFS="$IFS_SAVE"
    if [ "${#words[@]}" -eq 0 ]; then
        echo "No words given; skipping this part."
        return
    fi

    echo
    echo "For each word, dictate the sentence shown INTO THIS TERMINAL (click here, hold"
    echo "the hotkey, speak, release). The text lands on the prompt line; press Enter."
    local hits=0 total=0 w heard
    for w in "${words[@]}"; do
        echo
        echo "Say: \"Please forward this to $w before the end of the day.\""
        read -r -p "> " heard
        total=$((total + 1))
        if echo "$heard" | grep -qiF -- "$w"; then
            hits=$((hits + 1))
            note "  hit:  $w"
        else
            note "  miss: $w (heard: $heard)"
        fi
    done
    note ""
    note "Dictionary words spelled right: $hits of $total"
    note "Words: $(IFS=', '; echo "${words[*]}")"
    note ""
}

echo "FluidWispr dictation measurements, $(date '+%Y-%m-%d %H:%M')"
case "$MODE" in
    timing) run_timing ;;
    words) run_words ;;
    all) run_timing; run_words ;;
    *) echo "Usage: bash scripts/measure-dictation.sh [timing|words|all]"; exit 2 ;;
esac

{
    echo "FluidWispr dictation measurements, $(date '+%Y-%m-%d %H:%M')"
    echo "macOS $(sw_vers -productVersion 2>/dev/null || echo unknown), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
    echo
    printf '%s' "$REPORT"
} > "$OUT"
echo
echo "Saved to $OUT. Paste its contents into the thread."
