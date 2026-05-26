# anki-toeic-add

A Claude Code skill that lets Claude **add English vocabulary cards to your Anki TOEIC deck** with a single sentence like *"幫我加 pedestrian, garage 到 TOEIC"*. Claude auto-generates Chinese meaning, KK 音標 (IPA), part of speech, etymology (字根字首拆解), TOEIC-style example sentences, **TOEIC drill fields** (high-frequency collocations, synonyms/confusables, Part 分布 + business context), optional pronunciation tips, **and a high-quality English audio mp3 (Microsoft Azure Neural Voice "Ava" via edge-tts)** — then pushes everything into Anki via the AnkiConnect HTTP API.

## Why

Building good vocab cards manually is slow: you have to look up the IPA, decide the part of speech, find example sentences, type Chinese, and click through Anki's UI. This skill closes the gap between *"I want to remember this word"* and *"…another 5-minute card-building chore"*: you just name the word(s), and Claude does the lookup + composition + API push in one go, using a card template optimized for mobile review with TTS on both Card 1 (中→英) and Card 2 (英→中).

## Install

```powershell
git clone https://github.com/momobacon-wq/claude-skill-anki-toeic-add.git "$env:USERPROFILE\.claude\skills\anki-toeic-add"
```

That's it — Claude Code auto-discovers skills under `~/.claude/skills/`. Start a new Claude Code session (or `/reload`) so the skill is registered.

### Requirements

- **Anki desktop** running on the same machine
- **AnkiConnect** add-on installed (add-on code `2055492159`), which exposes a localhost HTTP API at `http://127.0.0.1:8765`
- A deck named `TOEIC` (or edit `Add-AnkiCard`'s `-Deck` default)
- A note type named `英文單字` with these **11 fields** in order:
  `中文 / English / KK音標 / 發音說明 / 詞性 / 解說 / 例句 / 常用搭配 / 同義字反義 / 多益情境 / Audio`
- PowerShell 5.1+ (built in to Windows 10/11)
- **edge-tts** for the Ava neural voice — either install `uv` (`winget install astral-sh.uv`) so the skill can run it ephemerally via `uvx`, or `pip install --user edge-tts` (the skill auto-falls back to `python -m edge_tts`)
- Claude Code installed and running on the same machine

The skill ships with a `scripts/Add-AnkiCard.ps1` helper exposing: `Add-AnkiCard`, `New-AnkiTtsAudio`, `Test-AnkiCardExists`, `Test-AnkiConnect`, `Start-AnkiIfNotRunning`.

### TOEIC drill fields (the three TOEIC-specific extras)

| Field | What it contains | Why it matters for TOEIC |
|---|---|---|
| **常用搭配** | 3-5 high-frequency collocations (V+N, Adj+Prep, fixed phrases) | Part 5/6 vocabulary and preposition questions |
| **同義字反義** | Synonyms (Part 5 paraphrase distractors), antonyms, and **confusables** (e.g. `address` ↔ `access` ↔ `assess`) | Part 5 substitution traps, Part 7 paraphrase recognition |
| **多益情境** | Which Parts the word frequents + business contexts + estimated TOEIC level | Lets you mentally tag where you'll encounter the word during the test |

The **例句** field is also restructured so that each usage maps to a specific TOEIC question format: usage 1 → Part 5 cloze with 4 trap options, usage 2 → Part 4 monologue (meeting / announcement), usage 3 → Part 7 document (email / notice). For concrete-object words (e.g. `kneeling`, `wheelbarrow`) examples render as Part 1 picture-description sentences.

## Audio approach

Instead of relying on Anki's `{{tts}}` tag (which uses iOS/Windows OS TTS — quality varies, AnkiMobile defaults to compact Samantha which sounds robotic), this skill **pre-generates an mp3 per card** using Microsoft's free Azure Neural Voice `en-US-AvaNeural` via [`edge-tts`](https://github.com/rany2/edge-tts). The mp3 is stored in Anki's media library and embedded with `[sound:...]` in a dedicated `Audio` field. Result: ~7-10 KB per word, sounds natural on every device (iOS / Android / desktop / web), no per-platform TTS configuration needed.

The Chinese TTS (for Card 1 front) still uses `{{tts zh_TW:中文}}` because the user doesn't need to hear Chinese for memorization — saves storage.

## Usage

In Claude Code, say any of:

- 加 *X* 到 TOEIC
- 幫我加 *pedestrian, garage, schematic* 到 TOEIC
- 幫我把這幾個字做成 anki 卡
- 建單字卡 *X*
- 新增 Anki 卡片
- 這篇文章裡幫我挑 5 個 TOEIC 等級的生字加進去
- add *X* to my Anki
- make a flashcard for *X*

Claude will:

1. Check Anki is running + AnkiConnect reachable
2. Check each word for duplicates in the TOEIC deck (skip existing)
3. Generate all 10 content fields in the established style (clean `/IPA/`, etymology, TOEIC-style example sentences tagged with their Part, high-frequency collocations, synonyms / confusables, Part 分布 + business context, optional pronunciation tip)
4. POST to AnkiConnect's `addNote` endpoint
5. Sync to AnkiWeb so the cards show up on your phone immediately
6. Report back with each new note's ID + any duplicates that were skipped

## Card template

The accompanying card template (configured separately on the Anki side) produces 2 cards per note:

- **Card 1 (中 → 英)** — Front: Chinese + Chinese TTS. Back: English + KK音標 + 詞性 + etymology + examples + collocations + synonyms + TOEIC context + English audio mp3.
- **Card 2 (英 → 中)** — Front: English only (so you try pronouncing first). Back: KK音標 + Chinese + 詞性 + etymology + examples + collocations + synonyms + TOEIC context + English audio mp3 (heard on flip).

The three TOEIC drill blocks use Mustache conditional sections (`{{#field}}…{{/field}}`), so legacy cards from before the schema upgrade render exactly as they did before — only newly-filled cards show the extra blocks.

Mobile TTS works out-of-box on **AnkiMobile (iOS)**. On **AnkiDroid (Android)** you need Google TTS engine installed with English (US) and Chinese (Taiwan) voice packs.

## License

MIT — see [LICENSE](LICENSE).
