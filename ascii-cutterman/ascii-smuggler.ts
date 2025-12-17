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

// ANSI colors for output
const SUCCESS_COLOR = '\x1b[32m';
const FAIL_COLOR = '\x1b[31m';
const YELLOW_COLOR = '\x1b[33m';
const BLUE_COLOR = '\x1b[34m';
const MAGENTA_COLOR = '\x1b[35m';
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
 * Display help message
 */
function usage(): void {
  stderr.write(`Usage: ${TOOL_NAME} <plain-text> <text-to-smuggle>

The ASCII Smuggler creates test cases for ASCII Cutterman!

Takes two arguments:
  1. Plain text - The visible text that will appear normally
  2. Text to smuggle - The hidden text encoded as invisible Unicode tag characters

The smuggled text is appended to the end of the plain text using Unicode tag
characters (U+E0000-U+E007F), which are invisible in most contexts but can be
detected and decoded by tools like ASCII Cutterman.

Example:
  ${TOOL_NAME} "Hello World" "secret message"

  Output: Hello World (with invisible "secret message" at the end)

Options:
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
} {
  const result = {
    plainText: undefined as string | undefined,
    smuggleText: undefined as string | undefined,
    help: false,
    verbose: false,
  };

  const positionalArgs: string[] = [];

  for (let i = 2; i < args.length; i++) {
    const arg = args[i];

    if (arg === '-h' || arg === '--help') {
      result.help = true;
    } else if (arg === '-v' || arg === '--verbose') {
      result.verbose = true;
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

  // Encode the smuggle text as Unicode tag characters
  const encodedSmuggle = encodeAsTagCharacters(options.smuggleText);

  // Build spec-compliant tag sequence per Unicode Standard:
  // - U+E0001 (LANGUAGE TAG) - begins the tag sequence
  // - U+E0020-U+E007E - tag characters encoding the content
  // - U+E007F (CANCEL TAG) - terminates the tag sequence
  //
  // Note: Many terminals show unknown glyphs for tag characters - this is
  // expected. The text is still "hidden" (unreadable). In web/HTML contexts
  // where smuggling attacks are most dangerous, tag characters render invisible.
  const tagSequence = TAG_BEGIN + encodedSmuggle + TAG_CANCEL;

  // Use a trailing space as separator so terminal glyphs don't appear to "eat"
  // the last visible character
  const output = options.plainText + ' ' + tagSequence;
  stdout.write(output + '\n');

  // Verbose mode: show encoding details on stderr
  if (options.verbose) {
    stderr.write(`\n${SUCCESS_COLOR}${CHECKMARK} Smuggling complete${RESET_COLOR}\n`);
    stderr.write(`${YELLOW_COLOR}Plain text:${RESET_COLOR} "${MAGENTA_COLOR}${options.plainText}${RESET_COLOR}"\n`);
    stderr.write(`${YELLOW_COLOR}Smuggled text:${RESET_COLOR} "${BLUE_COLOR}${options.smuggleText}${RESET_COLOR}"\n`);
    stderr.write(`${YELLOW_COLOR}Tag sequence:${RESET_COLOR} ${tagSequence.length} chars (U+E0001 BEGIN + ${encodedSmuggle.length} content + U+E007F CANCEL)\n`);
    stderr.write(`${YELLOW_COLOR}Total output:${RESET_COLOR} ${output.length} characters (${options.plainText.length} visible + 1 space + ${tagSequence.length} tag)\n`);
  }
}

main();
