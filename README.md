# Logic2Drive

A small macOS menu bar app that keeps Logic Pro projects in Google Drive as
zip files, and opens those zips in Logic with a double-click.

**Status: early version (0.6.2). It has been tested on a single Mac with test
projects and a handful of real ones. Read "Known limitations" and "Not yet
tested" before you rely on it.**

## Why

Google Drive for desktop (File Provider mode) cannot reliably upload Logic
Pro projects. A `.logicx` project is a package, which is a folder. On
macOS 27 we saw uploads hang with "Communication with a helper application
failed", and other Macs received an empty file or a flat "document" instead
of the project. Zip files are not affected.

So Logic2Drive makes sure Google Drive only ever sees zips, and takes care of
packing and unpacking so that nobody has to think about it.

## What it does

- **Packing:** a project in a watched folder becomes `Name.logicx.zip` once it
  is closed in Logic and has been quiet for a while (5 minutes by default).
  After the upload is confirmed, the original moves to a local backup folder
  and Drive's empty placeholder goes to the Trash. The original stays in the
  backup folder for 90 days and then goes to the Trash.
- **Which projects:** every project whose upload hangs, and every project
  that was worked on at this Mac (its upload was seen here, or it was seen
  open in Logic and saved since). Projects that are already in the cloud and
  are merely downloaded here are left alone. That way only the Mac where the
  work happened does the packing.
- **Opening:** `Name.logicx.zip` is unpacked to `~/Music/Logic/In Arbeit` and
  opened in Logic. While it is open, a lock file `Name.logicx.inarbeit` sits
  next to the zip in Drive so that others can see it is in use.
- **Putting back:** after the project is closed in Logic and a quiet period
  (10 minutes by default), it is packed again and the zip in Drive is
  replaced. The previous zip is copied to the backup folder first and kept
  for 14 days.
- **Conflicts:** if the zip in Drive changed in the meantime, nothing is
  overwritten. Your version is placed next to it as
  `Name – Stand <first name> dd.MM. HH.mm.logicx.zip`.

Principles: nothing is ever deleted for good. Every zip is unpacked and
compared with the original before it replaces anything. A local copy is only
cleaned up once the upload is confirmed and the project is not open in Logic.

## Install

Download `Logic2Drive.zip` from the latest release, unpack it and move
`Logic2Drive.app` to your Applications folder. On first launch a welcome
window explains where the app lives and asks you to turn on three things:

- **Watch Google Drive:** watches every Google Drive account on this Mac.
  Before turning it on, Logic2Drive shows which hanging projects it would pack
  right away.
- **Open projects with a double-click:** macOS only knows the extension
  `.zip`, so Logic2Drive becomes the default app for all zips. It opens
  `Name.logicx.zip` in Logic and hands every other zip to Archive Utility.
- **Start at login.**

Logic2Drive has no window and no Dock icon. It lives in the menu bar: a record
with a small cloud. The menu shows what it is doing and the last thing it
did.

The first time it needs to know which projects are open, macOS asks whether
Logic2Drive may control Logic Pro. Click "Allow".

## Languages

German, English, French, Arabic and Farsi. Logic2Drive follows the language of
the Mac and falls back to English. The German texts live in the source code
and serve as keys, the translations are in `sprachen/<language>.lproj`.
`python3 test/texte.py` checks that every language has every text.

File names Logic2Drive writes into shared folders (`… – Stand …`,
`.inarbeit`) and the names of its local folders are the same in every
language, so that Macs with different languages understand each other.

## Updates

Once a day Logic2Drive asks GitHub for the latest release. If there is a newer
one, it downloads `Logic2Drive.zip` and installs it as soon as no project is
in progress and none has been open in Logic for 15 minutes, then restarts
itself. "Install updates automatically" in the settings window turns this
off; the menu then only points to the new version.

An update is only installed if its code signature is valid **and** comes from
the same Developer ID team as the running app. Someone who merely takes over
the GitHub account cannot push an update that way. A build without a
Developer ID (ad hoc signed) never installs updates on its own.

## Build

```bash
zsh -f bauen.sh                      # builds build/Logic2Drive.app (arm64 + x86_64, macOS 13+)
zsh -f bauen.sh --veroeffentlichen   # also notarizes it and creates build/Logic2Drive.zip
```

No Xcode project is needed, only the command line tools. The version number
lives in `VERSION`.

The app is signed with a "Developer ID Application" identity if the keychain
has one, otherwise ad hoc. `LOGIC2DRIVE_SIGNATUR` picks a specific identity,
`-` forces ad hoc. For `--veroeffentlichen` the notarization credentials must
be stored in the keychain (`xcrun notarytool store-credentials`). The profile
is called `logic-helfer-notar`, the project's former name, unless
`LOGIC2DRIVE_NOTAR` names another one.

If you fork this project and want updates from your own releases, change the
repository address in `update.swift` and `main.swift` and sign with your own
Developer ID.

Source files: `main.swift` (workflow and menu), `willkommen.swift` (welcome
window), `einstellungen.swift` (settings window), `zeichen.swift` (menu bar
icon and app icon), `update.swift` (updates), `texte.swift` (languages). Identifiers and comments are in German.

| Call | Effect |
|---|---|
| no argument | menu bar app |
| `--lauf` | runs without a user interface, for tests |
| `--oeffne <zip> [--trotzdem]` | hands a zip to the running app |
| `--trocken <folder …>` | only lists which projects it would pack |
| `--status` | jobs in progress as JSON |
| `--zuletzt` | the "last thing done" line of the menu |
| `--update-suchen` | asks for a newer version, changes nothing |
| `--version` | version number |

Data lives in `~/Library/Application Support/Logic2Drive`
(`einstellungen.json`, `auftraege.json`, `protokoll.log`).
`LOGIC2DRIVE_DATEN` moves that folder, `LOGIC2DRIVE_STILL=1` suppresses
notifications, `LOGIC2DRIVE_SPRACHE=de|en|fr|ar|fa` forces a language.

## Tests

```bash
zsh -f test/update.sh <work folder>   # updater, about 3 minutes, needs a Developer ID
python3 test/texte.py                 # translations complete?
zsh -f test/starten.sh                # the full run, see below
```

**Careful with the full run:** it opens and closes Logic Pro and works in a
real Google Drive folder, `Logic2Drive-Test` in "My Drive" of the first
account it finds (`LOGIC2DRIVE_TESTORDNER` picks another folder). It stops
if Logic is already running and takes about 30 minutes. One test places a
test project in iCloud Drive for about two minutes, because that is the only
place where a project that the cloud uploads normally can be tested. The
tests compare German output and set `LOGIC2DRIVE_SPRACHE=de` themselves.

Two things make the full run fail for reasons that have nothing to do with
the code. Somebody has to be at the Mac for both:

- Logic's own start-up dialogs. If Logic opens with a modal dialog (for
  example "The previous audio interface is not available"), it accepts the
  first project and silently ignores every further one until the dialog is
  confirmed.
- The first time a freshly signed build is launched through Launch Services,
  macOS asks whether it may control Logic Pro. Until that is allowed, the
  test that starts the app with a double-click times out.

## Known limitations

- **Conflicts are only detected on the local copy of Drive**, not in the
  cloud. After launch, wake or the network coming back, Logic2Drive waits
  3 minutes before it replaces anything. That lowers the risk but does not
  remove it.
- **Do not count on Drive's version history.** In a shared drive we saw only
  the new version after a zip was replaced, twice. That is why Logic2Drive keeps the
  replaced zip locally for 14 days, but only on the Mac that replaced it.
- Opening a project and letting Logic save it replaces the zip in Drive, even
  if you changed nothing on purpose.
- If a second Mac downloads a freshly saved project and opens it in Logic
  within ten minutes, both Macs pack it. A second "Stand" zip then appears
  next to the first.
- Logic2Drive remembers which projects were worked on here only in memory. If
  it restarts between saving and packing, a project that the cloud uploaded
  normally stays unpacked.
- If Logic shows a modal dialog and ignores a project it was asked to open,
  Logic2Drive cannot tell. The project stays checked out, and after a while a
  notification says it was never seen open.
- A crash at the moment of replacing produces a superfluous "Stand" version
  on the next start.
- If a zip contains several projects, only the first is opened.
- Projects in folder format whose audio lives next to the project are not
  packed with it.
- Packing, downloading and checksums run in one queue. A large project blocks
  the other jobs for that time.
- External commands and Drive downloads have no time limit. If a step hangs
  for more than 30 minutes, there is only a warning.
- Time limits depend on the system clock.
- Single folders can only be chosen in `einstellungen.json`, the settings window only
  knows "all of Google Drive".

## Not yet tested

- The full test run without a failure. With 0.6 it ran in a shared drive:
  98 of 99, and the one failure was Logic sitting in its "audio interface not
  available" dialog (see Tests). The run before that, unattended, stopped at
  73 of 99 for the same reason.
- Updates beyond one Mac. The updater is tested with a local stand-in for
  the release (17 of 17), and the running menu bar app updated itself from
  0.6 to 0.6.1 through "Check for Updates" and restarted. Not yet seen: the
  daily check finding an update on its own, and an update that has to wait
  because a project is in progress.
- The welcome window on a fresh Mac, and on a Mac without Google Drive.
- The French, Arabic and Farsi translations have not been read by native
  speakers. Right-to-left layout has only been looked at as a rendered image.
- A Mac on which Drive uploads packages normally (seen on macOS 14). Packing
  such projects has only been tested with iCloud Drive.
- Sleep and network loss during packing (handled in code, not tested for
  real).
- Macs with hidden file extensions, other macOS and Logic versions, large
  projects in day-to-day use, two people on the same project.

## Credits

Built by Joshua Nilles on behalf of [bibletunes gGmbH](https://bibletunes.com),
where Logic projects travel between several Macs through Google Drive every
week.

## License

MIT, see [LICENSE](LICENSE).
