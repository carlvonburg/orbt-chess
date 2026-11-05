# Security

ORBT Chess has no server and no account. Your repertoires and training data stay on your
devices and in the storage you choose; sign-in tokens are kept in the system's secure store.
The services it talks to are listed in the [privacy policy](https://orbtchess.org/privacy/).

## Reporting a vulnerability
Please don't open a public issue. Report it privately, either with GitHub's
[private vulnerability reporting](https://github.com/carlvonburg/orbt-chess/security/advisories/new)
or by email to hello@orbtchess.org, with the steps to reproduce it, the platform and the app
version.

You'll get an answer within a week. Fixes ship in the next release; only the latest version is
supported.

Of particular interest: a file or a network answer that crashes the app or makes it hang,
anything that leaks a sign-in token, and anything that reads or writes outside the app's folder.
