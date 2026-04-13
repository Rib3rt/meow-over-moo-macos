# macOS Steamworks Checklist

## macOS depot

1. Create a dedicated macOS depot.
2. Upload the extracted contents of the package `game` folder as the depot root.
3. Do not upload a zip archive as the SteamPipe content root.

## Launch option

Add a macOS launch option that points to the packaged app bundle:

- Executable: `MOM.app`
- Arguments: empty
- OS: `macOS`

## Branch strategy

1. Put the first native macOS build on a password beta branch.
2. Test Steam-installed launch before touching the public default branch.
3. Only enable public macOS support after the beta branch is validated.

## Steam Cloud

Cloud only:

- `OnlineRatingProfile.dat`

Keep local only:

- `OnlineRatingProfile.bak`

Base Auto-Cloud rule:

- Root: `WinAppDataRoaming`
- Subdirectory: `MeowOverMoo`
- Pattern: `OnlineRatingProfile.dat`
- Recursive: `No`
- OS: `All OSes`

macOS root override:

- OS: `macOS`
- New Root: `MacAppSupport`
- Add/Replace Path: `MeowOverMoo`
- Replace Path: `On`

Expected macOS save path:

- `~/Library/Application Support/MeowOverMoo/OnlineRatingProfile.dat`

## Store settings

Before enabling macOS publicly:

1. Add Apple Silicon minimum requirements to the store page.
2. Confirm the public package includes the macOS depot.
3. Confirm the native macOS build launches from Steam without Rosetta.

## Release gate

Do not mark macOS public until all of these pass:

- Steam-installed launch works
- overlay works
- achievements work
- leaderboard works
- online lobby works
- Steam Cloud rating sync works
