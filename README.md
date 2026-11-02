# DiaTweaks

Small tweaks for [Dia](https://www.diabrowser.com) that stay in place when Dia updates.

Unofficial and not affiliated with The Browser Company. Apple Silicon, macOS 14 or later.

## Tweaks

Each tweak changes one part of how Dia looks, like the padding around pages or a button in the toolbar. There's also a command, **Group Tabs by Domain**, that groups tabs by site.

Turn tweaks on and off in **Dia → Settings → Patches**, or with the `diatweaks` command.

[See all tweaks →](https://github.com/JaceThings/DiaTweaks/wiki)

### Bring Your Own Key (BYOK)

Route Dia Chat and agent features through your own AI API key and choice of model.
- **Supported Providers**: Google Gemini, Anthropic, OpenAI, OpenRouter.
- **Live Key Verification & Model Fetching**: When you paste your key and click **Verify & Fetch Models** (or run `diatweaks byok set`), it verifies the key against the provider's API and populates the model dropdown with available models.
- **Model Selection**: Pick any model from the dropdown or specify custom model IDs.
- **Briefs & Summaries Toggle**: Under **Dia → Settings → Patches** or via the Menu Bar item **"Use BYOK for Briefs & Summaries"**, choose whether Morning Briefs and page summaries use your BYOK key or Dia's default.

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
| `diatweaks byok` | Configure BYOK AI provider, API key, model and briefs toggle |
| `diatweaks byok set` | Set provider (`google`, `anthropic`, `openai`, `openrouter`), key, and default model |
| `diatweaks byok verify` | Test your API key and inspect available models |
| `diatweaks byok models` | Fetch and list all available models from the selected provider |
| `diatweaks list` | Shows every tweak and whether it's on |
| `diatweaks enable hideToolbar` | Turns a tweak on; Dia changes straight away |
| `diatweaks disable hideToolbar` | Turns a tweak off |
| `diatweaks status` | Shows Dia's version, safe mode and which tweaks are on |
| `diatweaks update` | Installs the latest DiaTweaks release and patches Dia again |
| `diatweaks update-dia` | Downloads a newer Dia and patches it |
| `diatweaks restore` | Puts the original Dia back |

Tweak names work as keys or titles, like `hideToolbar` or `"Hide toolbar"`. Add `-y` to skip the questions.

## Updating

Dia's own updater is switched off. **Settings → Patches → Software Update** checks for a new Dia and a new DiaTweaks release, downloads either one, and relaunches Dia to install it, like macOS's Software Update. Under **Automatic Updates**, pick for each of Dia and DiaTweaks: off, just show updates, download them, or download and install them when you quit (the default).

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

Yes. It's built on your Mac from this code. It only changes how Dia looks, and never reads your pages, history or passwords.

</details>

<details>
<summary><strong>How does it work?</strong></summary>

It keeps an untouched copy of Dia and makes a second copy that loads a small add-on. The add-on moves and hides parts of Dia while it runs.

</details>

<details>
<summary><strong>Why does my Mac ask about "Dia Safe Storage"?</strong></summary>

The tweaked Dia is signed by you instead of The Browser Company, so macOS checks once per Dia update. Click **Always Allow**.

</details>

<details>
<summary><strong>Does it run in the background?</strong></summary>

No. It only does anything while Dia is open.

</details>

<details>
<summary><strong>Does anything stop working?</strong></summary>

Passkeys saved in Apple Passwords need a short detour through the original Dia, which **Allow iCloud passkeys** handles. It's off by default, since it runs a second copy of Dia. [How it works →](https://github.com/JaceThings/DiaTweaks/wiki/Allow-iCloud-passkeys)

</details>

<details>
<summary><strong>What if Dia keeps crashing?</strong></summary>

If Dia crashes twice in a row right after opening, it opens next time with the tweaks off. **Settings → Patches** has a button to turn them back on.

</details>

## Uninstall

In Dia, open **Settings → Patches** and click **Restore…**. Dia reopens as the original app with its own updates.

To also delete DiaTweaks' files and the `diatweaks` command, run `diatweaks restore --purge` instead.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
