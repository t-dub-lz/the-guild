#!/usr/bin/env -S npx tsx

import { readFileSync, writeFileSync } from "fs";
import { argv, exit, stderr, stdout } from "process";
import { isatty } from "tty";

const CHECKMARK = '\u2713';
const XMARK = '\u2717';
const DOWN_RIGHT_ARROW = "╰─>";

const SUCCESS_COLOR = '\x1b[32m';
const FAIL_COLOR = '\x1b[31m';
const YELLOW_COLOR = '\x1b[33m';
const BLUE_COLOR = '\x1b[34m';
const MAGENTA_COLOR = '\x1b[35m';
const RESET_COLOR = '\x1b[0m';

const UNICODE_TAG_START = 0xE0000;
const UNICODE_TAG_END = 0xE007F;

// TIER 1: True smuggling - Unicode tag characters that encode hidden text
// These are ALWAYS detected and removed (cannot be disabled)
const SMUGGLING_RANGES = [
  { start: 0xE0000, end: 0xE007F, name: "Unicode tag characters (smuggling)" }
];

// TIER 2: Invisible formatting characters - not smuggling, just invisible
// These can be used for fingerprinting/steganography but don't hide other text
// Only processed with -s (strict) flag
const INVISIBLE_RANGES = [
  { start: 0x200B, end: 0x200D, name: "Zero-width spaces" },
  { start: 0x200E, end: 0x200F, name: "LTR/RTL marks" },
  { start: 0x202A, end: 0x202E, name: "Directional formatting" },
  { start: 0x2060, end: 0x2064, name: "Word joiners/invisible operators" },
  { start: 0x2066, end: 0x2069, name: "Directional isolates" },
  { start: 0x206A, end: 0x206F, name: "Deprecated formatting" },
  { start: 0xFEFF, end: 0xFEFF, name: "Zero-width no-break space" },
  { start: 0x180E, end: 0x180E, name: "Mongolian vowel separator" },
  { start: 0xE0100, end: 0xE01EF, name: "Variation selectors supplement" }
];

const REPLACEMENTS: Record<number, { replacement: string; name: string }> = {
  0x00A0: { replacement: ' ', name: 'Non-breaking space' },
  0x1680: { replacement: ' ', name: 'Ogham space' },
  0x2000: { replacement: ' ', name: 'En quad' },
  0x2001: { replacement: ' ', name: 'Em quad' },
  0x2002: { replacement: ' ', name: 'En space' },
  0x2003: { replacement: ' ', name: 'Em space' },
  0x2004: { replacement: ' ', name: 'Three-per-em space' },
  0x2005: { replacement: ' ', name: 'Four-per-em space' },
  0x2006: { replacement: ' ', name: 'Six-per-em space' },
  0x2007: { replacement: ' ', name: 'Figure space' },
  0x2008: { replacement: ' ', name: 'Punctuation space' },
  0x2009: { replacement: ' ', name: 'Thin space' },
  0x200A: { replacement: ' ', name: 'Hair space' },
  0x202F: { replacement: ' ', name: 'Narrow no-break space' },
  0x205F: { replacement: ' ', name: 'Medium mathematical space' },
  0x3000: { replacement: ' ', name: 'Ideographic space' },

  0x200B: { replacement: '', name: 'Zero-width space' },
  0x200C: { replacement: '', name: 'Zero-width non-joiner' },
  0x200D: { replacement: '', name: 'Zero-width joiner' },
  0x200E: { replacement: '', name: 'Left-to-right mark' },
  0x200F: { replacement: '', name: 'Right-to-left mark' },
  0x202A: { replacement: '', name: 'Left-to-right embedding' },
  0x202B: { replacement: '', name: 'Right-to-left embedding' },
  0x202C: { replacement: '', name: 'Pop directional formatting' },
  0x202D: { replacement: '', name: 'Left-to-right override' },
  0x202E: { replacement: '', name: 'Right-to-left override' },
  0x2060: { replacement: '', name: 'Word joiner' },
  0x2061: { replacement: '', name: 'Function application' },
  0x2062: { replacement: '', name: 'Invisible times' },
  0x2063: { replacement: '', name: 'Invisible separator' },
  0x2064: { replacement: '', name: 'Invisible plus' },
  0x2066: { replacement: '', name: 'Left-to-right isolate' },
  0x2067: { replacement: '', name: 'Right-to-left isolate' },
  0x2068: { replacement: '', name: 'First strong isolate' },
  0x2069: { replacement: '', name: 'Pop directional isolate' },
  0x206A: { replacement: '', name: 'Inhibit symmetric swapping' },
  0x206B: { replacement: '', name: 'Activate symmetric swapping' },
  0x206C: { replacement: '', name: 'Inhibit Arabic form shaping' },
  0x206D: { replacement: '', name: 'Activate Arabic form shaping' },
  0x206E: { replacement: '', name: 'National digit shapes' },
  0x206F: { replacement: '', name: 'Nominal digit shapes' },
  0xFEFF: { replacement: '', name: 'Zero-width no-break space (BOM)' },
  0x180E: { replacement: '', name: 'Mongolian vowel separator' },

  0x2028: { replacement: '\n', name: 'Line separator' },
  0x2029: { replacement: '\n\n', name: 'Paragraph separator' },
};

const HOMOGLYPHS: Record<string, { replacement: string; name: string }> = {
  // Cyrillic lowercase
  'а': { replacement: 'a', name: 'Cyrillic small letter a' },
  'е': { replacement: 'e', name: 'Cyrillic small letter ie' },
  'о': { replacement: 'o', name: 'Cyrillic small letter o' },
  'р': { replacement: 'p', name: 'Cyrillic small letter er' },
  'с': { replacement: 'c', name: 'Cyrillic small letter es' },
  'у': { replacement: 'y', name: 'Cyrillic small letter u' },
  'х': { replacement: 'x', name: 'Cyrillic small letter ha' },

  // Cyrillic uppercase
  'А': { replacement: 'A', name: 'Cyrillic capital letter A' },
  'В': { replacement: 'B', name: 'Cyrillic capital letter Ve' },
  'Е': { replacement: 'E', name: 'Cyrillic capital letter Ie' },
  'К': { replacement: 'K', name: 'Cyrillic capital letter Ka' },
  'М': { replacement: 'M', name: 'Cyrillic capital letter Em' },
  'Н': { replacement: 'H', name: 'Cyrillic capital letter En' },
  'О': { replacement: 'O', name: 'Cyrillic capital letter O' },
  'Р': { replacement: 'P', name: 'Cyrillic capital letter Er' },
  'С': { replacement: 'C', name: 'Cyrillic capital letter Es' },
  'Т': { replacement: 'T', name: 'Cyrillic capital letter Te' },
  'У': { replacement: 'Y', name: 'Cyrillic capital letter U' },
  'Х': { replacement: 'X', name: 'Cyrillic capital letter Ha' },

  // Small caps
  'ᴀ': { replacement: 'A', name: 'Latin letter small capital A' },
  'ʙ': { replacement: 'B', name: 'Latin letter small capital B' },
  'ᴄ': { replacement: 'C', name: 'Latin letter small capital C' },
  'ᴅ': { replacement: 'D', name: 'Latin letter small capital D' },
  'ᴇ': { replacement: 'E', name: 'Latin letter small capital E' },
  'ғ': { replacement: 'F', name: 'Latin letter small capital F' },
  'ɢ': { replacement: 'G', name: 'Latin letter small capital G' },
  'ʜ': { replacement: 'H', name: 'Latin letter small capital H' },
  'ɪ': { replacement: 'I', name: 'Latin letter small capital I' },
  'ᴊ': { replacement: 'J', name: 'Latin letter small capital J' },
  'ᴋ': { replacement: 'K', name: 'Latin letter small capital K' },
  'ʟ': { replacement: 'L', name: 'Latin letter small capital L' },
  'ᴍ': { replacement: 'M', name: 'Latin letter small capital M' },
  'ɴ': { replacement: 'N', name: 'Latin letter small capital N' },
  'ᴏ': { replacement: 'O', name: 'Latin letter small capital O' },
  'ᴘ': { replacement: 'P', name: 'Latin letter small capital P' },
  'ʀ': { replacement: 'R', name: 'Latin letter small capital R' },
  'ꜱ': { replacement: 'S', name: 'Latin letter small capital S' },
  'ᴛ': { replacement: 'T', name: 'Latin letter small capital T' },
  'ᴜ': { replacement: 'U', name: 'Latin letter small capital U' },
  'ᴠ': { replacement: 'V', name: 'Latin letter small capital V' },
  'ᴡ': { replacement: 'W', name: 'Latin letter small capital W' },
  'ʏ': { replacement: 'Y', name: 'Latin letter small capital Y' },
  'ᴢ': { replacement: 'Z', name: 'Latin letter small capital Z' },

  // Fullwidth digits
  '０': { replacement: '0', name: 'Fullwidth digit zero' },
  '１': { replacement: '1', name: 'Fullwidth digit one' },
  '２': { replacement: '2', name: 'Fullwidth digit two' },
  '３': { replacement: '3', name: 'Fullwidth digit three' },
  '４': { replacement: '4', name: 'Fullwidth digit four' },
  '５': { replacement: '5', name: 'Fullwidth digit five' },
  '６': { replacement: '6', name: 'Fullwidth digit six' },
  '７': { replacement: '7', name: 'Fullwidth digit seven' },
  '８': { replacement: '8', name: 'Fullwidth digit eight' },
  '９': { replacement: '9', name: 'Fullwidth digit nine' },

  // Fullwidth uppercase
  'Ａ': { replacement: 'A', name: 'Fullwidth Latin capital letter A' },
  'Ｂ': { replacement: 'B', name: 'Fullwidth Latin capital letter B' },
  'Ｃ': { replacement: 'C', name: 'Fullwidth Latin capital letter C' },
  'Ｄ': { replacement: 'D', name: 'Fullwidth Latin capital letter D' },
  'Ｅ': { replacement: 'E', name: 'Fullwidth Latin capital letter E' },
  'Ｆ': { replacement: 'F', name: 'Fullwidth Latin capital letter F' },
  'Ｇ': { replacement: 'G', name: 'Fullwidth Latin capital letter G' },
  'Ｈ': { replacement: 'H', name: 'Fullwidth Latin capital letter H' },
  'Ｉ': { replacement: 'I', name: 'Fullwidth Latin capital letter I' },
  'Ｊ': { replacement: 'J', name: 'Fullwidth Latin capital letter J' },
  'Ｋ': { replacement: 'K', name: 'Fullwidth Latin capital letter K' },
  'Ｌ': { replacement: 'L', name: 'Fullwidth Latin capital letter L' },
  'Ｍ': { replacement: 'M', name: 'Fullwidth Latin capital letter M' },
  'Ｎ': { replacement: 'N', name: 'Fullwidth Latin capital letter N' },
  'Ｏ': { replacement: 'O', name: 'Fullwidth Latin capital letter O' },
  'Ｐ': { replacement: 'P', name: 'Fullwidth Latin capital letter P' },
  'Ｑ': { replacement: 'Q', name: 'Fullwidth Latin capital letter Q' },
  'Ｒ': { replacement: 'R', name: 'Fullwidth Latin capital letter R' },
  'Ｓ': { replacement: 'S', name: 'Fullwidth Latin capital letter S' },
  'Ｔ': { replacement: 'T', name: 'Fullwidth Latin capital letter T' },
  'Ｕ': { replacement: 'U', name: 'Fullwidth Latin capital letter U' },
  'Ｖ': { replacement: 'V', name: 'Fullwidth Latin capital letter V' },
  'Ｗ': { replacement: 'W', name: 'Fullwidth Latin capital letter W' },
  'Ｘ': { replacement: 'X', name: 'Fullwidth Latin capital letter X' },
  'Ｙ': { replacement: 'Y', name: 'Fullwidth Latin capital letter Y' },
  'Ｚ': { replacement: 'Z', name: 'Fullwidth Latin capital letter Z' },

  // Fullwidth lowercase
  'ａ': { replacement: 'a', name: 'Fullwidth Latin small letter a' },
  'ｂ': { replacement: 'b', name: 'Fullwidth Latin small letter b' },
  'ｃ': { replacement: 'c', name: 'Fullwidth Latin small letter c' },
  'ｄ': { replacement: 'd', name: 'Fullwidth Latin small letter d' },
  'ｅ': { replacement: 'e', name: 'Fullwidth Latin small letter e' },
  'ｆ': { replacement: 'f', name: 'Fullwidth Latin small letter f' },
  'ｇ': { replacement: 'g', name: 'Fullwidth Latin small letter g' },
  'ｈ': { replacement: 'h', name: 'Fullwidth Latin small letter h' },
  'ｉ': { replacement: 'i', name: 'Fullwidth Latin small letter i' },
  'ｊ': { replacement: 'j', name: 'Fullwidth Latin small letter j' },
  'ｋ': { replacement: 'k', name: 'Fullwidth Latin small letter k' },
  'ｌ': { replacement: 'l', name: 'Fullwidth Latin small letter l' },
  'ｍ': { replacement: 'm', name: 'Fullwidth Latin small letter m' },
  'ｎ': { replacement: 'n', name: 'Fullwidth Latin small letter n' },
  'ｏ': { replacement: 'o', name: 'Fullwidth Latin small letter o' },
  'ｐ': { replacement: 'p', name: 'Fullwidth Latin small letter p' },
  'ｑ': { replacement: 'q', name: 'Fullwidth Latin small letter q' },
  'ｒ': { replacement: 'r', name: 'Fullwidth Latin small letter r' },
  'ｓ': { replacement: 's', name: 'Fullwidth Latin small letter s' },
  'ｔ': { replacement: 't', name: 'Fullwidth Latin small letter t' },
  'ｕ': { replacement: 'u', name: 'Fullwidth Latin small letter u' },
  'ｖ': { replacement: 'v', name: 'Fullwidth Latin small letter v' },
  'ｗ': { replacement: 'w', name: 'Fullwidth Latin small letter w' },
  'ｘ': { replacement: 'x', name: 'Fullwidth Latin small letter x' },
  'ｙ': { replacement: 'y', name: 'Fullwidth Latin small letter y' },
  'ｚ': { replacement: 'z', name: 'Fullwidth Latin small letter z' },
};

function isInvisibleFormattingChar(codePoint: number): boolean {
  return INVISIBLE_RANGES.some(range =>
    codePoint >= range.start && codePoint <= range.end
  );
}

function isSmugglingChar(codePoint: number): boolean {
  return codePoint >= UNICODE_TAG_START && codePoint <= UNICODE_TAG_END;
}

function tagToAscii(codePoint: number): string {
  if (codePoint >= UNICODE_TAG_START && codePoint <= UNICODE_TAG_END) {
    const asciiCode = codePoint - UNICODE_TAG_START;
    if (asciiCode >= 0x20 && asciiCode <= 0x7E) {
      return String.fromCharCode(asciiCode);
    }
  }
  return '';
}

interface ReplacementInfo {
  count: number;
  name: string;
}

// Strictness levels:
// 0 = default: only detect smuggling (tag characters)
// 1 = strict (-s): detect smuggling + invisible formatting
// 2 = super strict (-S): detect smuggling + invisible formatting + homoglyphs
function cleanContent(content: string, strictness: number = 0): {
  cleaned: string;
  invisibleReplacements: Map<string, ReplacementInfo>;
  homoglyphReplacements: Map<string, ReplacementInfo>;
  smugglingSequencesRemoved: number;
  smugglingCharactersRemoved: number;
  hiddenTexts: string[];
} {
  const invisibleReplacements = new Map<string, ReplacementInfo>();
  const homoglyphReplacements = new Map<string, ReplacementInfo>();
  const hiddenTexts: string[] = [];
  let smugglingSequencesRemoved = 0;
  let smugglingCharactersRemoved = 0;
  let cleaned = '';
  let inSmugglingSequence = false;
  let currentHiddenText = '';

  for (const char of content) {
    const codePoint = char.codePointAt(0);
    if (codePoint === undefined) {
      cleaned += char;
      continue;
    }

    // TIER 1: Always remove smuggling characters (Unicode tags) and collect hidden text
    if (isSmugglingChar(codePoint)) {
      if (!inSmugglingSequence) {
        smugglingSequencesRemoved++;
        inSmugglingSequence = true;
        if (currentHiddenText) {
          hiddenTexts.push(currentHiddenText);
          currentHiddenText = '';
        }
      }
      smugglingCharactersRemoved++;
      // Extract the hidden ASCII character
      const ascii = tagToAscii(codePoint);
      if (ascii) {
        currentHiddenText += ascii;
      }
      // Always skip smuggling characters
      continue;
    } else {
      if (inSmugglingSequence && currentHiddenText) {
        hiddenTexts.push(currentHiddenText);
        currentHiddenText = '';
      }
      inSmugglingSequence = false;
    }

    // TIER 2: Process invisible formatting characters only in strict mode (-s or -S)
    if (strictness >= 1 && codePoint in REPLACEMENTS) {
      const info = REPLACEMENTS[codePoint];
      const hexCode = `U+${codePoint.toString(16).toUpperCase().padStart(4, '0')}`;
      const existing = invisibleReplacements.get(hexCode);
      invisibleReplacements.set(hexCode, {
        count: (existing?.count || 0) + 1,
        name: info.name
      });
      // Replace with standard equivalent
      cleaned += info.replacement;
      continue;
    }

    // TIER 3: Process homoglyphs only in super strict mode (-S)
    if (strictness >= 2 && char in HOMOGLYPHS) {
      const info = HOMOGLYPHS[char];
      const key = `'${char}' → '${info.replacement}'`;
      const existing = homoglyphReplacements.get(key);
      homoglyphReplacements.set(key, {
        count: (existing?.count || 0) + 1,
        name: info.name
      });
      // Replace with ASCII equivalent
      cleaned += info.replacement;
      continue;
    }

    // Keep all other characters as-is
    cleaned += char;
  }

  // Don't forget the last hidden text if we ended in a smuggling sequence
  if (currentHiddenText) {
    hiddenTexts.push(currentHiddenText);
  }

  return { cleaned, invisibleReplacements, homoglyphReplacements, smugglingSequencesRemoved, smugglingCharactersRemoved, hiddenTexts };
}

function usage() {
  stderr.write(`Usage: ascii-cutterman [-s|-S] [-i] [-o output.md] [-n|-nn|-d] <filename>

The ASCII Cutterman combats the ASCII Smuggler!  Taking the supplied file, it
detects and removes Unicode tag sequences (U+E0000-U+E007F) that can be used to
hide text.  The hidden text is revealed on stderr while the "cleaned" original
file is sent to stdout.

WARNING: Stripping invisible formatting characters (-s) and homoglyphs (-S) can
be useful to combat fingerprinting and steganography, but may break legitimate
Unicode formatting in multilingual text, mathematical notation, or styled text.

Strictness levels:
  (default)       Detect only TRUE smuggling (Unicode tag characters)
  -s              Strict: also remove invisible formatting characters
  -S              Super strict: also replace homoglyphs with ASCII equivalents

Options:
  -i              In-place edit (overwrites input file)
  -o <file>       Write output to specified file instead of stdout
  -n              No output to stdout (stderr only, exit code indicates result)
  -nn             Binary test mode (no output at all, exit code only)
  -d              Details only (show only issue details, no header/status line)
  --prefix=<str>  Prefix string for each output line
  -h, --help      Show this help message

Exit codes:
  0 - Clean (no problematic characters found)
  1 - Naughty (problematic characters found)
  2 - Error (file read/write error)
`);
}

function parseArgs(args: string[]): {
  filename?: string;
  outputFile?: string;
  inPlace: boolean;
  strictness: number;
  help: boolean;
  noOutput: boolean;
  silent: boolean;
  detailsOnly: boolean;
  prefix?: string;
} {
  const result = {
    filename: undefined as string | undefined,
    outputFile: undefined as string | undefined,
    inPlace: false,
    strictness: 0,
    help: false,
    noOutput: false,
    silent: false,
    detailsOnly: false,
    prefix: undefined as string | undefined
  };

  let i = 2;
  while (i < args.length) {
    const arg = args[i];

    if (arg === '-s') {
      result.strictness = Math.max(result.strictness, 1);
      i++;
    } else if (arg === '-S') {
      result.strictness = 2;
      i++;
    } else if (arg === '-n') {
      result.noOutput = true;
      i++;
    } else if (arg === '-nn') {
      result.silent = true;
      result.noOutput = true;
      i++;
    } else if (arg === '-d') {
      result.detailsOnly = true;
      result.noOutput = true;
      i++;
    } else if (arg.startsWith('--prefix=')) {
      result.prefix = arg.substring(9);
      i++;
    } else if (arg === '-i') {
      result.inPlace = true;
      i++;
    } else if (arg === '-o') {
      if (i + 1 >= args.length) {
        stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -o requires an output filename\n`);
        exit(1);
      }
      result.outputFile = args[i + 1];
      i += 2;
    } else if (arg === '-h' || arg === '--help') {
      result.help = true;
      i++;
    } else if (!arg.startsWith('-')) {
      if (result.filename) {
        stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Too many arguments\n`);
        usage();
        exit(1);
      }
      result.filename = arg;
      i++;
    } else {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Unknown option: ${arg}\n`);
      usage();
      exit(1);
    }
  }

  return result;
}

function main() {
  const options = parseArgs(argv);

  if (options.help) {
    usage();
    exit(0);
  }

  if (!options.filename) {
    if (!options.silent) {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} No filename provided\n`);
      usage();
    }
    exit(2);
  }

  if (options.inPlace && options.outputFile) {
    if (!options.silent) {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Cannot use both -i and -o options\n`);
      usage();
    }
    exit(2);
  }

  if (options.noOutput && (options.inPlace || options.outputFile)) {
    if (!options.silent) {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -n/-nn cannot be used with -i or -o options\n`);
      usage();
    }
    exit(2);
  }

  try {
    const content = readFileSync(options.filename, 'utf-8');
    const { cleaned, invisibleReplacements, homoglyphReplacements, smugglingSequencesRemoved, smugglingCharactersRemoved, hiddenTexts } = cleanContent(content, options.strictness);

    const hasChanges = invisibleReplacements.size > 0 || homoglyphReplacements.size > 0 || smugglingCharactersRemoved > 0;

    // Write the cleaned content (unless -n or -nn option is used)
    if (!options.noOutput) {
      if (options.inPlace) {
        writeFileSync(options.filename, cleaned, 'utf-8');
      } else if (options.outputFile) {
        writeFileSync(options.outputFile, cleaned, 'utf-8');
      } else {
        stdout.write(cleaned);
      }
    }

    // Report status to stderr (unless -nn option is used)
    if (!options.silent) {
      const linePrefix = options.prefix || '';
      
      if (options.detailsOnly) {
        // In details-only mode, only show the issue details if there are problems
        if (hasChanges) {
          if (smugglingCharactersRemoved > 0) {
            stderr.write(`${linePrefix}${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} SMUGGLING DETECTED: Removed ${BLUE_COLOR}${smugglingSequencesRemoved}${RESET_COLOR} Unicode tag sequence${smugglingSequencesRemoved !== 1 ? 's' : ''} (${BLUE_COLOR}${smugglingCharactersRemoved}${RESET_COLOR} character${smugglingCharactersRemoved !== 1 ? 's' : ''})\n`);

            // Always show hidden text that was found
            if (hiddenTexts.length > 0) {
              stderr.write(`${linePrefix}${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Hidden text that was smuggled:\n`);
              hiddenTexts.forEach((text, idx) => {
                stderr.write(`${linePrefix}    Sequence ${idx + 1}: "${BLUE_COLOR}${text}${RESET_COLOR}"\n`);
              });
            }
          }

          if (invisibleReplacements.size > 0) {
            stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Invisible formatting characters detected:\n`);
            invisibleReplacements.forEach((info, char) => {
              stderr.write(`${linePrefix}    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          if (homoglyphReplacements.size > 0) {
            stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Homoglyphs detected:\n`);
            homoglyphReplacements.forEach((info, char) => {
              stderr.write(`${linePrefix}    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }
        }
      } else {
        // Normal mode - show full output
        // Determine if we need extra newlines for visual separation
        // We add newlines when:
        // 1. Output goes to stdout (no -i or -o option) AND
        // 2. stdout is a TTY (not redirected) AND
        // 3. Not using -n or -nn options
        const needsNewlines = !options.inPlace && !options.outputFile && !options.noOutput && isatty(stdout.fd);
        const prefix = needsNewlines ? '\n\n' : '';

        if (!hasChanges) {
          stderr.write(`${prefix}${SUCCESS_COLOR}${CHECKMARK} SUCCESS:${RESET_COLOR} clean - No problematic characters in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
        } else {
          // Determine severity: smuggling is FAIL, others are just issues
          const hasSmugglingissues = smugglingCharactersRemoved > 0;
          if (hasSmugglingissues) {
            stderr.write(`${prefix}${FAIL_COLOR}${XMARK} FAIL:${RESET_COLOR} SMUGGLING DETECTED in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
          } else {
            stderr.write(`${prefix}${YELLOW_COLOR}⚠ WARNING:${RESET_COLOR} Suspicious characters found in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
          }

          if (smugglingCharactersRemoved > 0) {
            stderr.write(`${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} SMUGGLING: Removed ${BLUE_COLOR}${smugglingSequencesRemoved}${RESET_COLOR} Unicode tag sequence${smugglingSequencesRemoved !== 1 ? 's' : ''} (${BLUE_COLOR}${smugglingCharactersRemoved}${RESET_COLOR} character${smugglingCharactersRemoved !== 1 ? 's' : ''})\n`);

            // Always show hidden text that was found
            if (hiddenTexts.length > 0) {
              stderr.write(`${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Hidden text that was smuggled:\n`);
              hiddenTexts.forEach((text, idx) => {
                stderr.write(`    Sequence ${idx + 1}: "${BLUE_COLOR}${text}${RESET_COLOR}"\n`);
              });
            }
          }

          if (invisibleReplacements.size > 0) {
            stderr.write(`${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Invisible formatting characters replaced:\n`);
            invisibleReplacements.forEach((info, char) => {
              stderr.write(`    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          if (homoglyphReplacements.size > 0) {
            stderr.write(`${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} Homoglyphs replaced with ASCII equivalents:\n`);
            homoglyphReplacements.forEach((info, char) => {
              stderr.write(`    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          if (options.inPlace) {
            stderr.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} File ${MAGENTA_COLOR}${options.filename}${RESET_COLOR} updated in-place\n`);
          } else if (options.outputFile) {
            stderr.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Cleaned output written to ${MAGENTA_COLOR}${options.outputFile}${RESET_COLOR}\n`);
          }
        }
      }
    }

    // Exit with appropriate code
    exit(hasChanges ? 1 : 0);
  } catch (error) {
    if (!options.silent) {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} ${error}\n`);
    }
    exit(2);
  }
}

main();
