#!/bin/bash
# =============================================================================
# E-Voting Compilation and Hash Generation Script
# Version: 1.6.2.1
# =============================================================================
#
# PURPOSE
#   This script supports the reproducible build verification process for the
#   Swiss Post e-voting system. It covers the full lifecycle from environment
#   setup to hash report generation:
#
#     1. clean_system          – Remove cached build artifacts and tool folders
#     2. install_prerequisites – Install Docker and Wine via the system package manager
#     3. download_tools        – Download Java, Node.js, and Maven into a local tools folder
#     4. clone_repositories    – Clone all required source repositories from GitLab
#     5. compile_projects      – Build all projects in dependency order
#     6. generate_hashes       – Compute SHA-256/SHA-384 checksums and write a report
#
# USAGE
#   Run the script without arguments; it will present an interactive menu.
#   Enter the numbers of the steps you want to execute (e.g. "456"), or "0"
#   to run all steps in sequence.
#
# SCRIPT REPOSITORY
#   The current version of this script is maintained at:
#     https://github.com/tg-sk-rd/evoting-trusted-build        ← adjust URL as needed
#   The protocol document should reference that URL rather than embedding
#   the script source directly.
#
# REQUIREMENTS
#   - Linux with apt (Debian/Ubuntu) or pacman (Arch) package manager
#   - git, wget, openssl, sha256sum available in PATH
#   - SSH key configured for GitLab (for cloning via git@gitlab.com)
#
# DIRECTORY LAYOUT
#   By default, all files are placed under ${HOME}/evoting:
#     tools/java    – JDK (Temurin 25)
#     tools/node    – Node.js 22
#     tools/maven   – Apache Maven 3.9
#     evsource/     – Cloned source repositories
#
#   Adjust EVOTING_FOLDER at the top of this file if a different base
#   directory is preferred.
#
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration – adjust these paths if needed
# ---------------------------------------------------------------------------

EVOTING_FOLDER="${HOME}/evoting"
EVOTING_SOURCE="${EVOTING_FOLDER}/evsource"

# Log file – all output is written here as well as to the terminal
LOG_FILE="${EVOTING_FOLDER}/$(date '+%Y%m%d_%H%M')_build.log"

# Canton identifier used in the hash report filename
CANTON="TG"

# E-Voting release
EV_RELEASE="1.6.2.1"

# Tool versions
JAVA_VERSION="25.0.4.1+1"
JAVA_TAG="jdk-25.0.4.1%2B1"            # URL-encoded form of the tag
NODE_VERSION="24.21.0"
MAVEN_VERSION="3.9.11"

# Docker registry used during compilation
DOCKER_REGISTRY="registry.gitlab.com/swisspost-evoting/e-voting/evoting-e2e-dev"

# Repositories to clone: each entry is "<branch> <git-url>"
# The branch name matches the release tag of that component.
REPOSITORIES=(
    "e-voting-${EV_RELEASE}             git@gitlab.com:swisspost-evoting/e-voting/e-voting.git"
    "e-voting-libraries-1.6.2.0   git@gitlab.com:swisspost-evoting/e-voting/e-voting-libraries.git"
    "crypto-primitives-ts-1.6.2.0 git@gitlab.com:swisspost-evoting/crypto-primitives/crypto-primitives-ts.git"
    "crypto-primitives-1.6.2.0    git@gitlab.com:swisspost-evoting/crypto-primitives/crypto-primitives.git"
    "data-integration-service-2.10.2.0 git@gitlab.com:swisspost-evoting/e-voting/data-integration-service.git"
    "verifier-1.7.2.1             git@gitlab.com:swisspost-evoting/verifier/verifier.git"
    "pdf-verification-service-1.6.2.0 git@gitlab.com:swisspost-evoting/e-voting/pdf-verification-service.git"
    "testdata-1.6.2.0             git@gitlab.com:swisspost-evoting/e-voting/testdata.git"
)

# Projects and their build order (Maven builds each with -f <name>)
PROJECTS=(
    "crypto-primitives"
    "crypto-primitives-ts"
    "testdata"
    "e-voting-libraries"
    "e-voting"
    "data-integration-service"
    "verifier"
    "pdf-verification-service"
)

# ---------------------------------------------------------------------------
# Helper utilities
# ---------------------------------------------------------------------------

# Print an error message including the line number and exit code.
log_error() {
    echo "ERROR: Command failed at line $1 (exit code $2)" >&2
}

# Remove a directory safely, falling back to sudo if needed.
# Refuses to operate on empty paths or the filesystem root.
safe_rm() {
    local path="$1"
    if [[ -z "$path" || "$path" == "/" ]]; then
        echo "safe_rm: refusing to remove '${path}'" >&2
        return 1
    fi
    rm -rf "$path" 2>/dev/null || {
        echo "Could not remove ${path}, retrying with sudo..."
        sudo rm -rf "$path" 2>/dev/null || log_error "${BASH_LINENO[0]}" "$?"
    }
}

# Add directories to PATH for the current session, avoiding duplicates.
path_append() {
    for dir in "$@"; do
        if [[ -d "$dir" && ":$PATH:" != *":$dir:"* ]]; then
            PATH="${PATH:+$PATH:}$dir"
        fi
    done
}

# ---------------------------------------------------------------------------
# Step 1 – Clean the system
# ---------------------------------------------------------------------------
# Removes Maven and npm caches as well as the local source and tools folders.
# Run this before a fresh build to ensure a clean state.

clean_system() {
    echo "==> Cleaning system..."
    local paths=("$HOME/.m2" "$HOME/.npm" "${EVOTING_SOURCE}" "${EVOTING_FOLDER}/tools")
    for path in "${paths[@]}"; do
        echo "    Removing: ${path}"
        safe_rm "$path"
    done
    echo "    Done."
}

# ---------------------------------------------------------------------------
# Step 2 – Install prerequisite tools
# ---------------------------------------------------------------------------
# Installs Docker and Wine using the system package manager (apt or pacman).
# Any existing Java installation is removed first to avoid version conflicts
# with the project-local JDK that is downloaded in the next step.

install_prerequisites() {
    echo "==> Installing prerequisites..."

    # --- Remove system Java to avoid conflicts with the project-local JDK ---
    if command -v java &>/dev/null; then
        echo "    Removing system Java..."
        if command -v apt &>/dev/null; then
            sudo apt remove --purge openjdk-\* -y 2>/dev/null || log_error "${BASH_LINENO[0]}" "$?"
        elif command -v pacman &>/dev/null; then
            sudo pacman -Rs java-openjdk jre-openjdk --noconfirm 2>/dev/null || log_error "${BASH_LINENO[0]}" "$?"
        else
            echo "    Unsupported package manager – please remove Java manually." >&2
        fi
    fi

    # --- Docker ---
    if ! command -v docker &>/dev/null; then
        echo "    Installing Docker..."
        if command -v apt &>/dev/null; then
            curl -fsSL https://get.docker.com -o get-docker.sh || log_error "${BASH_LINENO[0]}" "$?"
            sudo sh get-docker.sh                              || log_error "${BASH_LINENO[0]}" "$?"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S docker --noconfirm                 || log_error "${BASH_LINENO[0]}" "$?"
        else
            echo "    Unsupported package manager – please install Docker manually." >&2
        fi
        sudo systemctl enable --now docker                    || log_error "${BASH_LINENO[0]}" "$?"
        sudo usermod -aG docker "$USER"                       || log_error "${BASH_LINENO[0]}" "$?"
        echo "    Docker installed."
    else
        echo "    Docker already present – skipping."
    fi

    # --- Wine (required for building the secure-data-manager Windows package) ---
    if ! command -v wine &>/dev/null; then
        echo "    Installing Wine..."
        if command -v apt &>/dev/null; then
            sudo apt install -y wine wine-mono wine-gecko 2>/dev/null \
                || sudo apt install -y wine                           \
                || log_error "${BASH_LINENO[0]}" "$?"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S wine wine-mono wine-gecko --noconfirm 2>/dev/null \
                || sudo pacman -S wine --noconfirm                           \
                || log_error "${BASH_LINENO[0]}" "$?"
        else
            echo "    Unsupported package manager – please install Wine manually." >&2
        fi
        echo "    Wine installed."
    else
        echo "    Wine already present – skipping."
    fi

    echo "    Done."
}

# ---------------------------------------------------------------------------
# Step 3 – Download build tools
# ---------------------------------------------------------------------------
# Downloads a project-local JDK, Node.js, and Maven into ${EVOTING_FOLDER}/tools.
# These versions are kept separate from any system-wide installations.

download_tools() {
    echo "==> Downloading build tools..."
    _create_directories

    echo "    Downloading JDK ${JAVA_VERSION}..."
    curl -fL --progress-bar "https://github.com/adoptium/temurin25-binaries/releases/download/${JAVA_TAG}/OpenJDK25U-jdk_x64_linux_hotspot_${JAVA_VERSION/+/_}.tar.gz" \
        | tar -xz --strip-components=1 -C "${EVOTING_FOLDER}/tools/java" \
        || log_error "${BASH_LINENO[0]}" "$?"

    echo "    Downloading Node.js ${NODE_VERSION}..."
    curl -fL --progress-bar "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
        | tar -xz --strip-components=1 -C "${EVOTING_FOLDER}/tools/node" \
        || log_error "${BASH_LINENO[0]}" "$?"

    echo "    Downloading Maven ${MAVEN_VERSION}..."
    curl -fL --progress-bar "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        | tar -xz --strip-components=1 -C "${EVOTING_FOLDER}/tools/maven" \
        || log_error "${BASH_LINENO[0]}" "$?"

    echo "    Done."
}

# ---------------------------------------------------------------------------
# Step 4 – Clone source repositories
# ---------------------------------------------------------------------------
# Clones each repository at the branch/tag that corresponds to this release.
# Requires an SSH key authorised for the SwissPost GitLab group.

clone_repositories() {
    echo "==> Cloning repositories..."
    _create_directories
    _set_environment

    cd "${EVOTING_SOURCE}" || { log_error "${BASH_LINENO[0]}" "$?"; return; }

    # Allow long file paths (needed on some file systems)
    git config --global core.longpaths true

    for repo in "${REPOSITORIES[@]}"; do
        local branch url
        branch=$(echo "$repo" | awk '{print $1}')
        url=$(echo "$repo"    | awk '{print $2}')
        echo "    Cloning ${branch} from ${url}..."
        git clone -b "$branch" --single-branch "$url" || log_error "${BASH_LINENO[0]}" "$?"
    done

    echo "    Done."
}

# ---------------------------------------------------------------------------
# Step 5 – Compile projects
# ---------------------------------------------------------------------------
# Builds all projects in dependency order using the project-local Maven and JDK.
# Tests and hash generation are skipped here; hashes are produced in step 6.

compile_projects() {
    echo "==> Compiling projects..."
    _set_environment
    _ensure_wine_prefix

    cd "${EVOTING_SOURCE}" || { log_error "${BASH_LINENO[0]}" "$?"; return; }

    for project in "${PROJECTS[@]}"; do
        echo "    Building: ${project}"
        mvn clean install \
            -f "$project" \
            -DskipTests \
            -T 1.5C \
            -DskipHashGeneration \
            --no-transfer-progress \
            -e \
            || log_error "${BASH_LINENO[0]}" "$?"
    done

    echo "    Done."
}

# ---------------------------------------------------------------------------
# Step 6 – Generate hash report
# ---------------------------------------------------------------------------
# Computes SHA-256 checksums for all primary artefacts and SHA-384 checksums
# (Base64-encoded, single line) for the voter-portal JavaScript files.
# SHA-384 is required for those files because the hashes appear verbatim in
# the application's Content Security Policy (CSP) integrity attributes.
#
# The artefact paths are fully deterministic after compilation; only the
# version numbers embedded in the filenames vary between releases.
# Version numbers are read directly from the actual filenames on disk.
#
# Output is written to ${EVOTING_FOLDER}/<timestamp>_<canton>_ev_hashes.txt
# and contains two sections:
#
#   SECTION 1 – Plain table ("filename  hash"), ready to copy into the
#               protocol document.
#
#   SECTION 2 – Markdown table with columns Artefact | Version | Checksum,
#               suitable for publication.

generate_hashes() {
    echo "==> Generating hash report..."
    _set_environment

    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M')
    local report="${EVOTING_FOLDER}/${timestamp}_${CANTON}_ev_hashes.txt"

    # Convenience paths used throughout this function
    local src="${EVOTING_SOURCE}"
    local vp_dist="${src}/e-voting/voter-portal/target/dist/apps/voter-portal"

    # -----------------------------------------------------------------------
    # Helper: resolve a glob pattern to exactly one file.
    # Prints the resolved path. Exits with a warning if zero or multiple match.
    # -----------------------------------------------------------------------
    resolve_one() {
        local -a matches=( $1 )
        if   (( ${#matches[@]} == 0 )); then echo "    WARN: no file matched: $1" >&2; return 1
        elif (( ${#matches[@]} >  1 )); then echo "    WARN: multiple files matched: $1" >&2; return 1
        fi
        echo "${matches[0]}"
    }

    # -----------------------------------------------------------------------
    # Helper: extract the version number (e.g. "1.5.4.2") from a filename.
    # -----------------------------------------------------------------------
    version_of() {
        local name
        name=$(basename "$1")
        if [[ "$name" =~ ([0-9]+(\.[0-9]+)+) ]]; then echo "${BASH_REMATCH[1]}"; else echo "?"; fi
    }

    # -----------------------------------------------------------------------
    # Compute all hashes upfront and store them in named variables so that
    # both output sections can reference the same values without recomputing.
    #
    # For each artefact:
    #   file_<id>   – resolved path on disk
    #   name_<id>   – basename (actual filename incl. version number)
    #   ver_<id>    – version string extracted from the filename
    #   h256_<id>   – SHA-256 hex digest
    #
    # For voter-portal JS files that also need SHA-384:
    #   h384_<id>   – SHA-384 Base64 digest (single line)
    # -----------------------------------------------------------------------

    # Macro-style helper: resolve, then populate the three derived variables.
    # Usage: load <id> <glob-pattern>
    load() {
        local id="$1" pattern="$2"
        local path
        path=$(resolve_one "$pattern") || return
        printf -v "file_${id}" '%s' "$path"
        printf -v "name_${id}" '%s' "$(basename "$path")"
        printf -v "ver_${id}"  '%s' "$(version_of "$path")"
        printf -v "h256_${id}" '%s' "$(sha256sum "$path" | awk '{print $1}')"
    }

    # Macro-style helper: also compute SHA-384 for a voter-portal JS file.
    # Usage: load_js <id> <filepath>
    load_js() {
        local id="$1" path="$2"
        printf -v "file_${id}" '%s' "$path"
        printf -v "name_${id}" '%s' "$(basename "$path")"
        printf -v "ver_${id}"  '%s' "$(version_of "$path")"
        printf -v "h256_${id}" '%s' "$(sha256sum "$path" | awk '{print $1}')"
        printf -v "h384_${id}" '%s' "$(openssl dgst -sha384 -binary "$path" | openssl enc -base64 -A)"
    }

    # --- Versioned artefacts (SHA-256 only) ---
    load cc    "${src}/e-voting/control-component/target/control-component-*runnable.jar"
    load dtt   "${src}/e-voting/tools/direct-trust-tool/direct-trust-tool-package/target/direct-trust-tool-*.zip"
    load dr    "${src}/e-voting/tools/dispute-resolver/target/dispute-resolver-*runnable.jar"
    load fc    "${src}/e-voting/tools/file-cryptor/target/file-cryptor-*runnable.jar"
    load sdm   "${src}/e-voting/secure-data-manager/secure-data-manager-packaging/target/*secure-data-manager-*.zip"
    load vp    "${src}/e-voting/voter-portal/target/voter-portal-*.zip"
    load vs    "${src}/e-voting/voting-server/target/voting-server*runnable.jar"
    load xs    "${src}/e-voting/tools/xml-signature/target/xml-signature-*runnable.jar"
    load dis   "${src}/data-integration-service/target/data-integration-service*.zip"
    load pvs   "${src}/pdf-verification-service/pdf-verification-service-package/target/pdf-verification-service*.zip"
    load va    "${src}/verifier/verifier-assembly/target/verifier-assembly*.zip"

    # --- Voter-portal dist files (SHA-256 + SHA-384, except index.html SHA-256 only) ---
    # The version for these files is taken from the parent voter-portal ZIP.
    local vp_version="${ver_vp:-?}"
    load_js api    "${vp_dist}/crypto.ov-api.js"
    load_js worker "${vp_dist}/crypto.ov-worker.js"
    load_js idx    "${vp_dist}/index.html"
    load_js main   "${vp_dist}/main.js"
    load_js poly   "${vp_dist}/polyfills.js"
    load_js rt     "${vp_dist}/runtime.js"

    # -----------------------------------------------------------------------
    # Write report
    # -----------------------------------------------------------------------
    {
        echo "Hash Report – ${timestamp}"
        echo "E-Voting-System Release ${EV_RELEASE}"
        echo "Canton:  ${CANTON}"
        echo "System:  $(uname -a)"
        echo "========================================"
        echo

        # -------------------------------------------------------------------
        # Section 1a – SHA-256 plain table
        # Order matches the SHA-256 table in the protocol Word document:
        # versioned artefacts first, then voter-portal dist files.
        # Format: "<hash>  <filename>"  (two spaces, same as sha256sum output)
        # -------------------------------------------------------------------
 
        echo "----- SHA-256 hashes -----"
        echo
        echo "${h256_cc}  ${name_cc}"
        echo "${h256_dtt}  ${name_dtt}"
        echo "${h256_dr}  ${name_dr}"
        echo "${h256_fc}  ${name_fc}"
        echo "${h256_sdm}  ${name_sdm}"
        echo "${h256_vp}  ${name_vp}"
        echo "${h256_api}  crypto.ov-api.js"
        echo "${h256_worker}  crypto.ov-worker.js"
        echo "${h256_idx}  index.html"
        echo "${h256_main}  main.js"
        echo "${h256_poly}  polyfills.js"
        echo "${h256_rt}  runtime.js"
        echo "${h256_vs}  ${name_vs}"
        echo "${h256_xs}  ${name_xs}"
        echo "${h256_dis}  ${name_dis}"
        echo "${h256_pvs}  ${name_pvs}"
        echo "${h256_va}  ${name_va}"
        echo

        # -------------------------------------------------------------------
        # Section 1b – SHA-384 plain table (voter-portal JS files only)
        # Order matches the SHA-384 table in the protocol Word document.
        # index.html is intentionally omitted (no SHA-384 required).
        # -------------------------------------------------------------------
        echo "----- SHA-384 hashes (voter-portal JavaScript files, Base64) -----"
        echo
        echo "${h384_api}  crypto.ov-api.js"
        echo "${h384_worker}  crypto.ov-worker.js"
        echo "${h384_main}  main.js"
        echo "${h384_poly}  polyfills.js"
        echo "${h384_rt}  runtime.js"
        echo

       # -------------------------------------------------------------------
        # Section 1c – SHA-256 plain table
        # Order matches the SHA-256 table in the protocol Word document:
        # versioned artefacts first, then voter-portal dist files.
        # Format: "<filename>"
        # -------------------------------------------------------------------
 
        echo "----- filenames -----"
        echo
        echo "${name_cc}"
        echo "${name_dtt}"
        echo "${name_dr}"
        echo "${name_fc}"
        echo "${name_sdm}"
        echo "${name_vp}"
        echo "crypto.ov-api.js"
        echo "crypto.ov-worker.js"
        echo "index.html"
        echo "main.js"
        echo "polyfills.js"
        echo "runtime.js"
        echo "${name_vs}"
        echo "${name_xs}"
        echo "${name_dis}"
        echo "${name_pvs}"
        echo "${name_va}"
        echo
        echo "crypto.ov-api.js"
        echo "crypto.ov-worker.js"
        echo "main.js"
        echo "polyfills.js"
        echo "runtime.js"
		echo
      
	  # -------------------------------------------------------------------
        # Section 1d – SHA-256 plain table
        # Order matches the SHA-256 table in the protocol Word document:
        # versioned artefacts first, then voter-portal dist files.
        # Format: "<hash>"
        # -------------------------------------------------------------------
 
        echo "----- SHA-256 / SHA-384 hashes -----"
        echo
        echo "${h256_cc}"
        echo "${h256_dtt}"
        echo "${h256_dr}"
        echo "${h256_fc}"
        echo "${h256_sdm}"
        echo "${h256_vp}"
        echo "${h256_api}"
        echo "${h256_worker}"
        echo "${h256_idx}"
        echo "${h256_main}"
        echo "${h256_poly}"
        echo "${h256_rt}"
        echo "${h256_vs}"
        echo "${h256_xs}"
        echo "${h256_dis}"
        echo "${h256_pvs}"
        echo "${h256_va}"
        echo
        echo "${h384_api}"
        echo "${h384_worker}"
        echo "${h384_main}"
        echo "${h384_poly}"
        echo "${h384_rt}"		
		echo
		echo


        # -------------------------------------------------------------------
        # Section 2 – Markdown table
        # The voter-portal ZIP is listed first, followed immediately by its
        # dist files as sub-items (prefixed "-->"). Each JS file appears twice:
        # SHA-256 row first, SHA-384 row second. index.html: SHA-256 only.
        # -------------------------------------------------------------------
        echo "----- Markdown table -----"
        echo
        echo "| Artefact | Version | Checksum |"
        echo "|---|---|---|"
        echo "| **${name_cc}** | ${ver_cc} | ${h256_cc} |"
        echo "| **${name_dtt}** | ${ver_dtt} | ${h256_dtt} |"
        echo "| **${name_dr}** | ${ver_dr} | ${h256_dr} |"
        echo "| **${name_fc}** | ${ver_fc} | ${h256_fc} |"
        echo "| **${name_sdm}** | ${ver_sdm} | ${h256_sdm} |"
        echo "| **${name_vp}** | ${ver_vp} | ${h256_vp} |"
        echo "| --> crypto.ov-api.js | ${vp_version} | ${h256_api} |"
        echo "| --> crypto.ov-api.js | ${vp_version} | ${h384_api} |"
        echo "| --> crypto.ov-worker.js | ${vp_version} | ${h256_worker} |"
        echo "| --> crypto.ov-worker.js | ${vp_version} | ${h384_worker} |"
        echo "| --> index.html | ${vp_version} | ${h256_idx} |"
        echo "| --> main.js | ${vp_version} | ${h256_main} |"
        echo "| --> main.js | ${vp_version} | ${h384_main} |"
        echo "| --> polyfills.js | ${vp_version} | ${h256_poly} |"
        echo "| --> polyfills.js | ${vp_version} | ${h384_poly} |"
        echo "| --> runtime.js | ${vp_version} | ${h256_rt} |"
        echo "| --> runtime.js | ${vp_version} | ${h384_rt} |"
        echo "| **${name_vs}** | ${ver_vs} | ${h256_vs} |"
        echo "| **${name_xs}** | ${ver_xs} | ${h256_xs} |"
        echo "| **${name_dis}** | ${ver_dis} | ${h256_dis} |"
        echo "| **${name_pvs}** | ${ver_pvs} | ${h256_pvs} |"
        echo "| **${name_va}** | ${ver_va} | ${h256_va} |"
        echo

    } > "$report"

    echo "    Report written to: ${report}"
    echo "    Done."
}

# ---------------------------------------------------------------------------
# Private helpers (not listed in the menu)
# ---------------------------------------------------------------------------

# Create the expected directory structure under EVOTING_FOLDER.
_create_directories() {
    mkdir -p \
        "${EVOTING_SOURCE}" \
        "${EVOTING_FOLDER}/tools/java" \
        "${EVOTING_FOLDER}/tools/maven" \
        "${EVOTING_FOLDER}/tools/node"
}

# Export environment variables that point to the project-local tools.
# Also extends PATH for the current shell session.
_set_environment() {
    export JAVA_HOME="${EVOTING_FOLDER}/tools/java"
    export NODE_HOME="${EVOTING_FOLDER}/tools/node"
    export MAVEN_HOME="${EVOTING_FOLDER}/tools/maven"
    export EVOTING_HOME="${EVOTING_SOURCE}"
    export DOCKER_REGISTRY="${DOCKER_REGISTRY}"
    export WINEPREFIX="${EVOTING_FOLDER}/tools/wineprefix"
    path_append "${JAVA_HOME}/bin" "${MAVEN_HOME}/bin" "${NODE_HOME}" "${NODE_HOME}/bin"
}
# Ensures the wineprefix exists and matches the installed Wine version.
# After a system Wine update the prefix must be migrated, otherwise the
# secure-data-manager Windows package build fails. wineboot -u performs the
# same migration winecfg triggers implicitly, but non-interactively.
# Edge case: creating a *fresh* prefix is only silent if wine-mono is
# available system-wide; otherwise Wine shows an interactive Mono dialog.
_ensure_wine_prefix() {
    if [[ ! -d "${WINEPREFIX}" ]] \
        && ! ls /usr/share/wine/mono/* &>/dev/null \
        && ! ls "${HOME}/.cache/wine/wine-mono-"* &>/dev/null; then
        echo "    Warning: wine-mono not found system-wide. Initial prefix" >&2
        echo "    creation may show an interactive Mono install dialog." >&2
    fi
    echo "    Updating wineprefix..."
    WINEDEBUG=-all wineboot -u &>/dev/null \
        || log_error "${BASH_LINENO[0]}" "$?"
    wineserver -w
}

# ---------------------------------------------------------------------------
# Main – interactive step selection
# ---------------------------------------------------------------------------

main() {
    echo
    echo "======================================================"
    echo "  E-Voting Build & Verification Script (v${EV_RELEASE})"
    echo "======================================================"
    echo
    echo "Select one or more steps to execute."
    echo "Enter the step numbers without spaces (e.g. '456'),"
    echo "or enter '0' to run all steps in sequence."
    echo

    local steps=(
        "clean_system"
        "install_prerequisites"
        "download_tools"
        "clone_repositories"
        "compile_projects"
        "generate_hashes"
    )

    local descriptions=(
        "Clean build caches and local tool/source folders"
        "Install Docker and Wine via the system package manager"
        "Download JDK, Node.js, and Maven into tools folder"
        "Clone all source repositories from GitLab"
        "Compile all projects in dependency order"
        "Generate SHA-256/SHA-384 hash report"
    )

    for (( i = 0; i < ${#steps[@]}; i++ )); do
        printf "  %d. %-30s %s\n" "$((i+1))" "${steps[$i]}" "${descriptions[$i]}"
    done
    echo

    read -rp "Your choice: " input

    # Strip everything that is not a digit
    local digits="${input//[^0-9]/}"

    local selected=()
    if [[ "$digits" == "0" ]]; then
        selected=( "${steps[@]}" )
    else
        for (( i = 0; i < ${#digits}; i++ )); do
            local idx=$(( ${digits:$i:1} - 1 ))
            if (( idx >= 0 && idx < ${#steps[@]} )); then
                selected+=( "${steps[$idx]}" )
            else
                echo "WARNING: '${digits:$i:1}' is not a valid step number – ignored." >&2
            fi
        done
    fi

    if (( ${#selected[@]} == 0 )); then
        echo "No valid steps selected. Exiting."
        exit 0
    fi

    echo
    echo "Running: ${selected[*]}"
    echo

    for func in "${selected[@]}"; do
        # Ensure directories and environment are ready for steps that need them
        case "$func" in
            clone_repositories|compile_projects|generate_hashes)
                _create_directories
                _set_environment
                ;;
            download_tools)
                _create_directories
                ;;
        esac
        "$func"
        echo
    done

    echo "All selected steps completed."
}
mkdir -p "${EVOTING_FOLDER}"
exec > >(tee -a "${LOG_FILE}") 2>&1
main
