# Managing Jamf Reports

This folder lists the preference keys the Jamf Reports app reads, and holds example files for
setting them with a configuration profile or with `defaults write`.

Most of what Jamf Reports does is set per workspace in `config.yaml`, not in preferences. See
[Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates)
for that file. The keys here are per user, per Mac.

## Preference domain

```
com.tonyyo.jamfreports
```

This is the app's bundle identifier. The app, its bundled background item (the `--tick` run
every five minutes) and the included `jamf-reports` command all read this domain. The command
is a link to the app's executable; started through the link, it runs the executable inside
the app, so it sees the same preferences and profiles.

## Keys you can manage

| Key | Type | Default | What it does | Shown as managed in the app |
|---|---|---|---|---|
| `checkForAppUpdates` | Boolean | `true` | Once a day while the app is open, one request to `api.github.com` for the latest stable release, and a notice when it is newer. Nothing is downloaded or installed. Read at launch and every 30 minutes, so a profile that arrives while the app is open applies within half an hour. | Yes |
| `AIPolicy` | String | absent | `off` turns every AI feature off (insight cards, the run-failure explainer, the report summary), whatever each workspace's `config.yaml` says. `onDevice` allows AI but only on-device Apple Foundation Models; each workspace's `ai.enabled` still decides whether it is used. Any other value, including a different spelling, reads as `off`. Absent leaves AI to each workspace. Read when Settings or a screen loads a workspace's AI settings, so a change applies after switching workspace or relaunching. | Yes |
| `autoUpdateJamfCLI` | Boolean | `false` | At launch, check for a jamf-cli update and install it. Read once per launch. | Yes |
| `skipExpensiveCollections` | Boolean | `false` | Leave the four per-device report commands (EA results, patch failures, update failures, device compliance) and the per-device scan out of the collects the app runs while open, and stop the health strip expecting them. Scheduled runs, and the app's catch-up and repair collects, do not read it. Read at each collect. | Yes |
| `workspacesRootPath` | String | absent (`~/Jamf-Reports`) | The folder that holds every workspace. An absolute path: `~` and `$HOME` are not expanded. Read on every use, by the app and the background item. | Yes |
| `defaultTrendRange` | String | `W4` | The range Overview and Trends open on: `W4`, `W12`, `W26`, `W52` or `All`. | Yes |
| `hiddenTabs` | String | empty | Sidebar tabs to hide, as a comma-separated list. Overview, Computers, Data Sources and Settings are never hidden. To get the value, hide the tabs in Settings › Sidebar Visibility on a test Mac and run `defaults read com.tonyyo.jamfreports hiddenTabs`. | Yes |

**Managed values win.** macOS returns a configuration profile's value to the app ahead of
anything the user sets. When a profile sets a key, its control in Settings (or Trends' range
picker, or Sidebar Visibility) is locked and says "Set by your organization's configuration
profile", and the app never writes that key itself.

**`workspacesRootPath` notes.**

- A profile gives every user it reaches the same value, so use a path that is valid for each
  of them, such as a mounted volume. A path under one user's home suits a profile scoped to
  that user only.
- Create the folder first. It must belong to the user and must not be writable by other
  accounts. Config Doctor (Health Audit › Config Doctor) reports a folder that is missing,
  read-only, in a system or credentials location, or open to other accounts.
- A system or credentials location is refused and the default `~/Jamf-Reports` is used.
- Under `/Volumes` and `~/Library/CloudStorage` the app does not check who owns the folder
  or who can write to it, because network and File Provider volumes report owners and modes
  that say nothing about access. Make sure other accounts cannot write it. Config Doctor
  shows a warning (`cloud.root_ownership_unchecked`) for such a folder.
- A profile with System scope gives every account on the Mac the same root. The example
  `.mobileconfig` uses User scope; use System scope only when every account should share
  one folder.
- Existing workspaces are not moved. Copy them to the new folder yourself.
- With the key managed, Settings › Workspace location's Choose folder and Use default are
  locked, and the app refuses to change the folder.

## Not for management

The app writes these keys for itself. Do not set them in a profile: a forced value stops the
app updating its own state, and the stored format can change between releases.

| Key | What it holds |
|---|---|
| `automationPolicy` | The Automation screen's policy, as JSON. Set it in the app. |
| `schedulesImportedV1` | Set once old LaunchAgent schedules have been imported. |
| `JRC_SpotlightPurge_DoneForVersion` | The app version a one-time workspace clean-up last ran under. |
| `existingCLISetupOutcome`, `existingCLISetupDismissed` | Whether the "use existing jamf-cli profiles" setup was completed or skipped. The second is from older builds. |
| `com.jamfreports.forceDemoMode` | Demo mode was turned on by hand. |
| `com.jamfreports.selectedScoreCards`, `com.jamfreports.overviewLayout` | Which Overview cards and sections show, and their order. |
| `sidebarMode` | Sidebar expanded, compact or hidden. |
| `includeAuditInGenerate`, `generateSheetCustomSelection` | The Generate sheet's last choices. |
| `experimentalFeatures` | Preview features turned on in Settings. |
| `profile.scope.<profile>` | A label shown on Data Sources for a profile. It changes no access. |
| `dismissedAttentionItems` | "Needs attention" items dismissed on this Mac. |
| `appUpdateLastCheck`, `appUpdateLastCheckFailed`, `appUpdateLatestTag`, `appUpdateSkippedVersion` | The update check's last run, its result, and a version the user chose to skip. |

macOS also stores window positions and similar AppKit state in this domain. Leave those
alone too.

## Deploying

### Jamf Pro

1. Go to **Computers › Configuration Profiles** and create a profile.
2. Add the **Application & Custom Settings** payload and choose **Upload**.
3. Set **Preference Domain** to `com.tonyyo.jamfreports` and upload one of the `.plist` files
   in this folder, or your own with the keys you want.
4. Scope the profile and save.

To upload a whole profile instead, edit `jamf-reports-example.mobileconfig`: remove the keys
you do not want, replace the `workspacesRootPath` placeholder or remove it, and give each
`PayloadUUID` a new value from `uuidgen`. Upload it in **Configuration Profiles › Upload**.
Sign it first if your organization requires signed profiles.

| File | Sets |
|---|---|
| `jamf-reports-ai-off.plist` | `AIPolicy` to `off` |
| `jamf-reports-ai-on-device-only.plist` | `AIPolicy` to `onDevice` |
| `jamf-reports-disable-update-check.plist` | `checkForAppUpdates` to `false` |
| `jamf-reports-auto-update-jamf-cli.plist` | `autoUpdateJamfCLI` to `true` |
| `jamf-reports-skip-expensive-collections.plist` | `skipExpensiveCollections` to `true` |
| `jamf-reports-workspace-location.plist` | `workspacesRootPath` to a placeholder path; change it before upload |
| `jamf-reports-example.mobileconfig` | Every key above, with a comment on each |

### Testing with `defaults`

Set a key for the signed-in user, then quit and reopen the app:

```sh
defaults write com.tonyyo.jamfreports checkForAppUpdates -bool false
defaults write com.tonyyo.jamfreports defaultTrendRange -string W12
defaults delete com.tonyyo.jamfreports checkForAppUpdates
```

A value written this way is the user's own: the app does not show it as managed, and the
Settings switch changes it. Only a configuration profile makes a value managed.

`sudo defaults write /Library/Preferences/com.tonyyo.jamfreports <key> …` also reaches the
app, through the standard macOS search order, but a value in the user's own domain wins over
it. Use a profile when the value must hold.

### Checking what applies

```sh
# What the app reads, managed values included
defaults read com.tonyyo.jamfreports

# Values from a profile scoped to the computer, then to one user
cat "/Library/Managed Preferences/com.tonyyo.jamfreports.plist"
cat "/Library/Managed Preferences/$(whoami)/com.tonyyo.jamfreports.plist"
```

Each managed key's control in the app also says when a profile sets it.

## Logging profile

Verbose logging is a separate profile, for the `com.apple.system.logging` payload, not this
preference domain. The app bundles one:
`JamfReports.app/Contents/Resources/JamfReports-Debug-Logging.mobileconfig` (Settings ›
Logging › Reveal MDM profile shows it). It sets the `Level` dictionary's `Enable` and `Persist` to `Debug`
under `DEFAULT-OPTIONS` for the subsystem `com.github.tonyyo11.jamf-reports-community`, the
layout `man 5 os_log` documents, so debug and info messages are
kept in the local log store. It does not set `Enable-Private-Data`: serials, host names and
user names stay `<private>`. It is a user-scoped profile.

Settings › Logging shows whether a configuration profile sets logging for the app and what it
sets. For one Mac without a profile, an administrator can run:

```sh
sudo log config --subsystem com.github.tonyyo11.jamf-reports-community --mode "level:debug,persist:debug"
sudo log config --subsystem com.github.tonyyo11.jamf-reports-community --reset
```

The first keeps debug and info messages for Jamf Reports; the second returns it to the default.
Settings › Logging shows both commands with a Copy button. Earlier builds had two switches
that wrote `~/Library/Preferences/Logging/Subsystems/`, a folder macOS does not read for
logging settings; they are gone, and a file they left there can be deleted.

See [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting).

## Environment variable

Not a preference, and no profile sets it.

| Variable | What it does |
|---|---|
| `JRC_WORKSPACES_ROOT` | The workspaces folder, ahead of a `workspacesRootPath` the user set, but not ahead of one a profile manages: the profile's value wins and the app logs that the variable was ignored. Set it in a script or launchd job that must point the `jamf-reports` command at another folder than the app's setting. A system or credentials location is refused, as for the key. |

See [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line).
