# Play Store: privacy and Data safety

What the Android app sends where, for the Play Console's Data safety form and the privacy
policy. No analytics, no ads, no crash reporting, no server of our own: every request goes from
the device to the service named, and only when the user turned it on.

| Service | When | What is sent | What is stored on the device |
|---|---|---|---|
| Lichess opening explorer (`explorer.lichess.org`) | building, coverage checks | positions (FEN) and the database chosen; the Lichess token when signed in | the answers (stats cache, support folder) |
| Lichess cloud evaluations (`lichess.org`) | the analysis board, if on in Settings | the position (FEN) | nothing |
| Lichess sign-in (`lichess.org`) | Settings → Sign in with Lichess | OAuth (PKCE); no scopes | the token (Keystore-encrypted) and username |
| Coverage tables (Cloudflare R2) | a repertoire's coverage database | the file's name | the table |
| Stockfish's full network (download) | Settings → Download | the file's name | the network |
| Dropbox (`api.dropboxapi.com`, `content.dropboxapi.com`, `notify.dropboxapi.com`) | Settings → Sync with Dropbox | the repertoire files (PGN, `.otrep.json` settings and training state, `.otlog.jsonl` review log) of the app's folder, uploaded to and downloaded from the App folder `Apps/ORBT Chess`; OAuth (PKCE) | the refresh token and account email (Keystore-encrypted); what was last synced (names, revs, content hashes) |
| Google Drive (`www.googleapis.com`) | Settings → Sync with Google Drive | the same files, in the "ORBT Chess" folder (scope `drive.file`: only files the app created) | the account email; what was last synced. The access token comes from Play services and is kept in memory only |

Data safety answers:
- **Data collected by the developer:** none. The files go to the user's own Dropbox or Google
  Drive (the user's choice, for the user's own use), which Play counts as data the user chose to
  send to a service, not collection by us.
- **Data shared:** none with third parties beyond the user's chosen storage provider and Lichess.
- **Encrypted in transit:** yes (HTTPS only).
- **Deletion:** everything is on the device or in the user's own storage; uninstalling removes
  the device's copy; Stop Syncing keeps the provider's files, which the user deletes there.
- **Account:** none of ours. Sign-ins are optional (Lichess, Dropbox, Google).
- Personal info: an email address is read only to show which account syncs (Dropbox's
  `users/get_current_account`, Google's sign-in); it never leaves the device.

Before publishing: Dropbox needs production approval past 500 users; Google's OAuth consent
screen needs brand verification for `drive.file` (no security assessment: the scope is not
restricted), with the privacy policy URL (orbtchess.org).
