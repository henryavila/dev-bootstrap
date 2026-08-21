# mesh-workstation — merge Catppuccin + Nerd Font into Windows Terminal settings.
# Usage: jq --slurpfile frag wt-settings-fragment.json --arg distro "$WSL_DISTRO_NAME" -f wt-settings-merge.jq settings.json
#
# - schemes: append fragment schemes, unique_by name
# - profiles.defaults: fragment fills missing keys; existing user keys win
# - profiles.defaults.font: same, per-key (so a profile-defaults {size:15} still
#   picks up CaskaydiaCove when face is unset)
# - unhide WSL/Ubuntu profiles
# - if defaultProfile is missing or still a factory PowerShell/cmd profile,
#   point it at the WSL/Ubuntu profile matching $distro (else first Ubuntu)

def factory_shell:
  ((.commandline // "") | test("powershell\\.exe|cmd\\.exe|pwsh\\.exe"; "i"))
  or ((.name // "") | test("^(Windows PowerShell|Command Prompt|Prompt de comando|PowerShell)$"; "i"));

def wslish:
  ((.source // "") | test("WSL|Ubuntu|Canonical"; "i"))
  or ((.name // "") | test("Ubuntu|WSL"; "i"));

.schemes = (((.schemes // []) + $frag[0].schemes) | unique_by(.name))
| .profiles = (.profiles // {})
| (.profiles.defaults // {}) as $old_defaults
| .profiles.defaults = (($frag[0].profileDefaults // {}) + $old_defaults)
| .profiles.defaults.font = (($frag[0].profileDefaults.font // {}) + ($old_defaults.font // {}))
| .profiles.list = ((.profiles.list // []) | map(if wslish then .hidden = false else . end))
| . as $root
| (
    ($root.profiles.list | map(select(wslish))) as $wsl
    | if ($wsl | length) == 0 then null
      elif ($distro | length) > 0 and ($wsl | map(select((.name // "") == $distro)) | length) > 0 then
        ($wsl | map(select((.name // "") == $distro)) | .[0])
      elif ($wsl | map(select((.name // "") | test("Ubuntu"; "i"))) | length) > 0 then
        ($wsl | map(select((.name // "") | test("Ubuntu"; "i"))) | .[0])
      else $wsl[0]
      end
  ) as $pick
| (
    ($root.defaultProfile // "") as $cur
    | if ($cur | length) == 0 then true
      else
        ($root.profiles.list | map(select(.guid == $cur)) | .[0] // {}) | factory_shell
      end
  ) as $should_switch
| if ($pick != null) and $should_switch then .defaultProfile = $pick.guid else . end
