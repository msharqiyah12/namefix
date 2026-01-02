#!/bin/bash
# namefix by pinkorca - Cross-platform filename sanitizer
# https://github.com/pinkorca/namefix
set -euo pipefail

readonly VERSION="1.0.0"
readonly BACKUP_DIR=".namefix_backup"
readonly BACKUP_LOG=".namefix_undo.log"
readonly MAX_FILENAME_BYTES=255

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Globals
declare -i TOTAL_FILES=0
declare -i CHECKED_FILES=0
declare -i PROBLEM_FILES=0
declare -i FIXED_FILES=0
declare -i SKIPPED_FILES=0
declare -i ERRORS=0

MODE="check"
DRY_RUN=false
INTERACTIVE=false
JSON_OUTPUT=false
VERBOSE=false
QUIET=false
RECURSIVE=false
TARGET_DIR="."
SANITIZE_STRATEGY="underscore"

trap 'echo -e "\n${RED}Interrupted${NC}"; exit 130' INT TERM

# shellcheck disable=SC2329
cleanup() {
    [[ -f "/tmp/namefix_$$" ]] && rm -f "/tmp/namefix_$$" || true
}

trap 'cleanup' EXIT

usage() {
    cat <<'EOF'
namefix - Cross-platform filename validator and sanitizer

USAGE:
    namefix [OPTIONS] [DIRECTORY]

OPTIONS:
    -c, --check         Check mode (default): detect problems only
    -f, --fix           Fix mode: sanitize problematic filenames
    -u, --undo          Undo mode: restore original filenames from backup
    -d, --dry-run       Preview changes without applying
    -i, --interactive   Prompt before each rename
    -b, --batch         Apply fixes without prompts
    -r, --recursive     Process directories recursively
    -j, --json          Output in JSON format
    -v, --verbose       Show detailed output
    -q, --quiet         Suppress non-essential output
    -s, --strategy STR  Sanitization strategy: underscore|remove|hyphen (default: underscore)
    -h, --help          Show this help
    --version           Show version

EXAMPLES:
    namefix .                    Check current directory
    namefix -f -d ~/Downloads    Dry-run fix on Downloads
    namefix -f -i /path          Interactive fix mode
    namefix -f -b -r /path       Batch fix recursively
    namefix -u .                 Undo previous renames
    namefix -c -j .              Check with JSON output
EOF
}

msg() {
    $QUIET && return 0
    echo -e "$1"
}

msg_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

msg_warn() {
    $QUIET && return 0
    echo -e "${YELLOW}WARN: $1${NC}"
}

msg_success() {
    $QUIET && return 0
    echo -e "${GREEN}$1${NC}"
}

msg_verbose() {
    $VERBOSE && ! $QUIET && echo -e "${CYAN}$1${NC}"
    return 0
}

progress_bar() {
    $QUIET && return 0
    $JSON_OUTPUT && return 0
    local current=$1 total=$2
    local width=40
    local percent=0 filled=0 empty=$width
    if ((total > 0)); then
        percent=$((current * 100 / total))
        filled=$((current * width / total))
        empty=$((width - filled))
    fi
    local bar_filled="" bar_empty=""
    local i
    for ((i = 0; i < filled; i++)); do bar_filled+="#"; done
    for ((i = 0; i < empty; i++)); do bar_empty+="."; done
    printf "\r${BLUE}Progress: [%s%s] %d/%d (%d%%)${NC}" \
        "$bar_filled" "$bar_empty" "$current" "$total" "$percent"
    return 0
}

json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    printf '%s' "$str"
}

is_reserved_name() {
    local name="${1%%.*}"
    name="${name^^}"
    case "$name" in
        CON | PRN | AUX | NUL) return 0 ;;
        COM[1-9] | LPT[1-9]) return 0 ;;
    esac
    return 1
}

has_forbidden_chars() {
    local name="$1"
    [[ "$name" =~ [:\<\>\"\|\?\*\\\/] ]] && return 0
    return 1
}

has_control_chars() {
    local name="$1"
    local i hex char
    for ((i = 0; i < ${#name}; i++)); do
        char="${name:$i:1}"
        hex=$(printf '%d' "'$char" 2>/dev/null || echo "32")
        if [[ "$hex" =~ ^[0-9]+$ ]] && { ((hex >= 0 && hex <= 31)) || ((hex == 127)); }; then
            return 0
        fi
    done
    return 1
}

has_trailing_dot_space() {
    local name="$1"
    [[ "$name" =~ [.\ ]$ ]] && return 0
    return 1
}

has_leading_dot_space() {
    local name="$1"
    [[ "$name" =~ ^[\ ] ]] && return 0
    return 1
}

exceeds_length() {
    local name="$1"
    local bytes
    bytes=$(printf '%s' "$name" | wc -c)
    ((bytes > MAX_FILENAME_BYTES)) && return 0
    return 1
}

has_problematic_unicode() {
    local name="$1"
    # Check for zero-width characters, RTL marks, and various emoji ranges
    if command -v perl &>/dev/null; then
        if printf '%s' "$name" | perl -CSD -ne 'exit 0 if /[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}\x{FEFF}\x{1F300}-\x{1F9FF}\x{2600}-\x{26FF}\x{2700}-\x{27BF}]/; exit 1' 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

has_case_conflict() {
    local filepath="$1"
    local dir name lower_name
    dir=$(dirname "$filepath")
    name=$(basename "$filepath")
    lower_name="${name,,}"
    local count=0
    local f fn
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        fn=$(basename "$f")
        [[ "${fn,,}" == "$lower_name" ]] && ((++count)) || true
    done < <(find "$dir" -maxdepth 1 -name "*" 2>/dev/null || true)
    if ((count > 1)); then
        return 0
    fi
    return 1
}

detect_issues() {
    local filepath="$1"
    local name
    name=$(basename "$filepath")
    local issues=()

    has_forbidden_chars "$name" && issues+=("forbidden_chars")
    has_control_chars "$name" && issues+=("control_chars")
    is_reserved_name "$name" && issues+=("reserved_name")
    has_trailing_dot_space "$name" && issues+=("trailing_dot_space")
    has_leading_dot_space "$name" && issues+=("leading_space")
    exceeds_length "$name" && issues+=("length_exceeded")
    has_problematic_unicode "$name" && issues+=("problematic_unicode")
    has_case_conflict "$filepath" && issues+=("case_conflict")

    printf '%s\n' "${issues[@]}"
}

sanitize_name() {
    local name="$1"
    local strategy="${2:-underscore}"
    local replacement

    case "$strategy" in
        underscore) replacement="_" ;;
        hyphen) replacement="-" ;;
        remove) replacement="" ;;
        *) replacement="_" ;;
    esac

    # Remove control characters
    local result=""
    local char hex
    for ((i = 0; i < ${#name}; i++)); do
        char="${name:$i:1}"
        hex=$(printf '%d' "'$char" 2>/dev/null) || {
            result+="$char"
            continue
        }
        if ((hex >= 0 && hex <= 31)) || ((hex == 127)); then
            [[ -n "$replacement" ]] && result+="$replacement"
        else
            result+="$char"
        fi
    done
    name="$result"

    # Replace forbidden characters
    name=$(printf '%s' "$name" | sed "s/[:<>\"|\?\*\\\/]/${replacement}/g")

    # Remove problematic Unicode (zero-width, RTL marks)
    name=$(printf '%s' "$name" | perl -CSD -pe 's/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}\x{FEFF}]//g' 2>/dev/null || echo "$name")

    # Handle trailing dots/spaces
    name="${name%.}"
    name="${name% }"
    name="${name#' '}"

    # Handle reserved names
    local base="${name%%.*}"
    local ext="${name#*.}"
    if is_reserved_name "$base"; then
        if [[ "$name" == *"."* ]]; then
            name="_${base}.${ext}"
        else
            name="_${name}"
        fi
    fi

    # Truncate if too long
    while [[ $(printf '%s' "$name" | wc -c) -gt $MAX_FILENAME_BYTES ]]; do
        if [[ "$name" == *"."* ]]; then
            local ext="${name##*.}"
            local base="${name%.*}"
            base="${base:0:-1}"
            name="${base}.${ext}"
        else
            name="${name:0:-1}"
        fi
    done

    # Clean up multiple consecutive replacements
    if [[ -n "$replacement" ]]; then
        while [[ "$name" == *"${replacement}${replacement}"* ]]; do
            name="${name//${replacement}${replacement}/${replacement}}"
        done
    fi

    printf '%s' "$name"
}

get_unique_name() {
    local dir="$1"
    local name="$2"
    local base ext newname counter=1

    if [[ -e "$dir/$name" ]]; then
        if [[ "$name" == *"."* ]]; then
            ext="${name##*.}"
            base="${name%.*}"
        else
            ext=""
            base="$name"
        fi

        while true; do
            if [[ -n "$ext" ]]; then
                newname="${base}_${counter}.${ext}"
            else
                newname="${base}_${counter}"
            fi
            [[ ! -e "$dir/$newname" ]] && break
            ((counter++))
        done
        printf '%s' "$newname"
    else
        printf '%s' "$name"
    fi
}

backup_filename() {
    local original="$1"
    local newname="$2"
    local backup_dir="$3"

    mkdir -p "$backup_dir"
    echo "$(date -Iseconds)|$(pwd)|$original|$newname" >>"$backup_dir/$BACKUP_LOG"
}

do_rename() {
    local filepath="$1"
    local newname="$2"
    local dir
    dir=$(dirname "$filepath")
    local oldname
    oldname=$(basename "$filepath")

    if [[ "$oldname" == "$newname" ]]; then
        return 0
    fi

    local final_name
    final_name=$(get_unique_name "$dir" "$newname")

    if $DRY_RUN; then
        msg_verbose "  Would rename: '$oldname' -> '$final_name'"
        return 0
    fi

    backup_filename "$oldname" "$final_name" "$dir/$BACKUP_DIR"

    if mv "$filepath" "$dir/$final_name" 2>/dev/null; then
        msg_verbose "  Renamed: '$oldname' -> '$final_name'"
        ((++FIXED_FILES)) || true
        return 0
    else
        msg_error "Failed to rename '$oldname'"
        ((++ERRORS)) || true
        return 1
    fi
}

process_file() {
    local filepath="$1"
    local name issues_arr newname

    name=$(basename "$filepath")

    readarray -t issues_arr < <(detect_issues "$filepath")

    if [[ ${#issues_arr[@]} -eq 0 ]] || [[ -z "${issues_arr[0]}" ]]; then
        return 0
    fi

    ((++PROBLEM_FILES)) || true

    local issues_str
    issues_str=$(
        IFS=','
        echo "${issues_arr[*]}"
    )

    if $JSON_OUTPUT; then
        printf '{"file":"%s","issues":[%s]' \
            "$(json_escape "$filepath")" \
            "$(printf '"%s",' "${issues_arr[@]}" | sed 's/,$//')"
    else
        msg "${YELLOW}→ $name${NC}"
        msg "  Issues: $issues_str"
    fi

    if [[ "$MODE" == "fix" ]]; then
        newname=$(sanitize_name "$name" "$SANITIZE_STRATEGY")
        newname=$(get_unique_name "$(dirname "$filepath")" "$newname")

        if $JSON_OUTPUT; then
            printf ',"suggested":"%s"' "$(json_escape "$newname")"
        else
            msg "  Suggested: ${GREEN}$newname${NC}"
        fi

        if $INTERACTIVE && ! $DRY_RUN; then
            printf "  Apply rename? [y/N/q]: "
            read -r response
            case "$response" in
                [yY]) do_rename "$filepath" "$newname" ;;
                [qQ])
                    msg "Quitting..."
                    exit 0
                    ;;
                *)
                    ((++SKIPPED_FILES)) || true
                    msg "  Skipped"
                    ;;
            esac
        elif ! $INTERACTIVE; then
            do_rename "$filepath" "$newname"
        fi
    fi

    $JSON_OUTPUT && printf '}\n' || true
}

do_undo() {
    local target_dir="$1"
    local backup_file="$target_dir/$BACKUP_DIR/$BACKUP_LOG"

    if [[ ! -f "$backup_file" ]]; then
        msg_error "No backup found in $target_dir"
        return 1
    fi

    local count=0
    local restored=0

    msg "${BOLD}Restoring original filenames...${NC}"

    while IFS='|' read -r _timestamp _workdir original newname; do
        [[ -z "$original" ]] && continue
        ((++count)) || true

        local current_path="$target_dir/$newname"
        local original_path="$target_dir/$original"

        if [[ -e "$current_path" ]]; then
            if $DRY_RUN; then
                msg "Would restore: '$newname' -> '$original'"
            else
                if mv "$current_path" "$original_path" 2>/dev/null; then
                    msg_success "Restored: '$newname' -> '$original'"
                    ((++restored)) || true
                else
                    msg_error "Failed to restore '$newname'"
                fi
            fi
        else
            msg_warn "File not found: '$newname'"
        fi
    done <"$backup_file"

    if ! $DRY_RUN && [[ $restored -gt 0 ]]; then
        mv "$backup_file" "$backup_file.done"
    fi

    msg "\n${BOLD}Undo Summary:${NC}"
    msg "  Entries processed: $count"
    msg "  Files restored: $restored"
}

collect_files() {
    local target="$1"
    local files=()

    if $RECURSIVE; then
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$target" -type f -print0 2>/dev/null)
    else
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$target" -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    printf '%s\0' "${files[@]}"
}

print_summary() {
    $QUIET && return

    if $JSON_OUTPUT; then
        printf '{"summary":{"total":%d,"problems":%d,"fixed":%d,"skipped":%d,"errors":%d}}\n' \
            "$TOTAL_FILES" "$PROBLEM_FILES" "$FIXED_FILES" "$SKIPPED_FILES" "$ERRORS"
    else
        echo ""
        msg "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        msg "${BOLD}Summary${NC}"
        msg "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        msg "  Total files checked: ${BLUE}$TOTAL_FILES${NC}"
        msg "  Problems detected:   ${YELLOW}$PROBLEM_FILES${NC}"
        if [[ "$MODE" == "fix" ]]; then
            msg "  Files fixed:         ${GREEN}$FIXED_FILES${NC}"
            msg "  Files skipped:       ${CYAN}$SKIPPED_FILES${NC}"
        fi
        if [[ "$ERRORS" -gt 0 ]]; then
            msg "  Errors:              ${RED}$ERRORS${NC}"
        fi
        msg "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

        if $DRY_RUN; then
            msg "${YELLOW}(Dry run - no changes made)${NC}"
        fi
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c | --check)
                MODE="check"
                shift
                ;;
            -f | --fix)
                MODE="fix"
                shift
                ;;
            -u | --undo)
                MODE="undo"
                shift
                ;;
            -d | --dry-run)
                DRY_RUN=true
                shift
                ;;
            -i | --interactive)
                INTERACTIVE=true
                shift
                ;;
            -b | --batch)
                INTERACTIVE=false
                shift
                ;;
            -r | --recursive)
                RECURSIVE=true
                shift
                ;;
            -j | --json)
                JSON_OUTPUT=true
                shift
                ;;
            -v | --verbose)
                VERBOSE=true
                shift
                ;;
            -q | --quiet)
                QUIET=true
                shift
                ;;
            -s | --strategy)
                SANITIZE_STRATEGY="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --version)
                echo "namefix $VERSION"
                exit 0
                ;;
            -*)
                msg_error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                TARGET_DIR="$1"
                shift
                ;;
        esac
    done

    if [[ ! -d "$TARGET_DIR" ]]; then
        msg_error "Directory not found: $TARGET_DIR"
        exit 1
    fi

    TARGET_DIR=$(cd "$TARGET_DIR" && pwd)

    if [[ "$MODE" == "undo" ]]; then
        do_undo "$TARGET_DIR"
        exit $?
    fi

    if ! $JSON_OUTPUT && ! $QUIET; then
        msg "${BOLD}namefix v${VERSION}${NC}"
        msg "Target: ${BLUE}$TARGET_DIR${NC}"
        msg "Mode: ${CYAN}$MODE${NC}"
        $DRY_RUN && msg "${YELLOW}(Dry run mode)${NC}"
        $INTERACTIVE && msg "${CYAN}(Interactive mode)${NC}"
        echo ""
    fi

    $JSON_OUTPUT && printf '{"results":[\n' || true

    local files_list=()
    while IFS= read -r -d '' file; do
        files_list+=("$file")
    done < <(collect_files "$TARGET_DIR")

    TOTAL_FILES=${#files_list[@]}

    if ((TOTAL_FILES == 0)); then
        $JSON_OUTPUT || msg "No files found."
        $JSON_OUTPUT && printf '],\n' || true
        print_summary
        exit 0
    fi

    local first_json=true
    for filepath in "${files_list[@]}"; do
        ((++CHECKED_FILES)) || true

        ! $JSON_OUTPUT && ! $QUIET && progress_bar "$CHECKED_FILES" "$TOTAL_FILES"

        if $JSON_OUTPUT && ! $first_json; then
            # JSON separator handled in process_file
            :
        fi
        first_json=false

        process_file "$filepath"
    done

    ! $JSON_OUTPUT && ! $QUIET && echo ""

    $JSON_OUTPUT && printf '],\n' || true

    print_summary

    if [[ "$ERRORS" -gt 0 ]]; then
        exit 1
    elif [[ "$PROBLEM_FILES" -gt 0 ]] && [[ "$MODE" == "check" ]]; then
        exit 2
    fi
    exit 0
}

main "$@"
