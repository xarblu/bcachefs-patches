#!/usr/bin/env bash

# Script to generate a patch
#
# Assumptions:
# - You are inside a linux source directory
# - The repository has 2 remotes:
#   - origin -> git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
#   - bcachefs -> git://evilpiepirate.org/bcachefs.git

# git refs used
declare -g LINUX_REF='origin/master'
declare -g BCACHEFS_REF='bcachefs/for-next'

# log utility function writing to stderr
function log() {
    # shellcheck disable=SC2059
    printf "${@}" 1>&2
}

# Y/n prompt
function confirm() {
    local prompt="${1:-'Confirm?'}"
    local response
    while true; do
        read -r -p "${prompt} [Y/n]: " response
        case "${response,,}" in
            y|yes|'') return 0 ;;
            n|no) return 1 ;;
            *) log 'Bad response\n' ;;
        esac
    done
}

# --help listing
function help() {
    log 'Usage:\n'
    log '  -o|--output  Output file or directory\n'
    log '               If file (.patch extension) this exact file is used\n'
    log '               If directory (must exist) auto generate a patch\n'
    log '               If not given auto generates file in current directory\n'
}

# argparser
function parse_args() {
    while (( ${#} > 0 )); do
        case "${1}" in
            -o|--output)
                if (( ${#} < 2 )); then
                    log 'Expected argument after %s\n' "${1}"
                    exit 1
                fi
                OUT_FILE="${2}"
                shift 2
                ;;
            -h|--help)
                help
                exit 0
                ;;
            *)
                log 'Bad argument %s\n' "${1}"
                exit 1
                ;;
        esac
    done
}

# basic checks if repo is valid
function check_repo() {
    # basic check if we're in a git repo
    if [[ ! -d .git ]]; then
        log '.git does not exist\n'
        log 'Is the current directory a linux source tree?\n'
        exit 1
    fi

    # check if we have required remotes
    local remote url
    for remote in "${LINUX_REF%/*}" "${BCACHEFS_REF%/*}"; do
        if url=$(git remote get-url "${remote}"); then
            log 'Using remote %s from %s\n' "${remote}" "${url}" 
        else
            log 'Expected remote %s does not exist\n' "${remote}"
            exit 1
        fi
    done
}

# get last git tag name before the checked-out commit
# returned in REPLY
function last_tag() {
    declare -g _LAST_TAG

    if [[ -z "${_LAST_TAG}" ]]; then
        _LAST_TAG="$(git describe --abbrev=0)"
    fi

    REPLY="${_LAST_TAG}"
}

# get date of last commit formatted as
# YYYYmmDDHHMMSS
# returned in REPLY
function get_ref_date() {
    local ref="${1}"
    local unix_time
    if ! unix_time="$(git log -n 1 --format=%ct "${ref}")"; then
        log 'Bad ref: %s\n' "${ref}"
        exit 1
    fi

    TZ=UTC0 printf -v REPLY '%(%Y%m%d%H%M%S)T' "${unix_time}"
}

# generate output file name
# returned in REPLY
function out_file() {
    if [[ "${OUT_FILE}" == *.patch ]]; then
        REPLY="${OUT_FILE}"
        return 0
    fi

    if [[ -z "${OUT_FILE}" ]]; then
        OUT_FILE="${PWD}"
    fi

    if [[ -d "${OUT_FILE}" ]]; then
        get_ref_date "${BCACHEFS_REF}"
        local bch_date="${REPLY}"
        last_tag
        local lnx_tag="${REPLY}"
        OUT_FILE="${OUT_FILE%/}/bcachefs-${bch_date}-for-${lnx_tag}.patch"
    else
        log 'Output %s does not end with .patch and is not an existing directory\n' \
            "${OUT_FILE}"
        exit 1
    fi

    REPLY="${OUT_FILE}"
}

function main() {
    parse_args "${@}"

    check_repo

    if confirm "Fetch ${LINUX_REF%/*}?"; then
        git fetch "${LINUX_REF%/*}"
    fi

    if confirm "Fetch ${BCACHEFS_REF%/*}?"; then
        git fetch "${BCACHEFS_REF%/*}"
    fi

    if confirm "Reset repo to ${LINUX_REF}?"; then
        git reset --hard "${LINUX_REF}"
    fi

    last_tag
    local tag="${REPLY}"
    log 'Detected last tag %s\n' "${tag}"

    if confirm 'Reset repo to that tag?'; then
        git reset --hard "${tag}"
    fi

    if confirm 'Cleanup any stale files/directories?'; then
        git clean -fdx
    fi

    out_file
    local file="${REPLY}"

    if confirm "Write patch to ${file}"; then
        git diff "${tag}...${BCACHEFS_REF}" > "${file}"
    fi
}

main "${@}"
