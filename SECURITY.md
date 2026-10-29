# Security

ORBT Chess has no server and no account. What it keeps is on the device and in the user's
iCloud Drive: the repertoires (PGN), their training state, a statistics cache, and an optional
Lichess token in the Keychain. It talks to the Lichess API, Cloudflare R2 (coverage tables) and
stockfishchess.org (the optional engine network).

## Reporting a vulnerability
Please don't open a public issue. Report it privately, either with GitHub's
[private vulnerability reporting](https://github.com/carlvonburg/orbt-chess/security/advisories/new)
or by email to hello@orbtchess.org, with the steps to reproduce it and the app version
(Settings › About ORBT Chess).

You'll get an answer within a week. ORBT is a one-person project, so fixes ship in the next
App Store release; only the latest version is supported.

Of particular interest: a file (PGN, sidecar, review log) or a network answer that crashes the
app or makes it hang, anything that leaks the Lichess token, and anything that reads or writes
outside the app's folder.
