# shellcheck shell=bash
# Path rules shared by the scripts. Source this file; it defines functions only.

# Succeeds when <path> is absolute or has ".." as a component, that is,
# when it may point outside the directory it is taken relative to.
is_unsafe_path() {
    local path="$1"
    [[ "$path" == /* || "$path" == .. || "$path" == ../* || \
       "$path" == */../* || "$path" == */.. ]]
}
