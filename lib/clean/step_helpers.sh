#!/bin/bash
# Mole - Clean step helpers used by the machine-readable registry.

set -euo pipefail

if [[ -n "${MOLE_CLEAN_STEP_HELPERS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_CLEAN_STEP_HELPERS_LOADED=1

clean_system_caches_step() {
    local cache_cleaned=0
    if sudo test -d "/Library/Caches" 2> /dev/null; then
        while IFS= read -r -d '' file; do
            if should_protect_path "$file"; then
                continue
            fi
            if safe_sudo_remove "$file"; then
                cache_cleaned=1
            fi
        done < <(sudo find "/Library/Caches" -maxdepth 5 -type f \( \
            \( -name "*.cache" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.tmp" -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" \) -o \
            \( -name "*.log" -mtime "+$MOLE_LOG_AGE_DAYS" \) \
            \) -print0 2> /dev/null || true)
    fi
    [[ $cache_cleaned -eq 1 ]] && log_success "System caches"
}

clean_system_temp_files_step() {
    local tmp_cleaned=0
    local -a sys_temp_dirs=("/private/tmp" "/private/var/tmp")
    local tmp_dir
    for tmp_dir in "${sys_temp_dirs[@]}"; do
        if sudo find "$tmp_dir" -maxdepth 1 -type f -mtime "+${MOLE_TEMP_FILE_AGE_DAYS}" -print -quit 2> /dev/null | grep -q .; then
            if safe_sudo_find_delete "$tmp_dir" "*" "${MOLE_TEMP_FILE_AGE_DAYS}" "f"; then
                tmp_cleaned=1
            fi
        fi
    done
    [[ $tmp_cleaned -eq 1 ]] && log_success "System temp files"
}

clean_system_crash_reports_step() {
    if sudo find "/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -mtime "+$MOLE_CRASH_REPORT_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/Library/Logs/DiagnosticReports" "*" "$MOLE_CRASH_REPORT_AGE_DAYS" "f" || true
    fi
    log_success "System crash reports"
}

clean_system_logs_step() {
    if sudo find "/private/var/log" -maxdepth 3 -type f \( -name "*.log" -o -name "*.gz" -o -name "*.asl" \) -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        safe_sudo_find_delete "/private/var/log" "*.log" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.gz" "$MOLE_LOG_AGE_DAYS" "f" || true
        safe_sudo_find_delete "/private/var/log" "*.asl" "$MOLE_LOG_AGE_DAYS" "f" || true
    fi
    log_success "System logs"
}

clean_system_third_party_logs_step() {
    local -a third_party_log_dirs=(
        "/Library/Logs/Adobe"
        "/Library/Logs/CreativeCloud"
    )
    local third_party_logs_cleaned=0
    local third_party_log_dir=""
    for third_party_log_dir in "${third_party_log_dirs[@]}"; do
        if sudo test -d "$third_party_log_dir" 2> /dev/null; then
            if sudo find "$third_party_log_dir" -maxdepth 5 -type f -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
                if safe_sudo_find_delete "$third_party_log_dir" "*" "$MOLE_LOG_AGE_DAYS" "f"; then
                    third_party_logs_cleaned=1
                fi
            fi
        fi
    done
    if sudo find "/Library/Logs" -maxdepth 1 -type f -name "adobegc.log" -mtime "+$MOLE_LOG_AGE_DAYS" -print -quit 2> /dev/null | grep -q .; then
        if safe_sudo_remove "/Library/Logs/adobegc.log"; then
            third_party_logs_cleaned=1
        fi
    fi
    [[ $third_party_logs_cleaned -eq 1 ]] && log_success "Third-party system logs"
}

clean_system_updates_step() {
    if [[ -d "/Library/Updates" && ! -L "/Library/Updates" ]]; then
        local updates_cleaned=0
        while IFS= read -r -d '' item; do
            if [[ -z "$item" ]] || [[ ! "$item" =~ ^/Library/Updates/[^/]+$ ]]; then
                debug_log "Skipping malformed path: $item"
                continue
            fi
            local item_flags
            item_flags=$($STAT_BSD -f%Sf "$item" 2> /dev/null || echo "")
            if [[ "$item_flags" == *"restricted"* ]]; then
                continue
            fi
            if safe_sudo_remove "$item"; then
                updates_cleaned=$((updates_cleaned + 1))
            fi
        done < <(find /Library/Updates -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        [[ $updates_cleaned -gt 0 ]] && log_success "System library updates"
    fi
}

clean_system_installers_step() {
    if [[ -d "/macOS Install Data" ]]; then
        local mtime
        mtime=$(get_file_mtime "/macOS Install Data")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        if [[ $age_days -ge 14 ]]; then
            local size_kb
            size_kb=$(get_path_size_kb "/macOS Install Data")
            if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
                local size_human
                size_human=$(bytes_to_human "$((size_kb * 1024))")
                if safe_sudo_remove "/macOS Install Data"; then
                    log_success "macOS Install Data, $size_human"
                fi
            fi
        fi
    fi

    local installer_cleaned=0
    local current_macos_version=""
    current_macos_version=$(sw_vers -productVersion 2> /dev/null | cut -d. -f1 || true)
    local installer_app
    for installer_app in /Applications/Install\ macOS*.app; do
        [[ -d "$installer_app" ]] || continue
        local app_name
        app_name=$(basename "$installer_app")
        if pgrep -f "$installer_app" > /dev/null 2>&1; then
            continue
        fi
        if [[ -n "$current_macos_version" ]]; then
            local installer_plist="$installer_app/Contents/Info.plist"
            if [[ -f "$installer_plist" ]]; then
                local installer_version=""
                installer_version=$(/usr/libexec/PlistBuddy -c "Print :DTPlatformVersion" "$installer_plist" 2> /dev/null | cut -d. -f1 || true)
                if [[ -n "$installer_version" && "$installer_version" == *"$current_macos_version"* ]]; then
                    continue
                fi
            fi
        fi
        local mtime
        mtime=$(get_file_mtime "$installer_app")
        local age_days=$((($(get_epoch_seconds) - mtime) / 86400))
        [[ $age_days -lt 14 ]] && continue
        local size_kb
        size_kb=$(get_path_size_kb "$installer_app")
        if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            if safe_sudo_remove "$installer_app"; then
                installer_cleaned=1
                log_success "$app_name, $size_human"
            fi
        fi
    done
    [[ $installer_cleaned -eq 1 ]] || true
}

clean_user_library_caches_step() {
    safe_clean ~/Library/Caches/* "User app cache"
}

clean_user_library_logs_step() {
    safe_clean ~/Library/Logs/* "User app logs"
}

clean_user_trash_step() {
    if is_path_whitelisted "$HOME/.Trash"; then
        return 0
    fi

    local trash_count
    local trash_count_status=0
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        trash_count=$(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null | tr -dc '\0' | wc -c | tr -d ' ' || echo "0")
    else
        trash_count=$(run_with_timeout 3 osascript -e 'tell application "Finder" to count items in trash' 2> /dev/null) || trash_count_status=$?
    fi
    if [[ $trash_count_status -eq 124 ]]; then
        trash_count=$(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null | tr -dc '\0' | wc -c | tr -d ' ' || echo "0")
    fi
    [[ "$trash_count" =~ ^[0-9]+$ ]] || trash_count="0"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ $trash_count -gt 0 ]]; then
            mole_machine_candidate_found "logical:user.trash" "Trash" "logical" "empty_trash" "$HOME/.Trash" "~/.Trash" "directory" 0 "$trash_count" "" '{}'
            mole_machine_item_result "logical:user.trash" "Trash" "would_clean" 0 "$trash_count" "" 0
        fi
        return 0
    fi

    if [[ $trash_count -le 0 ]]; then
        return 0
    fi

    local emptied_via_finder=false
    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
        if run_with_timeout 5 osascript -e 'tell application "Finder" to empty trash' > /dev/null 2>&1; then
            emptied_via_finder=true
            note_activity
        fi
    fi
    if [[ "$emptied_via_finder" != "true" ]]; then
        local cleaned_count=0
        while IFS= read -r -d '' item; do
            if safe_remove "$item" true; then
                cleaned_count=$((cleaned_count + 1))
            fi
        done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        if [[ $cleaned_count -gt 0 ]]; then
            note_activity
        fi
    fi
}

clean_user_recent_items_step() {
    _clean_recent_items
}

clean_user_mail_downloads_step() {
    _clean_mail_downloads
}

clean_app_caches_macos_common_step() {
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states" || true
    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache" || true
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache" || true
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache" || true
    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports" || true
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails" || true
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache" || true
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache" || true
    _clean_incomplete_downloads
    safe_clean ~/Library/Autosave\ Information/* "Autosave information" || true
    safe_clean ~/Library/IdentityCaches/* "Identity caches" || true
    safe_clean ~/Library/Suggestions/* "Siri suggestions cache" || true
    safe_clean ~/Library/Calendars/Calendar\ Cache "Calendar cache" || true
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache" || true
}

clean_app_caches_support_data_step() {
    clean_support_app_data
}

clean_app_caches_sandboxed_containers_step() {
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/tmp/* "Media analysis temp files"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"
    safe_clean ~/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp/* "Wallpaper aerials temp files"
    safe_clean ~/Library/Containers/com.apple.geod/Data/tmp/* "Geod temp files"
    safe_clean ~/Library/Containers/com.apple.stocks/Data/Library/Caches/* "Stocks cache"
    safe_clean ~/Library/Application\ Support/com.apple.wallpaper/aerials/thumbnails/* "Wallpaper aerials thumbnails"
    local containers_dir="$HOME/Library/Containers"
    [[ ! -d "$containers_dir" ]] && return 0

    local total_size=0
    local total_size_partial=false
    local cleaned_count=0
    local found_any=false
    local precise_size_limit="${MOLE_CONTAINER_CACHE_PRECISE_SIZE_LIMIT:-64}"
    [[ "$precise_size_limit" =~ ^[0-9]+$ ]] || precise_size_limit=64
    local precise_size_used=0

    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    local container_dir
    for container_dir in "$containers_dir"/*; do
        process_container_cache "$container_dir"
    done
    eval "$_ng_state"

    if [[ "$found_any" == "true" ]]; then
        files_cleaned=$((files_cleaned + cleaned_count))
        total_size_cleaned=$((total_size_cleaned + total_size))
        total_items=$((total_items + 1))
        note_activity
    fi
}

clean_browser_safari_step() {
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"
}

clean_browser_chrome_family_step() {
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/component_crx_cache/* "Chrome component CRX cache"
    local chrome_profile
    for chrome_profile in "$HOME/Library/Application Support/Google/Chrome"/*/; do
        clean_service_worker_cache "Chrome" "$chrome_profile/Service Worker/CacheStorage"
        safe_clean "$chrome_profile"/Service\ Worker/ScriptCache/* "Chrome Service Worker ScriptCache"
    done
    safe_clean ~/Library/Application\ Support/Google/GoogleUpdater/crx_cache/* "GoogleUpdater CRX cache"
    safe_clean ~/Library/Application\ Support/Google/GoogleUpdater/*.old "GoogleUpdater old files"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"
    safe_clean ~/.cache/puppeteer/* "Puppeteer browser cache"
}

clean_browser_edge_family_step() {
    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
}

clean_browser_brave_family_step() {
    safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/Application\ Cache/* "Brave app cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/*/GPUCache/* "Brave GPU cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/component_crx_cache/* "Brave component CRX cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/ShaderCache/* "Brave shader cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/GrShaderCache/* "Brave GR shader cache"
    safe_clean ~/Library/Application\ Support/BraveSoftware/Brave-Browser/GraphiteDawnCache/* "Brave Dawn cache"
}

clean_browser_firefox_step() {
    local firefox_running=false
    if pgrep -x "Firefox" > /dev/null 2>&1; then
        firefox_running=true
    fi
    if [[ "$firefox_running" == "true" ]]; then
        mole_machine_candidate_skipped "logical:browsers.firefox" "Firefox caches" "app_running" "Firefox is running; cache cleanup skipped."
        return 0
    fi
    safe_clean ~/Library/Caches/Firefox/* "Firefox cache"
    safe_clean ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache"
}

clean_browser_other_step() {
    safe_clean ~/Library/Application\ Support/net.imput.helium/*/GPUCache/* "Helium GPU cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/component_crx_cache/* "Helium component cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/extensions_crx_cache/* "Helium extensions cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/GrShaderCache/* "Helium shader cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/GraphiteDawnCache/* "Helium Dawn cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/ShaderCache/* "Helium shader cache"
    safe_clean ~/Library/Application\ Support/net.imput.helium/*/Application\ Cache/* "Helium app cache"
    safe_clean ~/Library/Caches/net.imput.helium/* "Helium cache"
    safe_clean ~/Library/Caches/Yandex/YandexBrowser/* "Yandex cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/ShaderCache/* "Yandex shader cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GrShaderCache/* "Yandex GR shader cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GraphiteDawnCache/* "Yandex Dawn cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/*/GPUCache/* "Yandex GPU cache"
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
}

clean_browser_old_versions_step() {
    clean_chrome_old_versions
    clean_edge_old_versions
    clean_edge_updater_old_versions
    clean_brave_old_versions
}

clean_office_microsoft_step() {
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/Library/Caches/* "Microsoft Word container cache"
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/tmp/* "Microsoft Word temp files"
    safe_clean ~/Library/Containers/com.microsoft.Word/Data/Library/Logs/* "Microsoft Word container logs"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/Library/Caches/* "Microsoft Excel container cache"
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/tmp/* "Microsoft Excel temp files"
    safe_clean ~/Library/Containers/com.microsoft.Excel/Data/Library/Logs/* "Microsoft Excel container logs"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
}

clean_office_apple_and_other_step() {
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
}

clean_dev_homebrew_step() {
    safe_clean ~/Library/Caches/Homebrew/* "Homebrew cache"
    local brew_lock_dirs=(
        "/opt/homebrew/var/homebrew/locks"
        "/usr/local/var/homebrew/locks"
    )
    local lock_dir
    for lock_dir in "${brew_lock_dirs[@]}"; do
        if [[ -d "$lock_dir" && -w "$lock_dir" ]]; then
            safe_clean "$lock_dir"/* "Homebrew lock files"
        elif [[ -d "$lock_dir" ]]; then
            if find "$lock_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                debug_log "Skipping read-only Homebrew locks in $lock_dir"
            fi
        fi
    done
    clean_homebrew
}

clean_virtualization_vmware_step() {
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
}

clean_virtualization_parallels_step() {
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
}

clean_virtualization_virtualbox_step() {
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
}

clean_virtualization_vagrant_step() {
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
}

clean_external_volume_target_step() {
    [[ -n "${EXTERNAL_VOLUME_TARGET:-}" ]] || return 0
    clean_external_volume_target "$EXTERNAL_VOLUME_TARGET"
}
