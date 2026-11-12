# DiaTweaks

Small tweaks for [Dia](https://www.diabrowser.com) that stay in place when Dia updates.

Unofficial and not affiliated with The Browser Company. Apple Silicon, macOS 14 or later.

## Tweaks

Each tweak changes one thing about Dia: it hides something you don't use, changes how something looks, or adds something Dia doesn't do. They're grouped as they are in Settings:

| Section | What the tweaks there change |
|---|---|
| Page | The padding and corners around web pages |
| Toolbar | The toolbar, its buttons and the address field |
| Sidebar & Tab Bar | The sidebar, pinned tabs, profiles and tab groups |
| Tabs | Grouping, saving, unloading, closing and reopening tabs |
| Command Bar | The command bar and what it suggests |
| New Tab Page | What the new tab page shows |
| AI | Turning off Dia's AI, all at once or one part at a time |
| Window | How the window looks and behaves |
| Passwords | Password managers and passkeys |
| Links | Opening links in Peek and the address shown on hover |

Turn them on and off in **Dia → Settings → Patches**, or with the `diatweaks` command. Each one's Settings page links to its wiki page, which says what it does and when you'd want it.

[See all tweaks →](https://github.com/JaceThings/DiaTweaks/wiki)

## Install

1. Put Dia in your Applications folder.
2. Install Apple's developer tools: `xcode-select --install`
3. Paste this into Terminal:

   ```sh
   git clone https://github.com/JaceThings/DiaTweaks.git ~/DiaTweaks && ~/DiaTweaks/install.sh
   ```

Dia quits and reopens. If macOS asks about "Dia Safe Storage", enter your password and click **Always Allow**.

## The `diatweaks` command

Run `diatweaks` on its own for a menu, or:

| Command | Does |
|---|---|
| `diatweaks list` | Shows every tweak and whether it's on |
| `diatweaks enable hideToolbar` | Turns tweaks on; Dia changes straight away |
| `diatweaks disable hideToolbar` | Turns tweaks off |
| `diatweaks status` | Shows Dia's version, safe mode and which tweaks are on |
| `diatweaks update` | Installs the latest DiaTweaks release and patches Dia again |
| `diatweaks update-dia` | Downloads a newer Dia and patches it |
| `diatweaks restore` | Puts the original Dia back |

Tweak names work as keys or titles, like `hideToolbar` or `"Hide Toolbar"`, and `enable` and `disable` take several at once. Add `-y` to skip the questions.

## Updating

Dia's own updater is switched off. **Settings → Home → Software Update** checks for a new Dia and a new DiaTweaks release, downloads either one, and relaunches Dia to install it, like macOS's Software Update. Under **Automatic Updates**, pick for each of Dia and DiaTweaks: off, just show updates, download them, or download and install them when you quit (the default). A DiaTweaks you built from source with `install.sh` is never downloaded or replaced automatically: **Update Now** or `diatweaks update` installs the latest release, and automatic updates apply from then on.

- **Dia now:** `diatweaks update-dia`
- **DiaTweaks now:** `diatweaks update`

<details>
<summary>Installed before <code>diatweaks</code> existed?</summary>

Update once by hand, then use `diatweaks update` from then on:

```sh
rm -rf /tmp/DiaTweaks && git clone --depth 1 https://github.com/JaceThings/DiaTweaks.git /tmp/DiaTweaks && /tmp/DiaTweaks/install.sh
```

</details>

## FAQ

<details>
<summary><strong>Is it safe?</strong></summary>

It's built on your Mac from this code, and it doesn't send anything about you anywhere. It goes online only to check for updates and to load the preview pictures in Settings. A few tweaks look at what's in Dia to work: Group Tabs by Domain reads your tabs' addresses, and Tidy Tabs gives your tab titles and addresses to Apple's on-device model, which runs on your Mac. The password tweaks pass messages between your password manager and its extension without reading them.

</details>

<details>
<summary><strong>How does it work?</strong></summary>

It keeps an untouched copy of Dia and makes a second copy that loads a small add-on. The add-on changes parts of Dia while it runs. When Dia updates, DiaTweaks patches the new version the same way.

</details>

<details>
<summary><strong>Why does my Mac ask about "Dia Safe Storage"?</strong></summary>

The tweaked Dia is signed by you instead of The Browser Company, so macOS checks once per Dia update. Click **Always Allow**.

</details>

<details>
<summary><strong>Why does screen sharing ask for permission again?</strong></summary>

macOS ties Screen Recording to the app's signature, and the tweaked Dia is signed differently from the original. The first time DiaTweaks patches Dia (and when it goes back to the original), it clears the old permission so macOS asks once for the new one. Switch on **Dia** under **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen Dia. Dia and DiaTweaks updates keep your permission. If sharing still loops, run `tccutil reset ScreenCapture company.thebrowser.dia` and try again.

</details>

<details>
<summary><strong>Does it run in the background?</strong></summary>

No. It only does anything while Dia is open.

</details>

<details>
<summary><strong>Does anything stop working?</strong></summary>

Apple Passwords, its passkeys and 1Password only trust the original Dia, so in the patched one they stop working until you switch on the matching tweak in the **Passwords** section. Those run the original Dia without windows as a go-between, which is why they're off by default. [How it works →](https://github.com/JaceThings/DiaTweaks/wiki/Allow-iCloud-Passkeys)

</details>

<details>
<summary><strong>What if Dia keeps crashing?</strong></summary>

If Dia crashes twice in a row right after opening, it opens next time with the tweaks off. **Settings → Patches** has a button to turn them back on.

</details>

## Uninstall

In Dia, open **Settings → Home** and click **Restore…**. Dia reopens as the original app with its own updates.

To also delete DiaTweaks' files and the `diatweaks` command, run `diatweaks restore --purge` instead.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
