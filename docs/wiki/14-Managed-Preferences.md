# Managed Preferences

Jamf Reports keeps a few per-user settings in the preference domain `com.tonyyo.jamfreports`.
You can set them on every Mac with a configuration profile, or on one Mac with
`defaults write`. Everything about a workspace (folders, thresholds, notifications) is in its
`config.yaml` instead; see [Configuration & Templates](https://github.com/tonyyo11/jamf-reports-community/wiki/04-Configuration-and-Templates).

The full list of keys, the keys not to manage, and how to deploy and check them are in
[`application_management/`](https://github.com/tonyyo11/jamf-reports-community/tree/main/application_management)
in the repository, with example files ready to upload to Jamf Pro.

## Keys you can manage

| Key | Type | Default | Purpose |
|---|---|---|---|
| `AIPolicy` | String | absent | `off` turns every AI feature off; `onDevice` allows only on-device Apple models. Any other value reads as `off`. |
| `checkForAppUpdates` | Boolean | `true` | Daily check for a newer stable release. |
| `autoUpdateJamfCLI` | Boolean | `false` | Install jamf-cli updates at launch. |
| `skipExpensiveCollections` | Boolean | `false` | Leave per-device commands out of collects the app runs while open. |
| `workspacesRootPath` | String | `~/Jamf-Reports` | The folder that holds every workspace. Absolute path only. |
| `defaultTrendRange` | String | `W4` | The range Overview and Trends open on. |
| `hiddenTabs` | String | empty | Sidebar tabs to hide. |

A managed value always takes effect. Its control in the app is locked and says "Set by your
organization's configuration profile", and the app never writes that key itself.

## In Jamf Pro

Create a configuration profile with the **Application & Custom Settings** payload, choose
**Upload**, set the preference domain to `com.tonyyo.jamfreports`, and upload one of the
example `.plist` files. To turn off the update check on every Mac, upload
`jamf-reports-disable-update-check.plist`.

## The command-line tool

The `jamf-reports` command is a link to the app's executable and runs the executable inside
the app, so it reads the app's domain and sees the same profiles. Set `JRC_WORKSPACES_ROOT` in
the script that runs it when the workspaces are not in `~/Jamf-Reports`; a profile that manages
`workspacesRootPath` wins over the variable. See [Command Line](https://github.com/tonyyo11/jamf-reports-community/wiki/07-Command-Line).

## Verbose logging

The bundled `JamfReports-Debug-Logging.mobileconfig` is a separate logging profile. See the
logging section of the [`application_management` README](https://github.com/tonyyo11/jamf-reports-community/tree/main/application_management#logging-profile)
and [Diagnostics & Troubleshooting](https://github.com/tonyyo11/jamf-reports-community/wiki/09-Diagnostics-and-Troubleshooting).
