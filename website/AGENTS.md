# The website (orbtchess.org)

- Public text (the pages, the privacy policy, store listings) stays high level: what the app
  does and what data goes where, in a few short sentences; no folder names, token storage or
  per-platform exceptions.
- Change the privacy policy only when something it states becomes false (data goes somewhere
  new, or stops going somewhere). Wording changes ship with the next deploy; don't ask to deploy
  for them.
- Deploying (`deploy.sh`, see README.md) publishes to orbtchess.org: only when the owner asks.
