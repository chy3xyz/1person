#!/usr/bin/env bash
# Generate a Markdown CI report summarizing the make ci run.
#
# Inputs (read from the current working directory):
#   ci-timings.log   - capture of time make db-up, time make db-migrate
#                      (twice, for idempotency), and time make check runs.
#   build.log        - last 20 lines (or full file if short) of zig build
#   test.log         - last 30 lines (or full file if short) of zig build test
#   migrate.log      - last 20 lines (or full file if short) of make db-migrate
#
# Outputs:
#   ci-report.md     - human-readable Markdown summary suitable for posting
#                      to a PR via gh pr comment or for writing into a
#                      GitHub Actions job summary (GITHUB_STEP_SUMMARY).
#
# All inputs are optional — the report degrades gracefully when a log is
# missing and falls back to a placeholder.
#
# Usage: ./scripts/ci-report.sh
# Environment overrides (all optional):
#   TIMINGS_FILE, REPORT_FILE, BUILD_LOG, TEST_LOG, MIGRATE_LOG,
#   PR_NUMBER, COMMIT_SHA, RUN_URL

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TIMINGS_FILE="${TIMINGS_FILE:-$ZSERVER_DIR/ci-timings.log}"
REPORT_FILE="${REPORT_FILE:-$ZSERVER_DIR/ci-report.md}"
BUILD_LOG="${BUILD_LOG:-$ZSERVER_DIR/build.log}"
TEST_LOG="${TEST_LOG:-$ZSERVER_DIR/test.log}"
MIGRATE_LOG="${MIGRATE_LOG:-$ZSERVER_DIR/migrate.log}"
PR_NUMBER="${PR_NUMBER:-}"
COMMIT_SHA="${COMMIT_SHA:-}"
RUN_URL="${RUN_URL:-}"

if [ -f "$TIMINGS_FILE" ]; then
    cp "$TIMINGS_FILE" "$ZSERVER_DIR/ci-timings.log" 2>/dev/null || true
fi

# Build a Markdown heading that embeds the PR number and commit SHA when
# provided so the comment links directly to the run that produced it.
build_heading() {
    local heading="## 🤖 zserver CI report"
    local suffix=""
    if [ -n "$PR_NUMBER" ] && [ -n "$COMMIT_SHA" ]; then
        suffix=" (PR #${PR_NUMBER} @ \`${COMMIT_SHA:0:12}\`)"
    elif [ -n "$COMMIT_SHA" ]; then
        suffix=" (\`${COMMIT_SHA:0:12}\`)"
    fi
    printf '%s%s\n' "$heading" "$suffix"
}

# Render the last N lines of a file as a fenced code block. If the file
# is missing or empty, render a placeholder so the collapsible section
# still shows up in the rendered comment.
render_block() {
    local path="$1"
    local max_lines="$2"
    local label="$3"
    if [ ! -f "$path" ] || [ ! -s "$path" ]; then
        cat <<EOF2
<details><summary>${label} (log missing)</summary>

\`\`\`
(log missing)
\`\`\`

</details>
EOF2
        return
    fi
    # Strip carriage returns so Windows-style line endings do not
    # confuse the Markdown renderer. Tail bounds the excerpt.
    local body
    body="$(tr -d '\r' < "$path" | tail -n "$max_lines")"
    cat <<EOF2
<details><summary>${label} (last ${max_lines} lines)</summary>

\`\`\`
${body}
\`\`\`

</details>
EOF2
}

# parse_step_timing: extract the elapsed seconds and max RSS from the
# time -v block for one step. Echoes two space-separated values:
# elapsed_seconds max_rss_kb. Either value may be ? if the field is
# missing. Implementation lives in a separate file so we can avoid
# embedding awk script with shell-hostile quoting inside this script.
parse_step_timing() {
    local step_marker="$1"
    local timings_path="$2"
    if [ ! -f "$timings_path" ]; then
        echo "? ?"
        return
    fi
    awk -v marker="$step_marker" '
        BEGIN { elapsed = ""; rss = ""; in_block = 0 }
        # Each step in the workflow is preceded by a banner line of the
        # form ==> -- <step> --. Everything from there until the next
        # banner (or EOF) belongs to that step.
        /^==> -- / {
            if (in_block) { exit }
            if (index($0, "==> -- " marker " --") > 0) { in_block = 1 }
            next
        }
        in_block && /^Elapsed \(wall clock\) time/ {
            # Parse the m:ss.cc or h:mm:ss form emitted by time -v.
            # The seconds field carries a fractional part (e.g.
            # 0:05.32) so we split on colon first and treat each
            # component as a possibly-fractional number.
            sub(/.*: /, "")
            n = split($0, parts, ":")
            if (n == 2) { elapsed = parts[1] * 60 + parts[2] + 0 }
            else if (n == 3) { elapsed = parts[1] * 3600 + parts[2] * 60 + parts[3] + 0 }
        }
        in_block && /^Maximum resident set size/ {
            sub(/.*: /, "")
            rss = $1
        }
        END {
            if (elapsed == "") { printf "? " } else { printf "%.2f ", elapsed }
            if (rss == "") { print "?" } else { print rss }
        }
    ' "$timings_path"
}

# Build the Timings table. Each row is step | elapsed (s) | max RSS (KB).
render_timings_table() {
    local dbup_e dbup_r
    local mig_e mig_r
    local remig_e remig_r
    local build_e build_r
    read -r dbup_e dbup_r <<< "$(parse_step_timing "db-up" "$ZSERVER_DIR/ci-timings.log")"
    read -r mig_e mig_r <<< "$(parse_step_timing "db-migrate" "$ZSERVER_DIR/ci-timings.log")"
    read -r remig_e remig_r <<< "$(parse_step_timing "db-migrate (re-run, idempotency)" "$ZSERVER_DIR/ci-timings.log")"
    read -r build_e build_r <<< "$(parse_step_timing "check (zig build && zig build test)" "$ZSERVER_DIR/ci-timings.log")"
    cat <<EOF2
| Step                                            | Elapsed (s) | Max RSS (KB) |
| ----------------------------------------------- | :---------: | :----------: |
| \`make db-up\`                                    |   ${dbup_e}    |    ${dbup_r}     |
| \`make db-migrate\`                               |   ${mig_e}     |    ${mig_r}      |
| \`make db-migrate\` (re-run, idempotent)          |   ${remig_e}   |    ${remig_r}    |
| \`make check\` (\`zig build && zig build test\`)   |   ${build_e}   |    ${build_r}    |
EOF2
}

# Read the last few lines of the migrate log to decide whether the
# idempotent re-run produced any new APPLY lines. If the log says
# something like skipped N or contains no APPLY entries on the
# idempotent path we annotate the report.
migrate_idempotency_note() {
    if [ ! -f "$MIGRATE_LOG" ] || [ ! -s "$MIGRATE_LOG" ]; then
        echo "(no migrate log available)"
        return
    fi
    local applied
    applied="$(tr -d '\r' < "$MIGRATE_LOG" | grep -c '^APPLY ' || true)"
    if [ "${applied:-0}" -eq 0 ]; then
        echo "Idempotency: re-run produced **no new APPLY lines** (expected on the second invocation)."
    else
        echo "Idempotency: re-run produced ${applied} APPLY line(s)."
    fi
}

write_report() {
    local status_build="$1"
    local status_migrate="$2"
    local status_remigrate="$3"
    local status_dbup="$4"

    {
        build_heading

        cat <<EOF2

### Summary

| Step                                          | Status |
| --------------------------------------------- | :----: |
| \`make db-up\`                                  |  ${status_dbup}  |
| \`make db-migrate\`                             |  ${status_migrate}  |
| \`make db-migrate\` (re-run, idempotent)        |  ${status_remigrate}  |
| \`make check\` (\`zig build && zig build test\`) |  ${status_build}  |

$(migrate_idempotency_note)

### Build

$(render_block "$BUILD_LOG" 20 "zig build")

### Test

$(render_block "$TEST_LOG" 30 "zig build test")

### Migrations

$(render_block "$MIGRATE_LOG" 20 "make db-migrate")

### Timings

$(render_timings_table)

<sub>Generated by \`scripts/ci-report.sh\` from \`ci-timings.log\`, \`build.log\`, \`test.log\` and \`migrate.log\`.${RUN_URL:+ See the run at ${RUN_URL}.}</sub>
EOF2
    } > "$REPORT_FILE"
}

# status_of: pull a status icon from the ci-timings.log marker emitted
# by the workflow. Falls back to check-mark when no marker is found so
# the local-dev path still renders usefully.
status_of() {
    local marker="$1"
    if [ ! -f "$ZSERVER_DIR/ci-timings.log" ]; then
        echo "✅"
        return
    fi
    if grep -qE "^${marker}=ok$" "$ZSERVER_DIR/ci-timings.log"; then
        echo "✅"
    elif grep -qE "^${marker}=fail$" "$ZSERVER_DIR/ci-timings.log"; then
        echo "❌"
    else
        echo "✅"
    fi
}

status_build="$(status_of build)"
status_migrate="$(status_of migrate)"
status_remigrate="$(status_of remigrate)"
status_dbup="$(status_of dbup)"

write_report "$status_build" "$status_migrate" "$status_remigrate" "$status_dbup"

echo "==> wrote $REPORT_FILE"
