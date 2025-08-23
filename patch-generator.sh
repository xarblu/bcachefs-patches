#!/usr/bin/env bash

# Script to generate a patch
#
# Assumptions:
# - You are inside a linux source directory
# - The repository has 2 remotes:
#   - origin -> git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
#   - bcachefs -> git://evilpiepirate.org/bcachefs.git

function log() {
    # shellcheck disable=SC2059
    printf "${@}" 1>&2
}

function confirm() {
    local prompt="${1:-'Confirm?'}"
    local response
    while true; do
        read -r -p "${prompt} [Y/n]: " response
        case "${response,,}" in
            y|yes|"") return 0 ;;
            n|no) return 1 ;;
            *) log "Bad response\n" ;;
        esac
    done
}

function help() {
    log "Usage:\n"
    log "  -o|--output  Output file or directory\n"
    log "               If file (.patch extension) this exact file is used\n"
    log "               If directory (must exist) auto generate a patch\n"
    log "               If not given auto generates file in current directory\n"
}

function parse_args() {
    while (( ${#} > 0 )); do
        case "${1}" in
            -o|--output)
                if (( ${#} < 2 )); then
                    log "Expected argument after %s\n" "${1}"
                    return 1
                fi
                OUT_FILE="${2}"
                shift 2
                ;;
            -h|--help)
                help
                exit 0
                ;;
            *)
                log "Bad argument %s\n" "${1}"
                return 1
                ;;
        esac
    done
}

function check_repo() {
    # basic check if we're in a git repo
    if [[ ! -d .git ]]; then
        log ".git does not exist\n"
        return 1
    fi

    # check if we have required remotes
    local remote
    for remote in origin bcachefs; do
        if ! git remote get-url "${remote}"; then
            log "Expected remote %s does not exist\n" "${remote}"
        fi
    done
}

function last_tag() {
    declare -g _LAST_TAG

    if [[ -z "${_LAST_TAG}" ]]; then
        LAST_TAG="$(git describe --abbrev=0)"
    fi

    printf "%s" "${LAST_TAG}"
}

function expand_out_file() {
    if [[ "${OUT_FILE}" == *.patch ]]; then
        return 0
    fi

    if [[ -z "${OUT_FILE}" ]]; then
        OUT_FILE="${PWD}"
    fi

    if [[ -d "${OUT_FILE}" ]]; then
        OUT_FILE="${OUT_FILE%/}/bcachefs-$(TZ=UTC date '+%Y%m%d%H%M%S')-for-$(last_tag).patch"
    else
        log "Output %s does not end with .patch and is not an existing directory" \
            "${OUT_FILE}"
        return 1
    fi
}

function main() {
    if ! parse_args "${@}"; then
        help
        return 1
    fi

    expand_out_file || return 1

    log "Detected last tag %s\n" "$(last_tag)"

    if confirm "Reset repo to that tag?"; then
        git reset --hard "$(last_tag)"
    fi

    if confirm "Cleanup any stale files/directories?"; then
        git clean -fdx
    fi

    if confirm "Fetch bcachefs?"; then
        git fetch bcachefs
    fi

    if confirm "Merge bcachefs/master?"; then
        git merge bcachefs/master
    fi

    if confirm "Write patch to ${OUT_FILE}"; then
        git diff 'HEAD~' > "${OUT_FILE}"
    fi
}
main "${@}"
