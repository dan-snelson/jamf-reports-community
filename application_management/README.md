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

This is the app's bundle identifier. The app and its bundled background item (the
`--tick` run every five minutes) read this domain.

The included `jamf-reports` command is a symlink to the app's executable. Run through that
symlink, macOS does not see the app bundle, so the command reads a domain named
`jamf-reports` instead and does not see a profile for `com.tonyyo.jamfreports`. Run the
command by its full path (`/Applications/JamfReports.app/Contents/MacOS/JamfReports`) when
it must read the app's preferences, or set the environment variable below.

## Keys you can manage

| Key | Type | Default | What it does | Shown as managed in the app |
|---|---|---|---|---|
| `checkForAppUpdates` | Boolean | `true` | Once a day while the app is open, one request to `api.github.com` for the latest stable release, and a notice when it is newer. Nothing is downloaded or installed. Read at launch and every 30 minutes, so a profile that arrives while the app is open applies within half an hour. | Yes. Settings › App updates says "Set by your organization's configuration profile" and the switch is locked. |
| `autoUpdateJamfCLI` | Boolean | `false` | At launch, check for a jamf-cli update and install it. Read once per launch. | No |
| `skipExpensiveCollections` | Boolean | `false` | Leave the four per-device report commands (EA results, patch failures, update failures, device compliance) and the per-device scan out of the collects the app runs while open, and stop the health strip expecting them. Scheduled runs, and the app's catch-up and repair collects, do not read it. Read at each collect. | No |
| `workspacesRootPath` | String | absent (`~/Jamf-Reports`) | The folder that holds every workspace. An absolute path: `~` and `$HOME` are not expanded. Read on every use, by the app and the background item. | No |
| `defaultTrendRange` | String | `W4` | The range Overview and Trends open on: `W4`, `W12`, `W26`, `W52` or `All`. | No |
| `hiddenTabs` | String | empty | Sidebar tabs to hide, as a comma-separated list. Overview, Computers, Data Sources and Settings are never hidden. To get the value, hide the tabs in Settings › Sidebar Visibility on a test Mac and run `defaults read com.tonyyo.jamfreports hiddenTabs`. | No |

**Managed values win.** macOS returns a configuration profile's value to the app ahead of
anything the user sets, so every key above takes effect when managed. Only
`checkForAppUpdates` is shown as managed. For the others the Settings control stays
enabled: a change the user makes is saved, but the app keeps reading the managed value. When
you manage one of them, tell your users that the control will not change it.

**`workspacesRootPath` notes.**

- A profile gives every user it reaches the same value, so use a path that is valid for each
  of them, such as a mounted volume. A path under one user's home suits a profile scoped to
  that user only.
- Create the folder first. It must belong to the user and must not be writable by other
  accounts. Config Doctor (Health Audit › Config Doctor) reports a folder that is missing,
  read-only, in a system or credentials location, or open to other accounts.
- A system or credentials location is refused and the default `~/Jamf-Reports` is used.
- Existing workspaces are not moved. Copy them to the new folder yourself.
- Settings › Workspace location still offers Change and Use default. With the key managed,
  either one reports success but the managed folder stays in use.

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

Settings › App updates also shows whether `checkForAppUpdates` is managed.

## Logging profile

Verbose logging is a separate profile, for the `com.apple.system.logging` payload, not this
preference domain. The app bundles one:
`JamfReports.app/Contents/Resources/JamfReports-Debug-Logging.mobileconfig` (Settings ›
Logging › Reveal MDM profile shows it). It sets `Enable-Level` and `Persist` to `Debug` for
the subsystem `com.github.tonyyo11.jamf-reports-community`, so debug and info messages are
kept in the local log store. It does not set `Enable-Private-Data`: serials, host names and
user names stay `<private>`. It is a user-scoped profile.

The Settings › Logging switches do not use a profile. They write
`~/Library/Preferences/Logging/Subsystems/com.github.tonyyo11.jamf-reports-community.plist`
for the signed-in user, and they show only what that file holds, not a deployed profile.
Changes apply the next time the app starts.

See [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting).

## Environment variable

Not a preference, and no profile sets it.

| Variable | What it does |
|---|---|
| `JRC_WORKSPACES_ROOT` | The workspaces folder, ahead of `workspacesRootPath`. Set it in the script or launchd job that runs the `jamf-reports` command when the workspaces are not in `~/Jamf-Reports`. A system or credentials location is refused, as for the key. |

See [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line).
