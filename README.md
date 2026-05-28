# ⚡ Fast Reading — KOReader Patch

A single drop-in patch for [KOReader](https://github.com/koreader/koreader) that adds three reading-enhancement modes to help you read faster and with less effort.

## Features

### 1. Bionic Reading
Bolds the **first half** of every word, letting your brain auto-complete the rest. Proven to increase reading speed by reducing fixation time.

```
 Normal:   The quick brown fox jumps over the lazy dog.
 Bionic:   The qu­ick br­own fox ju­mps ov­er the la­zy dog.
              ^^^          ^^^           ^^^^
           (bolded)     (bolded)      (bolded)
```

### 2. Guided Dots
Places a subtle middle-dot **·** between words to guide your eye along the line. Works great on its own or combined with Bionic / First Letter Focus.

```
 Normal:   The quick brown fox jumps
 Guided:   The · quick · brown · fox · jumps
```

### 3. First Letter Focus
Bolds the **first letter** (or first syllable for Indic scripts) of each word — a lighter alternative to full Bionic bolding.

```
 Normal:   The quick brown fox jumps
 Focus:    The quick brown fox jumps
            ^   ^     ^     ^   ^
         (bolded first letter of each word)
```

#### Hindi / Devanagari Support
First Letter Focus is fully compound-consonant-aware. Conjunct characters (consonant + virama + consonant) are never split — the entire first syllable cluster is bolded as a unit:

```
 स्पष्ट  →  स्पष्ट     (स्प is one cluster, bolded together)
 सुंदर   →  सुंदर      (सु is the first cluster)
 किताब   →  किताब      (कि is the first cluster)
```

## Supported Formats

| Format | Extensions |
|--------|-----------|
| EPUB   | `.epub`, `.kepub` |
| HTML   | `.xhtml`, `.html`, `.htm` |
| Plain text | `.md`, `.txt` |

## Installation

1. Copy `2-fast-reading.lua` to your KOReader patches directory:

   ```
   ~/.config/koreader/patches/2-fast-reading.lua
   ```

   On Kindle / Kobo / PocketBook, the path is typically:

   ```
   koreader/patches/2-fast-reading.lua
   ```

2. Restart KOReader.

3. Open any supported book and go to:

   **☰ Menu → Typeset tab**

   You'll see the new options above the "Typography" entry:
   - **Guided dots** — toggle guided dot separators
   - **Bionic reading** — toggle bionic bold
   - **First letter focus** — toggle first-letter bolding
   - **Restore all books** — undo all modifications at once

## Usage Notes

- **Features can be combined.** For example, you can enable Guided Dots + Bionic Reading simultaneously.
- **Bionic and First Letter Focus are mutually exclusive** — enabling one automatically disables the other, since both modify word styling.
- **Non-destructive.** A backup of every modified book is stored in its `.sdr` folder. Use "Restore all books" or simply disable all features to revert to the original file.
- **Progress is preserved.** When toggling a feature, your current reading position is saved and restored after the book reloads.
- **Dictionary lookup works.** Word selection is automatically expanded across `<b>` tag boundaries so that long-pressing a bionic/first-letter-styled word still looks up the full word.

## How It Works

The patch operates by modifying the book file in-place:

1. **Backup** — Before any transformation, the original file is copied to `<book>.sdr/backup.<ext>.orig`.
2. **Transform** — Each XHTML/HTML content file inside the EPUB (or the standalone file) is parsed. Text nodes outside protected tags (`<code>`, `<pre>`, `<script>`, `<svg>`, etc.) are tokenized into words and separators, then styled according to the active features.
3. **State** — The active feature combination is persisted in `<book>.sdr/intellireading.state` so it survives app restarts.
4. **Reload** — KOReader's `reloadDocument` API is used to seamlessly re-open the modified file without losing your place.

### Protected Content

The following elements are **never** modified:
- `<code>`, `<pre>`, `<script>`, `<style>`, `<svg>`, `<math>`, `<textarea>`, `<title>` blocks
- HTML entities (e.g. `&amp;`, `&#8212;`)
- Table-of-contents files (`nav.xhtml`, `toc.xhtml`)
- Image-only / SVG-only pages (auto-detected)

## Script Support

| Script | Bionic | First Letter Focus | Guided Dots |
|--------|--------|-----|-------------|
| Latin (English, French, etc.) | ✅ | ✅ | ✅ |
| Cyrillic (Russian, etc.) | ✅ | ✅ | ✅ |
| Greek | ✅ | ✅ | ✅ |
| Devanagari (Hindi, Sanskrit) | ✅ | ✅ | ✅ |
| Other Indic (Bengali, Tamil, etc.) | ✅ | ✅ | ✅ |
| Arabic / Hebrew (RTL) | — | — | ✅ |
| CJK (Chinese, Japanese, Korean) | — | — | — |

## Requirements

- **KOReader** 2024.04 or later (needs `reloadDocument` and `ffi/archiver`)
- No additional dependencies — the patch is a single self-contained Lua file

## Uninstalling

1. In KOReader, use **Typeset → Restore all books** to revert every modified book.
2. Delete `2-fast-reading.lua` from your patches directory.
3. Restart KOReader.

## License

MIT — free to use, modify, and distribute.
