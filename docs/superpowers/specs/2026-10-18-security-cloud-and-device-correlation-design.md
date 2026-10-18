# Security Cloud and device correlation — design

Status: the first slice shipped (epic #283): `DeviceCorrelation` and the Protect screen's
"Jamf Pro match" card. Everything else here is blocked on a Security Cloud tenant to test
against and is a plan, not a commitment.

## What shipped

`DeviceCorrelation` joins a row from one product to a Jamf Pro computer by identifier. It uses
the Devices rule: a row joins a record when they share an identifier and no identifier both
carry differs; a name never decides. An identifier on more than 50 records is a placeholder and
joins nothing. Several fits is "ambiguous" and is not counted. Protect's `uuid` is taken to be
Jamf Pro's `udid` and `serial` is the serial; that UUID match is unverified against a tenant.
The Protect screen shows how many Protect computers match, which do not, and which Jamf Pro
Macs have no Protect record.

## jamf-cli 1.31.1 surface

- `security setup` takes a separate Radar app ID and secret for each API (Risk, Device
  Lifecycle, SSE). There is no tenant URL.
- The gateway commands `dns`, `ztna`, `uem` and `device-groups` take Platform credentials plus
  `--tenant-id` or `--environment-id`.
- `security risk list` has `--external-id` and `--guid` filters. Its help documents no output
  fields.

## To settle against a tenant

- The fields of a risk row.
- What `externalId` and `guid` refer to (a Jamf Pro ID, a UDID, a serial, a Security Cloud ID).
- Pagination.
- Exit codes when a credential pair is missing.
- Whether an environment-level Platform profile reaches `/securitycloud`.
- Whether Protect's `uuid` equals Jamf Pro's `udid`.

## Planned config and collect

```yaml
security:
  enabled: false
  profile: ""
```

Collect kinds: `security-risk` (refresh tier); `security-device-groups`, `security-dns`,
`security-ztna-apps`, `security-ztna-gateways`, `security-uem-connectors` (inventory tier).
The allow-list is fixed and read-only. The app never runs risk override, device-lifecycle
purge, stream, status update, verification trigger or any gateway write. A 404 lands an empty
snapshot; a 429 is a rate limit, not a failure of the data.

## Correlation sources to add

Each joins the same way and is added with its first caller, not before.

| Source | First caller |
|---|---|
| `mobile-devices-list` | risk pill on Mobile Fleet |
| School devices | none planned |
| `platform-devices` | none planned |

## Surfaces

- A risk pill and filter on Mobile Fleet and Computers.
- A Security Cloud screen.
- A workbook sheet and an HTML report group, with counts only.
- An optional `security_cloud_risk` score factor, never in the default list.

## Redaction

- Phone numbers are redacted wherever they could appear.
- `security-risk` is treated as a device snapshot: it carries device identifiers.
- ZTNA IPsec fields are never shown.

## Out of scope

Writes of any kind to Security Cloud.
