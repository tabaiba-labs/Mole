#!/bin/bash
# Mole - Clean step registry for machine-readable orchestration.

set -euo pipefail

if [[ -n "${MOLE_CLEAN_REGISTRY_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_CLEAN_REGISTRY_LOADED=1

declare -a MOLE_CLEAN_SECTION_ORDER=()
declare -a MOLE_CLEAN_SECTION_DEFS=()
declare -a MOLE_CLEAN_STEP_DEFS=()

register_clean_section() {
    local section_id="$1"
    local label="$2"
    MOLE_CLEAN_SECTION_ORDER+=("$section_id")
    MOLE_CLEAN_SECTION_DEFS+=("$section_id|$label")
}

register_clean_step() {
    local step_id="$1"
    local section_id="$2"
    local label="$3"
    local function_name="$4"
    local kind="$5"
    local required_caps="$6"
    local recommended_caps="$7"
    local scope="$8"
    MOLE_CLEAN_STEP_DEFS+=("$step_id|$section_id|$label|$function_name|$kind|$required_caps|$recommended_caps|$scope")
}

clean_registry_init() {
    [[ ${#MOLE_CLEAN_STEP_DEFS[@]} -gt 0 ]] && return 0

    register_clean_section "system" "System"
    register_clean_section "user_essentials" "User essentials"
    register_clean_section "app_caches" "App caches"
    register_clean_section "browsers" "Browsers"
    register_clean_section "cloud_office" "Cloud & Office"
    register_clean_section "developer_tools" "Developer tools"
    register_clean_section "applications" "Applications"
    register_clean_section "virtualization" "Virtualization"
    register_clean_section "application_support" "Application Support"
    register_clean_section "orphaned_data" "Orphaned data"
    register_clean_section "apple_silicon" "Apple Silicon"
    register_clean_section "device_backups" "Device backups"
    register_clean_section "time_machine" "Time Machine"
    register_clean_section "large_files" "Large files"
    register_clean_section "system_data_clues" "System Data clues"
    register_clean_section "project_artifacts" "Project artifacts"
    register_clean_section "external_volume" "External volume"

    register_clean_step "system.caches" "system" "System caches" "clean_system_caches_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.temp_files" "system" "System temp files" "clean_system_temp_files_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.crash_reports" "system" "System crash reports" "clean_system_crash_reports_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.logs" "system" "System logs" "clean_system_logs_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.third_party_logs" "system" "Third-party system logs" "clean_system_third_party_logs_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.updates" "system" "System updates" "clean_system_updates_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.installers" "system" "System installers" "clean_system_installers_step" "cleanup" "sudo.session" "" "system"
    register_clean_step "system.local_snapshots" "system" "Local snapshots" "clean_local_snapshots" "cleanup" "sudo.session" "tool.tmutil" "system"

    register_clean_step "user.library_caches" "user_essentials" "User app cache" "clean_user_library_caches_step" "cleanup" "" "" "user"
    register_clean_step "user.library_logs" "user_essentials" "User app logs" "clean_user_library_logs_step" "cleanup" "" "" "user"
    register_clean_step "user.trash" "user_essentials" "Trash" "clean_user_trash_step" "cleanup" "" "automation.finder" "user"
    register_clean_step "user.recent_items" "user_essentials" "Recent items" "clean_user_recent_items_step" "cleanup" "" "" "user"
    register_clean_step "user.mail_downloads" "user_essentials" "Mail downloads" "clean_user_mail_downloads_step" "cleanup" "" "full_disk_access" "user"
    register_clean_step "user.finder_metadata" "user_essentials" "Finder metadata" "clean_finder_metadata" "cleanup" "" "" "user"

    register_clean_step "app_caches.macos_common" "app_caches" "macOS common caches" "clean_app_caches_macos_common_step" "cleanup" "" "full_disk_access" "user"
    register_clean_step "app_caches.support_app_data" "app_caches" "Support app data" "clean_app_caches_support_data_step" "cleanup" "" "full_disk_access" "user"
    register_clean_step "app_caches.sandboxed_containers" "app_caches" "Sandboxed app caches" "clean_app_caches_sandboxed_containers_step" "cleanup" "" "access.containers" "user"
    register_clean_step "app_caches.group_containers" "app_caches" "Group container caches" "clean_group_container_caches" "cleanup" "" "access.group_containers" "user"

    register_clean_step "browsers.safari" "browsers" "Safari caches" "clean_browser_safari_step" "cleanup" "" "" "user"
    register_clean_step "browsers.chrome_family" "browsers" "Chrome-family caches" "clean_browser_chrome_family_step" "cleanup" "" "access.browser_profiles" "user"
    register_clean_step "browsers.edge_family" "browsers" "Edge-family caches" "clean_browser_edge_family_step" "cleanup" "" "access.browser_profiles" "user"
    register_clean_step "browsers.brave_family" "browsers" "Brave-family caches" "clean_browser_brave_family_step" "cleanup" "" "access.browser_profiles" "user"
    register_clean_step "browsers.firefox" "browsers" "Firefox caches" "clean_browser_firefox_step" "cleanup" "" "access.browser_profiles" "user"
    register_clean_step "browsers.other" "browsers" "Other browser caches" "clean_browser_other_step" "cleanup" "" "access.browser_profiles" "user"
    register_clean_step "browsers.old_versions" "browsers" "Old browser versions" "clean_browser_old_versions_step" "cleanup" "" "" "user"

    register_clean_step "cloud_storage.caches" "cloud_office" "Cloud storage caches" "clean_cloud_storage" "cleanup" "" "" "user"
    register_clean_step "office.microsoft" "cloud_office" "Microsoft Office caches" "clean_office_microsoft_step" "cleanup" "" "" "user"
    register_clean_step "office.apple_and_other" "cloud_office" "Apple and other Office caches" "clean_office_apple_and_other_step" "cleanup" "" "" "user"

    register_clean_step "dev.sqlite_temp" "developer_tools" "SQLite temp files" "clean_sqlite_temp_files" "cleanup" "" "" "user"
    register_clean_step "dev.node_tooling" "developer_tools" "Node tooling caches" "clean_dev_npm" "cleanup" "" "" "user"
    register_clean_step "dev.python_tooling" "developer_tools" "Python tooling caches" "clean_dev_python" "cleanup" "" "" "user"
    register_clean_step "dev.go_tooling" "developer_tools" "Go tooling caches" "clean_dev_go" "cleanup" "" "" "user"
    register_clean_step "dev.mise" "developer_tools" "mise cache" "clean_dev_mise" "cleanup" "" "" "user"
    register_clean_step "dev.rust_tooling" "developer_tools" "Rust tooling caches" "clean_dev_rust" "cleanup" "" "" "user"
    register_clean_step "dev.rust_toolchain_versions" "developer_tools" "Rust toolchain versions" "check_rust_toolchains" "check" "" "" "user"
    register_clean_step "dev.docker" "developer_tools" "Docker caches" "clean_dev_docker" "cleanup" "" "" "user"
    register_clean_step "dev.cloud" "developer_tools" "Cloud tooling caches" "clean_dev_cloud" "cleanup" "" "" "user"
    register_clean_step "dev.nix" "developer_tools" "Nix caches" "clean_dev_nix" "cleanup" "" "" "user"
    register_clean_step "dev.shell" "developer_tools" "Shell caches" "clean_dev_shell" "cleanup" "" "" "user"
    register_clean_step "dev.frontend" "developer_tools" "Frontend tooling caches" "clean_dev_frontend" "cleanup" "" "" "user"
    register_clean_step "dev.project_caches" "developer_tools" "Project caches" "clean_project_caches" "cleanup" "" "" "user"
    register_clean_step "dev.mobile" "developer_tools" "Mobile tooling caches" "clean_dev_mobile" "cleanup" "" "" "user"
    register_clean_step "dev.jvm" "developer_tools" "JVM caches" "clean_dev_jvm" "cleanup" "" "" "user"
    register_clean_step "dev.jetbrains_toolbox" "developer_tools" "JetBrains Toolbox" "clean_dev_jetbrains_toolbox" "cleanup" "" "" "user"
    register_clean_step "dev.other_langs" "developer_tools" "Other language caches" "clean_dev_other_langs" "cleanup" "" "" "user"
    register_clean_step "dev.cicd" "developer_tools" "CI/CD caches" "clean_dev_cicd" "cleanup" "" "" "user"
    register_clean_step "dev.database" "developer_tools" "Database caches" "clean_dev_database" "cleanup" "" "" "user"
    register_clean_step "dev.api_tools" "developer_tools" "API tooling caches" "clean_dev_api_tools" "cleanup" "" "" "user"
    register_clean_step "dev.network" "developer_tools" "Network tooling caches" "clean_dev_network" "cleanup" "" "" "user"
    register_clean_step "dev.misc" "developer_tools" "Misc developer caches" "clean_dev_misc" "cleanup" "" "" "user"
    register_clean_step "dev.elixir" "developer_tools" "Elixir caches" "clean_dev_elixir" "cleanup" "" "" "user"
    register_clean_step "dev.haskell" "developer_tools" "Haskell caches" "clean_dev_haskell" "cleanup" "" "" "user"
    register_clean_step "dev.ocaml" "developer_tools" "OCaml caches" "clean_dev_ocaml" "cleanup" "" "" "user"
    register_clean_step "dev.xcode_tools" "developer_tools" "Xcode tools" "clean_xcode_tools" "cleanup" "" "" "user"
    register_clean_step "dev.code_editors" "developer_tools" "Code editors" "clean_code_editors" "cleanup" "" "" "user"
    register_clean_step "dev.homebrew" "developer_tools" "Homebrew caches" "clean_dev_homebrew_step" "cleanup" "" "" "user"

    register_clean_step "apps.communication" "applications" "Communication apps" "clean_communication_apps" "cleanup" "" "" "user"
    register_clean_step "apps.dingtalk" "applications" "DingTalk" "clean_dingtalk" "cleanup" "" "" "user"
    register_clean_step "apps.ai" "applications" "AI apps" "clean_ai_apps" "cleanup" "" "" "user"
    register_clean_step "apps.design" "applications" "Design apps" "clean_design_tools" "cleanup" "" "" "user"
    register_clean_step "apps.video_tools" "applications" "Video tools" "clean_video_tools" "cleanup" "" "" "user"
    register_clean_step "apps.three_d" "applications" "3D apps" "clean_3d_tools" "cleanup" "" "" "user"
    register_clean_step "apps.productivity" "applications" "Productivity apps" "clean_productivity_apps" "cleanup" "" "" "user"
    register_clean_step "apps.media_players" "applications" "Media players" "clean_media_players" "cleanup" "" "" "user"
    register_clean_step "apps.video_players" "applications" "Video players" "clean_video_players" "cleanup" "" "" "user"
    register_clean_step "apps.download_managers" "applications" "Download managers" "clean_download_managers" "cleanup" "" "" "user"
    register_clean_step "apps.gaming_platforms" "applications" "Gaming platforms" "clean_gaming_platforms" "cleanup" "" "" "user"
    register_clean_step "apps.translation" "applications" "Translation apps" "clean_translation_apps" "cleanup" "" "" "user"
    register_clean_step "apps.screenshot" "applications" "Screenshot apps" "clean_screenshot_tools" "cleanup" "" "" "user"
    register_clean_step "apps.email_clients" "applications" "Email clients" "clean_email_clients" "cleanup" "" "" "user"
    register_clean_step "apps.task_apps" "applications" "Task apps" "clean_task_apps" "cleanup" "" "" "user"
    register_clean_step "apps.shell_utils" "applications" "Shell utilities" "clean_shell_utils" "cleanup" "" "" "user"
    register_clean_step "apps.system_utils" "applications" "System utilities" "clean_system_utils" "cleanup" "" "" "user"
    register_clean_step "apps.note_apps" "applications" "Note apps" "clean_note_apps" "cleanup" "" "" "user"
    register_clean_step "apps.launcher_apps" "applications" "Launcher apps" "clean_launcher_apps" "cleanup" "" "" "user"
    register_clean_step "apps.remote_desktop" "applications" "Remote desktop apps" "clean_remote_desktop" "cleanup" "" "" "user"

    register_clean_step "virtualization.vmware" "virtualization" "VMware caches" "clean_virtualization_vmware_step" "cleanup" "" "" "user"
    register_clean_step "virtualization.parallels" "virtualization" "Parallels caches" "clean_virtualization_parallels_step" "cleanup" "" "" "user"
    register_clean_step "virtualization.virtualbox" "virtualization" "VirtualBox caches" "clean_virtualization_virtualbox_step" "cleanup" "" "" "user"
    register_clean_step "virtualization.vagrant" "virtualization" "Vagrant temp files" "clean_virtualization_vagrant_step" "cleanup" "" "" "user"

    register_clean_step "app_support.logs_and_caches" "application_support" "Application Support logs and caches" "clean_application_support_logs" "cleanup" "" "full_disk_access" "user"

    register_clean_step "orphaned.app_data" "orphaned_data" "Orphaned app data" "clean_orphaned_app_data" "cleanup" "" "full_disk_access" "user"
    register_clean_step "orphaned.system_services" "orphaned_data" "Orphaned system services" "clean_orphaned_system_services" "cleanup" "sudo.session" "tool.mdfind" "system"
    register_clean_step "orphaned.user_launch_agent_hints" "orphaned_data" "User LaunchAgent hints" "show_user_launch_agent_hint_notice" "hint" "" "" "user"

    register_clean_step "apple_silicon.caches" "apple_silicon" "Apple Silicon caches" "clean_apple_silicon_caches" "cleanup" "" "" "user"
    register_clean_step "device_backups.ios" "device_backups" "iOS device backups" "check_ios_device_backups" "check" "" "" "user"
    register_clean_step "time_machine.failed_backups" "time_machine" "Time Machine failed backups" "clean_time_machine_failed_backups" "cleanup" "" "tool.tmutil" "user"
    register_clean_step "large_files.candidates" "large_files" "Large file candidates" "check_large_file_candidates" "scan" "" "" "user"
    register_clean_step "system_data.hints" "system_data_clues" "System Data hints" "show_system_data_hint_notice" "hint" "" "" "user"
    register_clean_step "project_artifacts.hints" "project_artifacts" "Project artifact hints" "show_project_artifact_hint_notice" "hint" "" "" "user"

    register_clean_step "external_volume.metadata_cleanup" "external_volume" "External volume metadata" "clean_external_volume_target_step" "cleanup" "" "tool.diskutil" "external"
}

clean_section_label() {
    local section_id="$1"
    local entry
    clean_registry_init
    for entry in "${MOLE_CLEAN_SECTION_DEFS[@]}"; do
        IFS='|' read -r current_id label <<< "$entry"
        if [[ "$current_id" == "$section_id" ]]; then
            printf '%s\n' "$label"
            return 0
        fi
    done
    printf '%s\n' "$section_id"
}

clean_step_record_by_id() {
    local step_id="$1"
    local entry
    clean_registry_init
    for entry in "${MOLE_CLEAN_STEP_DEFS[@]}"; do
        IFS='|' read -r current_id _rest <<< "$entry"
        if [[ "$current_id" == "$step_id" ]]; then
            printf '%s\n' "$entry"
            return 0
        fi
    done
    return 1
}

clean_step_selected_by_cli() {
    local step_id="$1"
    [[ -z "${MOLE_SELECTED_STEPS_CSV:-}" ]] && return 0

    local wanted
    local old_ifs="$IFS"
    IFS=','
    for wanted in ${MOLE_SELECTED_STEPS_CSV}; do
        if [[ "$wanted" == "$step_id" ]]; then
            IFS="$old_ifs"
            return 0
        fi
    done
    IFS="$old_ifs"
    return 1
}

clean_scope_matches() {
    local step_scope="$1"
    local requested_scope="${MOLE_SCOPE:-all}"

    case "$requested_scope" in
        all)
            if [[ "$step_scope" == "external" ]]; then
                return 1
            fi
            if [[ "$step_scope" == "system" && "${SYSTEM_CLEAN:-false}" != "true" && "${MOLE_INTERFACE:-human}" == "human" ]]; then
                return 1
            fi
            return 0
            ;;
        user) [[ "$step_scope" == "user" ]] ;;
        system) [[ "$step_scope" == "system" ]] ;;
        external) [[ "$step_scope" == "external" ]] ;;
        *) return 1 ;;
    esac
}

clean_selected_step_records() {
    local entry
    clean_registry_init
    for entry in "${MOLE_CLEAN_STEP_DEFS[@]}"; do
        local step_id section_id label function_name kind required_caps recommended_caps scope
        IFS='|' read -r step_id section_id label function_name kind required_caps recommended_caps scope <<< "$entry"
        clean_scope_matches "$scope" || continue
        clean_step_selected_by_cli "$step_id" || continue
        printf '%s\n' "$entry"
    done
}
