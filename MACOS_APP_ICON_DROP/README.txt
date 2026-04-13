Drop one custom macOS `.icns` app icon here if you want MOM.app to use your own icon.

Supported file names:
- `MOM.icns`
- `AppIcon.icns`
- `OS X AppIcon.icns`
- or any single `.icns` file in this folder

How it works:
- the packager copies your icon into `MOM.app/Contents/Resources/OS X AppIcon.icns`
- the existing macOS bundle metadata already points at that icon name
- if this folder is empty, the packaged app keeps the default LOVE icon

Recommended:
- create the `.icns` from a square master image with the usual macOS icon sizes
- rebuild with `./MAKE_MAC_PACKAGE.sh` or `./MAKE_MAC_PACKAGE_RELEASE.sh`
