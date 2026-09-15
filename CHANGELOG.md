# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Show a readable reason when signing in fails, such as "Incorrect username or password", instead of internal error details
- Show readable messages such as "Connection refused" when connecting, registering an account, transferring or uploading files, searching channels, or setting up OMEMO encryption fails, and when the server closes the connection
- Fix Ducko quitting unexpectedly when the server connection or a file transfer drops while data is being sent
- Fix Ducko crashing when the server closes an encrypted connection while messages are still being sent
- Fix connecting hanging indefinitely when a server stops responding during the encrypted handshake, and keep a slow certificate check from delaying going offline
- Fix connections staying open in the background after the server ends them, and going offline returning before the connection has actually closed
- Fix direct file transfers hanging when the peer rejects the connection method, a file transfer proxy can't be activated, or the peer or proxy stops responding
- Fix completed direct file transfers later showing as failed, and a second click on Accept stalling an incoming transfer
- Fix a rare crash in the update checker

### Security

- Prevent a peer from freezing or crashing a direct file transfer with an invalid transfer block size

## [0.0.2] - 2026-09-14

### Added

- Show the first import errors in the Adium import summary, not just their count

### Fixed

- Fix signing in to servers that offer SASL2 authentication, which failed with an unexpected stream error
- Import Adium chat history for Facebook, MSN, and ICQ contacts whose IDs contain `@` or spaces
- Show readable connection and server error messages instead of internal error codes

## [0.0.1] - 2026-09-14

Initial release.

[Unreleased]: https://github.com/tobihagemann/ducko/compare/0.0.2...HEAD
[0.0.2]: https://github.com/tobihagemann/ducko/compare/0.0.1...0.0.2
[0.0.1]: https://github.com/tobihagemann/ducko/releases/tag/0.0.1
