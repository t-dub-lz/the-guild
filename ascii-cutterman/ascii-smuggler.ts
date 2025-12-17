#!/usr/bin/env -S npx tsx

/**
 * ASCII Smuggler - Creates test cases for ASCII Cutterman
 *
 * Takes plain text and text to smuggle, outputs the plain text with the
 * smuggled text encoded as Unicode tag characters appended at the end.
 *
 * Unicode tag characters (U+E0000-U+E007F) are invisible in most contexts
 * and map 1:1 to ASCII characters. This tool encodes ASCII text into these
 * invisible tag characters for testing ASCII smuggling detection.
 */

import { argv, exit, stderr, stdout } from "process";

const TOOL_NAME = "ascii-smuggler";

// Unicode tag character range (maps to ASCII 0x00-0x7F)
const UNICODE_TAG_START = 0xE0000;

// Tag sequence markers (proper Unicode tag framing)
const TAG_BEGIN = '\u{E0001}';   // U+E0001 - Language Tag / Begin
const TAG_CANCEL = '\u{E007F}';  // U+E007F - Cancel Tag / End

// Sneaky Bits encoding - binary using invisible math operators
// Reference: https://embracethered.com/blog/posts/2025/sneaky-bits-and-ascii-smuggler/
const SNEAKY_ZERO = '\u2062';  // Invisible times (binary 0)
const SNEAKY_ONE = '\u2064';   // Invisible plus (binary 1)

// Variant Selectors encoding - direct byte mapping
// VS1-VS16: U+FE00-U+FE0F (bytes 0-15)
// VS17-VS256: U+E0100-U+E01EF (bytes 16-255)
const VS_BASE_START = 0xFE00;      // VS1-VS16 range start
const VS_SUPPLEMENT_START = 0xE0100; // VS17-VS256 range start

type EncodingMethod = 'tags' | 'sneaky' | 'variant';

// ANSI colors for output
const SUCCESS_COLOR = '\x1b[32m';
const FAIL_COLOR = '\x1b[31m';
const YELLOW_COLOR = '\x1b[33m';
const BLUE_COLOR = '\x1b[34m';
const MAGENTA_COLOR = '\x1b[35m';
const CYAN_COLOR = '\x1b[36m';
const RESET_COLOR = '\x1b[0m';

const CHECKMARK = '\u2713';
const XMARK = '\u2717';

/**
 * Convert an ASCII character to its Unicode tag equivalent
 * ASCII code + 0xE0000 = Unicode tag character
 */
function asciiToTag(char: string): string {
  const asciiCode = char.charCodeAt(0);

  // Only convert printable ASCII (0x20-0x7E) and common control chars
  if (asciiCode >= 0x00 && asciiCode <= 0x7F) {
    return String.fromCodePoint(UNICODE_TAG_START + asciiCode);
  }

  // For non-ASCII, return empty (skip the character)
  return '';
}

/**
 * Encode a string into Unicode tag characters (invisible smuggled text)
 */
function encodeAsTagCharacters(text: string): string {
  let encoded = '';
  for (const char of text) {
    encoded += asciiToTag(char);
  }
  return encoded;
}

/**
 * Encode a string using Sneaky Bits technique
 * Each byte is converted to 8 binary digits, represented by invisible chars:
 * - U+2062 (invisible times) = 0
 * - U+2064 (invisible plus) = 1
 */
function encodeAsSneakyBits(text: string): string {
  let encoded = '';
  for (const char of text) {
    const byte = char.charCodeAt(0);
    // Convert byte to 8 bits, MSB first
    for (let bit = 7; bit >= 0; bit--) {
      encoded += (byte >> bit) & 1 ? SNEAKY_ONE : SNEAKY_ZERO;
    }
  }
  return encoded;
}

/**
 * Encode a string using Variant Selectors technique
 * Each byte (0-255) maps to a variant selector:
 * - Bytes 0-15 → VS1-VS16 (U+FE00-U+FE0F)
 * - Bytes 16-255 → VS17-VS256 (U+E0100-U+E01EF)
 */
function encodeAsVariantSelectors(text: string): string {
  let encoded = '';
  for (const char of text) {
    const byte = char.charCodeAt(0) & 0xFF; // Ensure byte range
    if (byte < 16) {
      // VS1-VS16: U+FE00-U+FE0F
      encoded += String.fromCodePoint(VS_BASE_START + byte);
    } else {
      // VS17-VS256: U+E0100-U+E01EF
      encoded += String.fromCodePoint(VS_SUPPLEMENT_START + (byte - 16));
    }
  }
  return encoded;
}

/**
 * Display help message
 */
function usage(): void {
  stderr.write(`Usage: ${TOOL_NAME} [-m METHOD] <plain-text> <text-to-smuggle>

The ASCII Smuggler creates test cases for ASCII Cutterman!

Takes two arguments:
  1. Plain text - The visible text that will appear normally
  2. Text to smuggle - The hidden text encoded as invisible Unicode characters

The smuggled text is appended to the end of the plain text using one of three
encoding methods, all invisible in most contexts but detectable by ASCII Cutterman.

ENCODING METHODS (-m):
  tags     (default) Unicode tag characters (U+E0000-U+E007F)
                     Maps ASCII 1:1 to tag characters. Most compatible.

  sneaky   Sneaky Bits - binary encoding using invisible math operators
                     Uses U+2062 (invisible times) for 0, U+2064 (invisible plus) for 1.
                     8:1 expansion (each byte becomes 8 invisible chars).

  variant  Variant Selectors - direct byte mapping (VS1-VS256)
                     Maps bytes 0-255 to variant selectors. 1:1 expansion.
                     Most efficient for binary data.

Example:
  ${TOOL_NAME} "Hello World" "secret message"
  ${TOOL_NAME} -m sneaky "Hello World" "secret"
  ${TOOL_NAME} -m variant "Hello World" "secret"

Options:
  -m, --method    Encoding method: tags (default), sneaky, or variant
  -h, --help      Show this help message
  -v, --verbose   Show details about the encoding

Exit codes:
  0 - Success
  1 - Error (invalid arguments)
`);
}

/**
 * Parse command line arguments
 */
function parseArgs(args: string[]): {
  plainText?: string;
  smuggleText?: string;
  help: boolean;
  verbose: boolean;
  method: EncodingMethod;
} {
  const result = {
    plainText: undefined as string | undefined,
    smuggleText: undefined as string | undefined,
    help: false,
    verbose: false,
    method: 'tags' as EncodingMethod,
  };

  const positionalArgs: string[] = [];

  for (let i = 2; i < args.length; i++) {
    const arg = args[i];

    if (arg === '-h' || arg === '--help') {
      result.help = true;
    } else if (arg === '-v' || arg === '--verbose') {
      result.verbose = true;
    } else if (arg === '-m' || arg === '--method') {
      i++;
      if (i >= args.length) {
        stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} -m requires a method argument (tags, sneaky, or variant)\n`);
        exit(1);
      }
      const method = args[i].toLowerCase();
      if (method !== 'tags' && method !== 'sneaky' && method !== 'variant') {
        stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Invalid method: ${args[i]}. Use tags, sneaky, or variant.\n`);
        exit(1);
      }
      result.method = method as EncodingMethod;
    } else if (!arg.startsWith('-')) {
      positionalArgs.push(arg);
    } else {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Unknown option: ${arg}\n`);
      exit(1);
    }
  }

  if (positionalArgs.length >= 1) {
    result.plainText = positionalArgs[0];
  }
  if (positionalArgs.length >= 2) {
    result.smuggleText = positionalArgs[1];
  }

  return result;
}

/**
 * Main entry point
 */
function main(): void {
  const options = parseArgs(argv);

  if (options.help) {
    usage();
    exit(0);
  }

  if (!options.plainText || !options.smuggleText) {
    stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} Both plain text and text to smuggle are required\n\n`);
    usage();
    exit(1);
  }

  let encodedSmuggle: string;
  let methodDescription: string;

  switch (options.method) {
    case 'sneaky':
      // Sneaky Bits: binary encoding using invisible math operators
      encodedSmuggle = encodeAsSneakyBits(options.smuggleText);
      methodDescription = `Sneaky Bits (${options.smuggleText.length} bytes × 8 = ${encodedSmuggle.length} invisible chars)`;
      break;

    case 'variant':
      // Variant Selectors: direct byte mapping
      encodedSmuggle = encodeAsVariantSelectors(options.smuggleText);
      methodDescription = `Variant Selectors (${encodedSmuggle.length} VS chars for ${options.smuggleText.length} bytes)`;
      break;

    case 'tags':
    default:
      // Unicode Tags: original method with framing
      // Build spec-compliant tag sequence per Unicode Standard:
      // - U+E0001 (LANGUAGE TAG) - begins the tag sequence
      // - U+E0020-U+E007E - tag characters encoding the content
      // - U+E007F (CANCEL TAG) - terminates the tag sequence
      const tagContent = encodeAsTagCharacters(options.smuggleText);
      encodedSmuggle = TAG_BEGIN + tagContent + TAG_CANCEL;
      methodDescription = `Unicode Tags (U+E0001 BEGIN + ${tagContent.length} content + U+E007F CANCEL)`;
      break;
  }

  // Use a trailing space as separator so terminal glyphs don't appear to "eat"
  // the last visible character
  //
  // Note: Many terminals show unknown glyphs for invisible characters - this is
  // expected. The text is still "hidden" (unreadable). In web/HTML contexts
  // where smuggling attacks are most dangerous, these characters render invisible.
  const output = options.plainText + ' ' + encodedSmuggle;
  stdout.write(output + '\n');

  // Verbose mode: show encoding details on stderr
  if (options.verbose) {
    stderr.write(`\n${SUCCESS_COLOR}${CHECKMARK} Smuggling complete${RESET_COLOR}\n`);
    stderr.write(`${YELLOW_COLOR}Method:${RESET_COLOR} ${CYAN_COLOR}${options.method}${RESET_COLOR}\n`);
    stderr.write(`${YELLOW_COLOR}Plain text:${RESET_COLOR} "${MAGENTA_COLOR}${options.plainText}${RESET_COLOR}"\n`);
    stderr.write(`${YELLOW_COLOR}Smuggled text:${RESET_COLOR} "${BLUE_COLOR}${options.smuggleText}${RESET_COLOR}"\n`);
    stderr.write(`${YELLOW_COLOR}Encoding:${RESET_COLOR} ${methodDescription}\n`);
    stderr.write(`${YELLOW_COLOR}Total output:${RESET_COLOR} ${output.length} characters (${options.plainText.length} visible + 1 space + ${encodedSmuggle.length} hidden)\n`);
  }
}

main();
