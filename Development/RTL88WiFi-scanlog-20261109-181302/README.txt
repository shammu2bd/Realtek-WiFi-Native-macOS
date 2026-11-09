RTL88WiFi scan/roaming diagnostic capture
Capture tool version: 1.0
Driver build: 1.0.11-rtl88wifi-r29-unifi-scan-lifecycle-20261109
macOS: 15.8.1 (24H32), kernel 24.6.0
Mac model: MacBookPro16,3
Interface: en1
Started: 2026-11-09T18:13:02+0600
Planned duration: 300 seconds
Sampling interval: 2 seconds

Contents:
- samples.csv: link, queue, TX rate/MCS/bandwidth and scan/roam event counts per sample
- scan-events.log: newly observed scan, roaming, association and TX diagnostic lines
- join-report.txt: the driver's standard privacy-redacted join report
- capture-summary.txt: capture timing and final counters

Privacy:
The collector intentionally omits SSID, BSSID, MAC addresses, IP addresses,
router/gateway addresses, Wi-Fi passwords and key material. The selected driver
log lines are redacted before writing. Review the ZIP before sharing it.

This is a read-only observer. It does not initiate scans, change settings,
restart the driver, or run a throughput test.
