#!/usr/bin/env bash

# Script to generate a patch
#
# Assumptions:
# - You are inside a linux source directory
# - The repository has 2 remotes:
#   - origin -> git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
#   - bcachefs -> git://evilpiepirate.org/bcachefs.git

# git repos and remotes used
declare -g LINUX_REPO="${BASH_SOURCE[0]%/*}/../linux"
declare -g LINUX_REMOTE='origin'
declare -g LINUX_BCACHEFS_REMOTE='bcachefs'

declare -g BCACHEFS_TOOLS_REPO="${BASH_SOURCE[0]%/*}/../bcachefs-tools"
declare -g BCACHEFS_TOOLS_REMOTE='origin'

# log utility function writing to stderr
function log() {
    local fmt="${1}"
    shift
    # shellcheck disable=SC2059
    printf " \e[32m*\e[0m ${fmt}\n" "${@}" 1>&2
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
            *) log 'Bad response: %s' "${response}" ;;
        esac
    done
}

# --help listing
function help() {
    log 'Usage:'
    log '  -o|--output  Output file or directory'
    log '               If file (.patch extension) this exact file is used'
    log '               If directory (must exist) auto generate a patch'
    log '               If not given auto generates file in current directory'
    log '  -t|--tag     Linux tag to base patch on. Latest if unset.'
}

# argparser
function parse_args() {
    while (( ${#} > 0 )); do
        case "${1}" in
            -o|--output)
                if (( ${#} < 2 )); then
                    log 'Expected argument after %s' "${1}"
                    exit 1
                fi
                shift
                OUT_FILE="${1}"
                ;;
            -t|--tag)
                if (( ${#} < 2 )); then
                    log 'Expected argument after %s' "${1}"
                    exit 1
                fi
                shift
                TAG="${1}"
                ;;

            -h|--help)
                help
                exit 0
                ;;
            *)
                log 'Bad argument %s' "${1}"
                exit 1
                ;;
        esac
        shift
    done
}

# basic check if repo in cwd has remotes passed as args
function check_remotes() {
    # basic check if we're in a git repo
    if [[ ! -d .git ]]; then
        log '.git does not exist'
        log 'Is the current directory a linux source tree?'
        exit 1
    fi

    # check if we have required remotes
    local remote url
    for remote in "${@}"; do
        if url=$(git remote get-url "${remote}"); then
            log 'Using remote %s from %s' "${remote}" "${url}" 
        else
            log 'Expected remote %s does not exist' "${remote}"
            exit 1
        fi
    done
}

# get last git tag name before ref in arg 1
# returned in REPLY
function last_tag() {
    local ref="${1}"
    local tag
    if ! tag="$(git describe --abbrev=0 "${ref}")"; then
        log 'Failed to get tag for ref: %s' "${ref}"
        exit 1
    fi

    REPLY="${tag}"
}

# generate output file name
# returned in REPLY
function generate_out_file() {
    local bcachefs_tag="${1}"
    local linux_tag="${2}"

    if [[ "${OUT_FILE}" == *.patch ]]; then
        REPLY="$(readlink -m "${OUT_FILE}")"
        return 0
    fi

    if [[ -z "${OUT_FILE}" ]]; then
        OUT_FILE="${PWD}"
    fi

    if [[ -d "${OUT_FILE}" ]]; then
        OUT_FILE="${OUT_FILE%/}/bcachefs-${bcachefs_tag}-for-${linux_tag}.patch"
    else
        log 'Output %s does not end with .patch and is not an existing directory' \
            "${OUT_FILE}"
        exit 1
    fi

    REPLY="$(readlink -m "${OUT_FILE}")"
}

# detect latest stable bcachefs revision
# based on bcachefs-tools tagged release
# result in REPLY as tag:commit
function update_bcachefs_tools() {
    log 'Detecting latest stable bcachefs commit from bcachefs-tools'

    if ! pushd "${BCACHEFS_TOOLS_REPO}" >/dev/null; then
        log 'Failed to cd into bcachefs-tools source tree: %s' "${BCACHEFS_TOOLS_REPO}"
        exit 1
    fi

    check_remotes "${BCACHEFS_TOOLS_REMOTE}"

    log 'Fetching updates via git'
    git fetch "${BCACHEFS_TOOLS_REMOTE}"

    last_tag "${BCACHEFS_TOOLS_REMOTE}/master"
    local tag="${REPLY}"
    log 'Detected last tag: %s' "${tag}"

    local commit
    if ! commit="$(git cat-file -p "${tag}:.bcachefs_revision")"; then
        log 'Failed to cat .bcachefs_revision at tag %s' "${tag}"
        exit 1
    fi

    log 'Detected commit %s for tag %s' "${commit}" "${tag}"

    REPLY="${tag}:${commit}"

    popd >/dev/null || exit 1
}

# update linux source tree and return latest tag in REPLY
function update_linux() {
    log 'Preparing linux source tree'

    if ! pushd "${LINUX_REPO}" >/dev/null; then
        log 'Failed to cd into linux source tree: %s' "${LINUX_REPO}"
        exit 1
    fi

    check_remotes "${LINUX_REMOTE}" "${LINUX_BCACHEFS_REMOTE}"

    log 'Fetching updates via git'
    git fetch "${LINUX_REMOTE}"
    git fetch "${LINUX_BCACHEFS_REMOTE}"

    local tag
    if [[ -n "${TAG}" ]]; then
        tag="${TAG}"
        if ! git show "${tag}" &>/dev/null; then
            log 'Specified tag does not exist: %s' "${tag}"
            exit 1
        fi
        log 'Using specified tag: %s' "${tag}"
    else
        last_tag "${LINUX_REMOTE}/master"
        tag="${REPLY}"
        log 'Detected last tag: %s' "${tag}"
    fi

    REPLY="${tag}"

    popd >/dev/null || exit 1
}

function main() {
    parse_args "${@}"

    update_bcachefs_tools
    local bcachefs_tag bcachefs_commit
    IFS=':' read -r bcachefs_tag bcachefs_commit <<<"${REPLY}"

    update_linux
    local linux_tag="${REPLY}"

    generate_out_file "${bcachefs_tag}" "${linux_tag}"
    local file="${REPLY}"

    # We need to limit the diff path to bcachefs related stuff
    # to not pull in random bits when diffing with older tags.
    # Kent's tree seems to occasionally touch things like
    # closures.h or generic-radix-tree.h
    # which we'll ignore for now unless that starts causing issues.
    # DKMS wouldn't have those changes either
    local -a bch_paths=(
            Documentation/filesystems/bcachefs
            fs/bcachefs
    )

    if confirm "Write patch to ${file}"; then
        pushd "${LINUX_REPO}" >/dev/null || exit 1
        git diff "${linux_tag}...${bcachefs_commit}" -- "${bch_paths[@]}" > "${file}"
        popd >/dev/null || exit 1
    fi
}

main "${@}"
