# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Add a General setting to show or hide Ducko's menu bar icon

### Changed

- Require Apple Silicon for the app and bundled CLI
- Report confirmed contact changes separately from incomplete local synchronization or subscription requests
- Show an unavailable cipher suite explicitly in connection details

### Removed

- Remove the nonfunctional "Show Ducko in Dock" setting

### Fixed

- Allow closing Connection Info with Done, Return, or Escape
- Prevent a failed message-history write from crashing Ducko
- Preserve account and conversation settings when first saving them
- Preserve reply context in synced and archived messages
- Keep conversation history aligned with the latest conversation, date and search selection
- Keep contact changes and the saved roster version consistent across disconnects, reconnections, and local save failures
- Prevent a connection attempt from restoring an account after it has been disconnected
- Keep delayed room-join updates from restoring participants after leaving
- Close pending direct file-transfer connections when cancelling or going offline
- Finish signing out without a half-second wait when the connection has already dropped
- Prevent a failed OMEMO device list read from removing your other devices from encryption, and add this device once the list can be read again

### Security

- Accept replies to requests only from the address they were sent to, or from your own server, so another sender cannot answer them in its place

## [0.1.0] - 2026-09-16

### Added

- Save files you accept to the Downloads folder and show them in the sender's conversation, where you can preview them with Quick Look and reveal them in Finder
- List file offers sent as links next to direct transfers in the offer banner and the CLI

### Changed

- Ask before loading an image a contact links to, so opening a chat doesn't reveal your address and reading time to the image's host
- Accept or decline a file offer in the CLI by the id printed with it, taking the current account's newest offer when no id is given
- Show whether you have joined a room in the contact list, and follow the avatar and status indicator settings for room rows

### Removed

- Remove requesting a file from a contact and adding or removing files in a running transfer, which never delivered those files

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
- Fix direct file transfers reporting success when the file arrived incomplete or corrupted, and failed transfers later showing as completed
- Fix accepting a link offer reporting the transfer as complete without downloading anything, and refuse a download that ends early or arrives in a form whose size can't be checked
- Fix direct file transfers to clients such as Conversations stalling once they connect
- Fix your status in the Contacts header, account menu and menu bar not reflecting an account's own status, or showing online while the account is disconnected

### Security

- Prevent a peer from freezing or crashing a direct file transfer with an invalid transfer block size
- Prevent an attacker on the network from slipping unencrypted messages into a connection while it switches to encryption, and refuse to connect when a server does so
- Prevent anyone other than the person you are transferring with from cancelling, redirecting, feeding data into, or completing a direct file transfer
- Prevent a contact from disguising a file's name with invisible characters or saving it outside the Downloads folder
- Prevent a contact from opening a file on your own computer by sending a link to a local path
- Prevent accepting one file offer from acting on another offer that reuses its id

## [0.0.2] - 2026-09-14

### Added

- Show the first import errors in the Adium import summary, not just their count

### Fixed

- Fix signing in to servers that offer SASL2 authentication, which failed with an unexpected stream error
- Import Adium chat history for Facebook, MSN, and ICQ contacts whose IDs contain `@` or spaces
- Show readable connection and server error messages instead of internal error codes

## [0.0.1] - 2026-09-14

Initial release.

[Unreleased]: https://github.com/tobihagemann/ducko/compare/0.1.0...HEAD
[0.1.0]: https://github.com/tobihagemann/ducko/compare/0.0.2...0.1.0
[0.0.2]: https://github.com/tobihagemann/ducko/compare/0.0.1...0.0.2
[0.0.1]: https://github.com/tobihagemann/ducko/releases/tag/0.0.1
