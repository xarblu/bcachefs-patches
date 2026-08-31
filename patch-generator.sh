#!/usr/bin/env bash

# Script to generate a patch
#
# Usage (at repo root):
#   # Latest tagged release, written to "patches" directory
#   ./patch-generator.sh -o patches
#
#   # Latest master snapshot, written to "snapshots" directory
#   ./patch-generator.sh -o patches -s origin/master


# shellcheck disable=SC2155
declare -g SCRIPT_DIR="$(readlink -e "${BASH_SOURCE[0]%/*}")" 

# git repos and remotes used
declare -g BCACHEFS_TOOLS_REPO="${SCRIPT_DIR}/../bcachefs-tools"
declare -g BCACHEFS_TOOLS_REMOTE='origin'

set -o pipefail

# log utility function writing to stderr
function log() {
    local fmt="${1}"
    shift
    # shellcheck disable=SC2059
    printf " \e[32m*\e[0m ${fmt}\n" "${@}" 1>&2
}

# log + exit shorthand
function die() {
    log "${@}"
    exit 1
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
function usage() {
    log 'Usage:'
    log '  -o|--output   Output file or directory'
    log '                If file (.patch extension) this exact file is used'
    log '                If directory (must exist) auto generate a patch'
    log '                If not given auto generates file in current directory'
    log '  -s|--snapshot bcachefs-tools snapshot (commit) to use instead of last tagged release.'
    log '  -n|--no-glue  Dont append any glue patches - just create the base bcachefs patch.'
    log "                NOTE: This patch won't work on its own and is mainly intended as a clean base for rebasing glue patches."
}

# argparser
function parse_args() {
    # defaults / unset to prevent leakage from env
    unset OUT_FILE
    unset SNAPSHOT
    GLUE=1

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
            -s|--snapshot)
                if (( ${#} < 2 )); then
                    log 'Expected argument after %s' "${1}"
                    exit 1
                fi
                shift
                SNAPSHOT="${1}"
                ;;
            -n|--no-glue)
                GLUE=0
                ;;
            -h|--help)
                usage
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

# get last git tag name before rev in arg 1
# returned in REPLY
function last_tag() {
    local rev="${1}"
    if ! REPLY="$(git describe --abbrev=0 "${rev}")"; then
        log 'Failed to get tag for rev: %s' "${rev}"
        exit 1
    fi
}

# get date of commit formatted as YYYYMMDDHHMMSS
# returned in REPLY
function commit_date() {
    if ! pushd "${BCACHEFS_TOOLS_REPO}" >/dev/null; then
        log 'Failed to cd into bcachefs-tools tree: %s' "${BCACHEFS_TOOLS_REPO}"
        exit 1
    fi

    local rev="${1}"
    if ! REPLY="$(git show --no-patch --format=format:%cI "${rev}" | sed -E -e 's/[+-][0-9][0-9]:[0-9][0-9]$//g' -e 's/[T:-]//g')"; then
        log 'Failed to get date for rev: %s' "${rev}"
        exit 1
    fi

    popd >/dev/null || exit 1
}

# detect bcachefs on disk version format at specified commit
# returned in REPLY
function detect_bch_version() {
    local rev="${1}"

    local parser bch_version

    parser="${SCRIPT_DIR}/parse_bch_version.pl"
    if [[ ! -x "${parser}" ]]; then
        log 'Parser script does not exist at %s or is not executable' "${parser}"
        exit 1
    fi

    if ! pushd "${BCACHEFS_TOOLS_REPO}" >/dev/null; then
        log 'Failed to cd into bcachefs-tools tree: %s' "${BCACHEFS_TOOLS_REPO}"
        exit 1
    fi

    local fmt_h="fs/bcachefs_format.h"
    if ! bch_version="$(git cat-file -p "${rev}:${fmt_h}" | "${parser}")"; then
        log 'Failed to parse bcachefs version from %s' "${fmt_h}"
        exit 1
    fi

    REPLY="${bch_version}"

    popd >/dev/null || exit 1
}

# expand OUT_FILE
function generate_out_file() {
    local bcachefs_tag="${1}"

    if [[ "${OUT_FILE}" == *.patch ]]; then
        OUT_FILE="$(readlink -m "${OUT_FILE}")"
        return 0
    fi

    if [[ -z "${OUT_FILE}" ]]; then
        OUT_FILE="${PWD}"
    fi

    if [[ -d "${OUT_FILE}" ]]; then
        OUT_FILE="${OUT_FILE%/}/bcachefs-${bcachefs_tag}.patch"
    else
        log 'Output %s does not end with .patch and is not an existing directory' \
            "${OUT_FILE}"
        exit 1
    fi

    if ! ((GLUE)); then
        OUT_FILE="${OUT_FILE%.patch}-no-glue.patch"
    fi

    OUT_FILE="$(readlink -m "${OUT_FILE}")"
}

# detect latest stable bcachefs revision
# based on bcachefs-tools tagged release
# result in REPLY as tag:commit:
function update_bcachefs_tools() {
    log 'Detecting required metadata from bcachefs-tools'

    if ! pushd "${BCACHEFS_TOOLS_REPO}" >/dev/null; then
        log 'Failed to cd into bcachefs-tools source tree: %s' "${BCACHEFS_TOOLS_REPO}"
        exit 1
    fi

    check_remotes "${BCACHEFS_TOOLS_REMOTE}"

    log 'Fetching updates via git'
    git fetch "${BCACHEFS_TOOLS_REMOTE}"

    last_tag "${BCACHEFS_TOOLS_REMOTE}/master"
    local bch_tools_last_tag="${REPLY}"

    local bch_tools_rev
    if [[ -z "${SNAPSHOT}" ]]; then
        bch_tools_rev="$(git rev-list -1 "${bch_tools_last_tag}")"
        log 'Using detected last tag: %s (%s)' "${bch_tools_last_tag}" "${bch_tools_rev}"
    else
        bch_tools_rev="$(git rev-list -1 "${SNAPSHOT}")"
        log 'Using provided revision: %s (%s)' "${SNAPSHOT}" "${bch_tools_rev}"
    fi

    local version_string
    if ! version_string="$(git -c safe.directory="${PWD}" -c core.abbrev=12 describe "${bch_tools_rev}")"; then
        log 'Failed to generate version string from bcachefs-tools'
        exit 1
    fi
    log 'Generated module version string: %s' "${version_string}"

    # tag used to name the patch file
    local tag
    if [[ -z "${SNAPSHOT}" ]]; then
        tag="${bch_tools_last_tag}"
    else
        # 
        last_tag "${bch_tools_rev}"
        bch_tools_last_tag="${REPLY}"
        detect_bch_version "${bch_tools_rev}"
        tag="v${REPLY}"
        
        # last_stable_tag has major.minor.patch
        # detected version from bcachefs repo
        # has major.minor
        # If major.minor matches this is a snapshot for
        # the next patch, if not it's for the next minor release
        # (assuming no major changes)
        if [[ "${bch_tools_last_tag}" == "${tag}"* ]]; then
            tag="${tag}.$(( "${bch_tools_last_tag##*.}" + 1 ))"
        else
            tag="${tag}.0"
        fi

        commit_date "${bch_tools_rev}"
        tag+="_pre${REPLY}"
    fi

    REPLY="${tag}:${bch_tools_rev}:${version_string}"

    popd >/dev/null || exit 1
}

# write glue patch for KConfig and Makefile
# to stdout
# required for 6.18+ due to upstream removal
function glue_patch() {
    if (( ! GLUE )); then
        log 'Skipping glue patch(es) (--no-glue)'
        return 0
    fi

    local bcachefs_tag="${1}"
    local glue_dir="${OUT_FILE%/*}/glue"

    if [[ ! -d "${glue_dir}" ]]; then
        die 'Output directory has no glue subdirectory but one is expected at: %s' "${glue_dir}"
    fi

    # kconf is always expected/required,
    # others are version dependent
    local -a glue=(
        "${glue_dir}/bcachefs-kconf.patch"
    )

    if [[ -d "${glue_dir}/${bcachefs_tag}/" ]]; then
        glue+=( "${glue_dir}/${bcachefs_tag}/"*.patch )
    fi

    local f
    for f in "${glue[@]}"; do
        if [[ ! -f "${f}" ]]; then
            log 'Glue patch does not exist: %s' "${f}"
            exit 1
        fi

        log 'Appending glue patch: %s' "${f}"
        cat "${f}" || exit 1
    done
}

function module_version_patch() {
    if (( ! GLUE )); then
        log 'Skipping module version patch (--no-glue)'
        return 0
    fi

    local version_string="${1}"
    local module_version_patch="${OUT_FILE%/*}/glue/bcachefs-module-version.patch"

    if [[ ! -f "${module_version_patch}" ]]; then
        log 'Module version patch does not exist: %s' "${module_version_patch}"
        exit 1
    fi

    log 'Appending module version patch with version: %s' "${version_string}"
    perl -pe "s/%%VERSION_STRING%%/${version_string}/" "${module_version_patch}"
}

function bcachefs_patch_from_tools_rev() {
    local rev="${1}"
    local dest="${2}"
    local staging

    # preperation
    staging="$(mktemp -d)" || die "Failed to create staging dir ${staging}"

    log "Preparing staging area in ${staging}"

    if ! pushd "${BCACHEFS_TOOLS_REPO}" >/dev/null; then
        log 'Failed to cd into bcachefs-tools source tree: %s' "${BCACHEFS_TOOLS_REPO}"
        exit 1
    fi

    # fetch bcachefs files from bcachefs-tools
    # and transform them to linux source tree structure on the fly
    if ! git archive "${rev}" | tar -x --transform='s|^fs|fs/bcachefs|' -C "${staging}" fs; then
        die "Failed to snapshot bcachefs-tools repo into ${staging}"
    fi

    popd >/dev/null || die "popd failed"

    # create the actual patch
    pushd "${staging}" >/dev/null || die 'Failed to cd into staging area: %s' "${staging}"

    git init || die "git init failed"
    git add . || die "git add failed"
    git commit --no-gpg-sign -m "bcachefs-tools ${rev}" || die "git commit failed"
    git format-patch --stdout --root > "${dest}" || die "failed to write patch file"

    popd >/dev/null || die "popd failed"

    log "Successfully created base patch"

    # cleanup
    if confirm "Remove staging dir ${staging}?"; then
        rm -rf "${staging}" || die "rm failed"
    fi
}

function main() {
    parse_args "${@}"

    local bcachefs_tag bcachefs_tools_commit bcachefs_version_string
    update_bcachefs_tools
    IFS=':' read -r bcachefs_tag bcachefs_tools_commit bcachefs_version_string <<<"${REPLY}"
    generate_out_file "${bcachefs_tag}"

    log 'About to create patch for: %s (bachefs-tools %s)' \
        "${bcachefs_version_string}" \
        "${bcachefs_tools_commit}"

    if confirm "Write patch to ${OUT_FILE}?"; then
        bcachefs_patch_from_tools_rev "${bcachefs_tools_commit}" "${OUT_FILE}"
        glue_patch "${bcachefs_tag}" >> "${OUT_FILE}"
        module_version_patch "${bcachefs_version_string}" >> "${OUT_FILE}"
        return 0
    fi
    
    return 1
}

main "${@}"
