#!/usr/bin/env -S npx tsx

import { readFileSync, writeFileSync, existsSync, appendFileSync, unlinkSync } from "fs";
import { argv, exit, stderr, stdout } from "process";
import { isatty } from "tty";
import { tmpdir } from "os";
import { join } from "path";

const TOOL_NAME = "ascii-cutterman";

const CHECKMARK = '\u2713';
const XMARK = '\u2717';
const DOWN_RIGHT_ARROW = "╰─>";

const SUCCESS_COLOR = '\x1b[32m';
const FAIL_COLOR = '\x1b[31m';
const YELLOW_COLOR = '\x1b[33m';
const BLUE_COLOR = '\x1b[34m';
const MAGENTA_COLOR = '\x1b[35m';
const CYAN_COLOR = '\x1b[36m';
const RESET_COLOR = '\x1b[0m';

const UNICODE_TAG_START = 0xE0000;
const UNICODE_TAG_END = 0xE007F;

// Sneaky Bits encoding - binary using invisible math operators
// Reference: https://embracethered.com/blog/posts/2025/sneaky-bits-and-ascii-smuggler/
const SNEAKY_ZERO = 0x2062;  // Invisible times (binary 0)
const SNEAKY_ONE = 0x2064;   // Invisible plus (binary 1)

// Variant Selectors encoding - direct byte mapping
// VS1-VS16: U+FE00-U+FE0F (bytes 0-15)
// VS17-VS256: U+E0100-U+E01EF (bytes 16-255)
const VS_BASE_START = 0xFE00;
const VS_BASE_END = 0xFE0F;
const VS_SUPPLEMENT_START = 0xE0100;
const VS_SUPPLEMENT_END = 0xE01EF;

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

// ═══════════════════════════════════════════════════════════════════════════
// ENCODING DETECTION CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

const DEFAULT_MIN_BASE64_LENGTH = 24;  // Decodes to ~18 bytes
const DEFAULT_MIN_HEX_LENGTH = 32;     // 16 bytes

// Regex patterns - use capturing groups for the actual encoded content
// Base64: standard alphabet with optional padding, word boundaries to avoid partial matches
const BASE64_PATTERN = /(?<![a-zA-Z0-9+/=])([A-Za-z][A-Za-z0-9+/]{23,}={0,2})(?![a-zA-Z0-9+/=])/g;

// Hex: case-insensitive, even length sequences
const HEX_PATTERN = /(?<![a-fA-F0-9])([0-9a-fA-F]{32,})(?![a-fA-F0-9])/g;

// Known safe patterns to exclude (reduce false positives)
const SAFE_BASE64_CONTEXTS = [
  /data:image\/[^;]+;base64,/,           // Data URIs for images
  /data:application\/[^;]+;base64,/,     // Data URIs for apps
  /data:text\/[^;]+;base64,/,            // Data URIs for text
  /src\s*=\s*["']data:/,                 // Image src attributes
  /Content-Transfer-Encoding:\s*base64/i, // Email encoding headers
];

// Safe hex patterns - these are legitimate and should not be flagged
const SAFE_HEX_LENGTHS = new Set([
  8,    // Short hash, color without #
  32,   // MD5 hash
  40,   // Git SHA-1
  64,   // SHA-256
  96,   // SHA-384
  128,  // SHA-512
]);

// Suspicious decoded content indicators - security-relevant patterns
const SUSPICIOUS_PATTERNS: { pattern: RegExp; description: string }[] = [
  { pattern: /eval\s*\(/i, description: 'eval() call' },
  { pattern: /exec\s*\(/i, description: 'exec() call' },
  { pattern: /system\s*\(/i, description: 'system() call' },
  { pattern: /spawn\s*\(/i, description: 'spawn() call' },
  { pattern: /shell_exec/i, description: 'shell_exec call' },
  { pattern: /Process\./i, description: 'Process object access' },
  { pattern: /Runtime\.getRuntime/i, description: 'Java runtime access' },
  { pattern: /os\.(popen|system|exec)/i, description: 'Python os module call' },
  { pattern: /subprocess\./i, description: 'Python subprocess module' },
  { pattern: /\$\(\s*[`'"]/i, description: 'Shell command substitution' },
  { pattern: /`[^`]*`/, description: 'Backtick command execution' },
  { pattern: /curl\s+/i, description: 'curl command' },
  { pattern: /wget\s+/i, description: 'wget command' },
  { pattern: /fetch\s*\(/i, description: 'fetch() call' },
  { pattern: /\.env|password|secret|api.?key/i, description: 'Sensitive data reference' },
  { pattern: /ignore.*instruction/i, description: 'Prompt injection: ignore instructions' },
  { pattern: /disregard.*previous/i, description: 'Prompt injection: disregard previous' },
  { pattern: /forget.*instruction/i, description: 'Prompt injection: forget instructions' },
  { pattern: /new.*instruction/i, description: 'Prompt injection: new instructions' },
  { pattern: /<script/i, description: 'Script tag injection' },
  { pattern: /javascript:/i, description: 'JavaScript protocol' },
  { pattern: /on\w+\s*=/i, description: 'Event handler injection' },
  { pattern: /\bimport\s*\(/i, description: 'Dynamic import' },
  { pattern: /require\s*\(['"]/i, description: 'Dynamic require' },
  { pattern: /\$_(?:GET|POST|REQUEST|COOKIE)/i, description: 'PHP superglobal access' },
  { pattern: /base64_decode/i, description: 'Nested base64 decode' },
  { pattern: /fromCharCode/i, description: 'Character code obfuscation' },
  { pattern: /\\x[0-9a-fA-F]{2}/g, description: 'Hex escape sequences' },
];

// ═══════════════════════════════════════════════════════════════════════════
// ENCODING DETECTION TYPES
// ═══════════════════════════════════════════════════════════════════════════

interface EncodingMatch {
  type: 'base64' | 'hex';
  encoded: string;           // The original encoded string (possibly truncated for display)
  fullEncoded: string;       // Full original for length reporting
  decoded: string;           // Decoded content (possibly truncated for display)
  line: number;              // Line number
  column: number;            // Column position
  isSuspicious: boolean;     // Passed heuristic checks
  suspicionReasons: string[]; // Why it's flagged
}

interface EncodingAnalysisResult {
  base64Matches: EncodingMatch[];
  hexMatches: EncodingMatch[];
  totalSuspicious: number;
}

// ═══════════════════════════════════════════════════════════════════════════
// TIER 3: Homoglyph Detection
// ═══════════════════════════════════════════════════════════════════════════

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

/**
 * Check if a codepoint is a sneaky bit character (invisible times or invisible plus)
 */
function isSneakyBitChar(codePoint: number): boolean {
  return codePoint === SNEAKY_ZERO || codePoint === SNEAKY_ONE;
}

/**
 * Check if a codepoint is a variant selector used for smuggling
 */
function isVariantSelector(codePoint: number): boolean {
  return (codePoint >= VS_BASE_START && codePoint <= VS_BASE_END) ||
         (codePoint >= VS_SUPPLEMENT_START && codePoint <= VS_SUPPLEMENT_END);
}

/**
 * Decode a variant selector codepoint to its byte value (0-255)
 */
function decodeVariantSelector(codePoint: number): number {
  if (codePoint >= VS_BASE_START && codePoint <= VS_BASE_END) {
    return codePoint - VS_BASE_START;  // 0-15
  }
  return (codePoint - VS_SUPPLEMENT_START) + 16;  // 16-255
}

/**
 * Decode an array of sneaky bit codepoints to ASCII text
 * Each 8 consecutive bits decode to one byte
 */
function decodeSneakyBits(bits: number[]): string {
  let decoded = '';
  // Process in groups of 8 bits
  for (let i = 0; i + 7 < bits.length; i += 8) {
    let byte = 0;
    for (let bit = 0; bit < 8; bit++) {
      if (bits[i + bit] === SNEAKY_ONE) {
        byte |= (1 << (7 - bit));
      }
    }
    // Only include printable ASCII and common whitespace
    if ((byte >= 0x20 && byte <= 0x7E) || byte === 0x09 || byte === 0x0A || byte === 0x0D) {
      decoded += String.fromCharCode(byte);
    } else if (byte > 0) {
      // Non-printable but non-null - show as hex escape for visibility
      decoded += `\\x${byte.toString(16).padStart(2, '0')}`;
    }
  }
  return decoded;
}

/**
 * Decode an array of variant selector codepoints to text
 */
function decodeVariantSelectors(selectors: number[]): string {
  let decoded = '';
  for (const cp of selectors) {
    const byte = decodeVariantSelector(cp);
    // Only include printable ASCII and common whitespace
    if ((byte >= 0x20 && byte <= 0x7E) || byte === 0x09 || byte === 0x0A || byte === 0x0D) {
      decoded += String.fromCharCode(byte);
    } else if (byte > 0) {
      // Non-printable but non-null - show as hex escape for visibility
      decoded += `\\x${byte.toString(16).padStart(2, '0')}`;
    }
  }
  return decoded;
}

// ═══════════════════════════════════════════════════════════════════════════
// ENCODING DETECTION HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Safely decode base64, handling errors gracefully
 */
function safeBase64Decode(str: string): string | null {
  try {
    // Remove whitespace that might be in the string
    const cleaned = str.replace(/\s/g, '');

    // Validate base64 format - add padding if needed
    let padded = cleaned;
    const remainder = cleaned.length % 4;
    if (remainder > 0) {
      padded = cleaned + '='.repeat(4 - remainder);
    }

    const decoded = Buffer.from(padded, 'base64').toString('utf-8');

    // Verify it's actually valid by re-encoding - this catches invalid sequences
    const reencoded = Buffer.from(decoded, 'utf-8').toString('base64').replace(/=+$/, '');
    const originalNoPad = cleaned.replace(/=+$/, '');

    // Allow some flexibility in matching (base64 can have slight variations)
    if (reencoded.length > 0 && Math.abs(reencoded.length - originalNoPad.length) <= 4) {
      return decoded;
    }

    // Even if re-encode doesn't match perfectly, return if decoded has content
    if (decoded.length > 0) {
      return decoded;
    }

    return null;
  } catch {
    return null;
  }
}

/**
 * Safely decode hex string
 */
function safeHexDecode(str: string): string | null {
  try {
    // Remove common prefixes
    let cleaned = str.replace(/^0x/i, '').replace(/\\x/g, '');

    // Must be even length for valid hex
    if (cleaned.length % 2 !== 0) {
      cleaned = '0' + cleaned; // Pad with leading zero
    }

    const decoded = Buffer.from(cleaned, 'hex').toString('utf-8');
    return decoded.length > 0 ? decoded : null;
  } catch {
    return null;
  }
}

/**
 * Calculate Shannon entropy of a string (bits per character)
 * Higher entropy suggests random/encrypted/obfuscated data
 */
function calculateEntropy(str: string): number {
  if (str.length === 0) return 0;

  const freq = new Map<string, number>();
  for (const char of str) {
    freq.set(char, (freq.get(char) || 0) + 1);
  }

  let entropy = 0;
  const len = str.length;
  for (const count of freq.values()) {
    const p = count / len;
    entropy -= p * Math.log2(p);
  }

  return entropy;
}

/**
 * Check if a string is mostly printable ASCII
 */
function getPrintableRatio(str: string): number {
  if (str.length === 0) return 0;

  let printable = 0;
  for (const char of str) {
    const code = char.charCodeAt(0);
    // Printable ASCII range (space through tilde) plus common whitespace
    if ((code >= 32 && code <= 126) || code === 9 || code === 10 || code === 13) {
      printable++;
    }
  }

  return printable / str.length;
}

/**
 * Check if the context around a match suggests it's safe (e.g., data URI)
 */
function isInSafeBase64Context(content: string, position: number, matchLength: number): boolean {
  // Get surrounding context (200 chars before)
  const contextStart = Math.max(0, position - 200);
  const context = content.slice(contextStart, position + matchLength);

  // Check against safe patterns
  for (const pattern of SAFE_BASE64_CONTEXTS) {
    if (pattern.test(context)) return true;
  }

  return false;
}

/**
 * Check if a hex string is a known safe pattern (hash, UUID, etc.)
 */
function isKnownSafeHex(hexString: string): boolean {
  const len = hexString.length;

  // Check for standard hash lengths
  if (SAFE_HEX_LENGTHS.has(len)) {
    return true;
  }

  // Check for UUID pattern (with or without dashes - we see it without here)
  if (len === 32) {
    // 32 hex chars could be MD5 or UUID without dashes - consider safe
    return true;
  }

  return false;
}

/**
 * Analyze decoded content for suspicious patterns
 */
function analyzeSuspiciousness(decoded: string): { isSuspicious: boolean; reasons: string[] } {
  const reasons: string[] = [];

  // If it's mostly non-printable, it's likely binary data (less suspicious for text obfuscation)
  const printableRatio = getPrintableRatio(decoded);
  if (printableRatio < 0.7) {
    // Mostly binary - not text obfuscation, skip further analysis
    return { isSuspicious: false, reasons: [] };
  }

  // Check for suspicious patterns in decoded content
  for (const { pattern, description } of SUSPICIOUS_PATTERNS) {
    // Reset regex state for global patterns
    pattern.lastIndex = 0;
    if (pattern.test(decoded)) {
      reasons.push(description);
    }
  }

  // High entropy printable text is more suspicious (randomized to evade detection)
  const entropy = calculateEntropy(decoded);
  if (entropy > 5.0 && printableRatio > 0.9 && decoded.length > 50) {
    reasons.push(`High entropy text (${entropy.toFixed(2)} bits/char) - possible obfuscation`);
  }

  return {
    isSuspicious: reasons.length > 0,
    reasons
  };
}

/**
 * Get line and column number for a position in content
 */
function getLineInfo(content: string, position: number): { line: number; column: number } {
  const beforeMatch = content.slice(0, position);
  const lines = beforeMatch.split('\n');
  return {
    line: lines.length,
    column: lines[lines.length - 1].length + 1
  };
}

/**
 * Truncate a string for display, preserving useful information
 */
function truncateForDisplay(str: string, maxLen: number): string {
  if (str.length <= maxLen) return str;
  return str.slice(0, maxLen - 3) + '...';
}

/**
 * Main encoding detection function - finds and analyzes base64/hex strings
 */
function detectEncodings(content: string): EncodingAnalysisResult {
  const result: EncodingAnalysisResult = {
    base64Matches: [],
    hexMatches: [],
    totalSuspicious: 0
  };

  // Detect base64
  const base64Regex = new RegExp(BASE64_PATTERN.source, 'g');
  let match;

  while ((match = base64Regex.exec(content)) !== null) {
    const encoded = match[1] || match[0];

    // Skip if too short
    if (encoded.length < DEFAULT_MIN_BASE64_LENGTH) continue;

    // Skip if in safe context (data URI, etc.)
    if (isInSafeBase64Context(content, match.index, encoded.length)) continue;

    // Try to decode
    const decoded = safeBase64Decode(encoded);
    if (!decoded || decoded.length === 0) continue;

    // Skip if decoded is mostly non-printable (binary data is usually legitimate)
    const printableRatio = getPrintableRatio(decoded);
    if (printableRatio < 0.5) continue;

    // Analyze for suspiciousness
    const { isSuspicious, reasons } = analyzeSuspiciousness(decoded);

    const { line, column } = getLineInfo(content, match.index);

    const encodingMatch: EncodingMatch = {
      type: 'base64',
      encoded: truncateForDisplay(encoded, 60),
      fullEncoded: encoded,
      decoded: truncateForDisplay(decoded, 100),
      line,
      column,
      isSuspicious,
      suspicionReasons: reasons
    };

    result.base64Matches.push(encodingMatch);
    if (isSuspicious) result.totalSuspicious++;
  }

  // Detect hex
  const hexRegex = new RegExp(HEX_PATTERN.source, 'g');

  while ((match = hexRegex.exec(content)) !== null) {
    const encoded = match[1] || match[0];

    // Skip if too short
    if (encoded.length < DEFAULT_MIN_HEX_LENGTH) continue;

    // Skip known safe patterns (hashes, UUIDs)
    if (isKnownSafeHex(encoded)) continue;

    // Try to decode
    const decoded = safeHexDecode(encoded);
    if (!decoded || decoded.length === 0) continue;

    // Skip if decoded is mostly non-printable
    const printableRatio = getPrintableRatio(decoded);
    if (printableRatio < 0.5) continue;

    // Analyze for suspiciousness
    const { isSuspicious, reasons } = analyzeSuspiciousness(decoded);

    const { line, column } = getLineInfo(content, match.index);

    const encodingMatch: EncodingMatch = {
      type: 'hex',
      encoded: truncateForDisplay(encoded, 60),
      fullEncoded: encoded,
      decoded: truncateForDisplay(decoded, 100),
      line,
      column,
      isSuspicious,
      suspicionReasons: reasons
    };

    result.hexMatches.push(encodingMatch);
    if (isSuspicious) result.totalSuspicious++;
  }

  return result;
}

/**
 * Output encoding analysis results to stderr
 */
function outputEncodingResults(
  results: EncodingAnalysisResult,
  linePrefix: string,
  detailsOnly: boolean
): void {
  const { base64Matches, hexMatches } = results;

  // Output base64 findings
  if (base64Matches.length > 0) {
    const suspiciousCount = base64Matches.filter(m => m.isSuspicious).length;

    if (!detailsOnly || suspiciousCount > 0) {
      stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [base64] Found ${BLUE_COLOR}${base64Matches.length}${RESET_COLOR} base64 string${base64Matches.length !== 1 ? 's' : ''}`);
      if (suspiciousCount > 0) {
        stderr.write(` (${FAIL_COLOR}${suspiciousCount} suspicious${RESET_COLOR})`);
      }
      stderr.write(`\n`);

      for (const match of base64Matches) {
        // In details-only mode, only show suspicious matches
        if (detailsOnly && !match.isSuspicious) continue;

        const statusColor = match.isSuspicious ? FAIL_COLOR : CYAN_COLOR;
        const statusIcon = match.isSuspicious ? XMARK : '?';

        stderr.write(`${linePrefix}    ${statusColor}${statusIcon}${RESET_COLOR} Line ${match.line}: ${MAGENTA_COLOR}${match.encoded}${RESET_COLOR}\n`);
        stderr.write(`${linePrefix}      Decodes to: "${BLUE_COLOR}${match.decoded}${RESET_COLOR}"\n`);

        if (match.isSuspicious && match.suspicionReasons.length > 0) {
          stderr.write(`${linePrefix}      ${FAIL_COLOR}Reasons:${RESET_COLOR}\n`);
          for (const reason of match.suspicionReasons) {
            stderr.write(`${linePrefix}        - ${reason}\n`);
          }
        }
      }
    }
  }

  // Output hex findings
  if (hexMatches.length > 0) {
    const suspiciousCount = hexMatches.filter(m => m.isSuspicious).length;

    if (!detailsOnly || suspiciousCount > 0) {
      stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [hex] Found ${BLUE_COLOR}${hexMatches.length}${RESET_COLOR} hex string${hexMatches.length !== 1 ? 's' : ''}`);
      if (suspiciousCount > 0) {
        stderr.write(` (${FAIL_COLOR}${suspiciousCount} suspicious${RESET_COLOR})`);
      }
      stderr.write(`\n`);

      for (const match of hexMatches) {
        // In details-only mode, only show suspicious matches
        if (detailsOnly && !match.isSuspicious) continue;

        const statusColor = match.isSuspicious ? FAIL_COLOR : CYAN_COLOR;
        const statusIcon = match.isSuspicious ? XMARK : '?';

        stderr.write(`${linePrefix}    ${statusColor}${statusIcon}${RESET_COLOR} Line ${match.line}: ${MAGENTA_COLOR}${match.encoded}${RESET_COLOR}\n`);
        stderr.write(`${linePrefix}      Decodes to: "${BLUE_COLOR}${match.decoded}${RESET_COLOR}"\n`);

        if (match.isSuspicious && match.suspicionReasons.length > 0) {
          stderr.write(`${linePrefix}      ${FAIL_COLOR}Reasons:${RESET_COLOR}\n`);
          for (const reason of match.suspicionReasons) {
            stderr.write(`${linePrefix}        - ${reason}\n`);
          }
        }
      }
    }
  }
}

interface ReplacementInfo {
  count: number;
  name: string;
}

// Smuggling method types for tracking
interface SmugglingResult {
  method: 'unicode-tags' | 'sneaky-bits' | 'variant-sel';
  text: string;
  charCount: number;
}

// Strictness levels:
// 0 = default: only detect smuggling (tag characters, sneaky bits, variant selectors)
// 1 = strict (-s): detect smuggling + invisible formatting
// 2 = super strict (-S): detect smuggling + invisible formatting + homoglyphs
function cleanContent(content: string, strictness: number = 0): {
  cleaned: string;
  invisibleReplacements: Map<string, ReplacementInfo>;
  homoglyphReplacements: Map<string, ReplacementInfo>;
  smugglingSequencesRemoved: number;
  smugglingCharactersRemoved: number;
  hiddenTexts: string[];
  // New: detailed smuggling results by method
  smugglingResults: SmugglingResult[];
} {
  const invisibleReplacements = new Map<string, ReplacementInfo>();
  const homoglyphReplacements = new Map<string, ReplacementInfo>();
  const hiddenTexts: string[] = [];
  const smugglingResults: SmugglingResult[] = [];
  let smugglingSequencesRemoved = 0;
  let smugglingCharactersRemoved = 0;
  let cleaned = '';

  // State tracking for Unicode tag sequences
  let inTagSequence = false;
  let currentTagText = '';

  // State tracking for sneaky bits sequences
  let sneakyBits: number[] = [];

  // State tracking for variant selector sequences
  let variantSelectors: number[] = [];

  // Helper to flush sneaky bits if we have a complete sequence
  const flushSneakyBits = () => {
    if (sneakyBits.length >= 8) {
      const decoded = decodeSneakyBits(sneakyBits);
      if (decoded) {
        hiddenTexts.push(decoded);
        smugglingResults.push({
          method: 'sneaky-bits',
          text: decoded,
          charCount: sneakyBits.length
        });
        smugglingSequencesRemoved++;
      }
    }
    sneakyBits = [];
  };

  // Helper to flush variant selectors
  const flushVariantSelectors = () => {
    if (variantSelectors.length > 0) {
      const decoded = decodeVariantSelectors(variantSelectors);
      if (decoded) {
        hiddenTexts.push(decoded);
        smugglingResults.push({
          method: 'variant-sel',
          text: decoded,
          charCount: variantSelectors.length
        });
        smugglingSequencesRemoved++;
      }
    }
    variantSelectors = [];
  };

  for (const char of content) {
    const codePoint = char.codePointAt(0);
    if (codePoint === undefined) {
      cleaned += char;
      continue;
    }

    // TIER 1a: Unicode tag characters (original smuggling method)
    if (isSmugglingChar(codePoint)) {
      // Flush other sequence types
      flushSneakyBits();
      flushVariantSelectors();

      if (!inTagSequence) {
        inTagSequence = true;
        if (currentTagText) {
          hiddenTexts.push(currentTagText);
          smugglingResults.push({
            method: 'unicode-tags',
            text: currentTagText,
            charCount: currentTagText.length + 2 // +2 for begin/cancel tags
          });
          currentTagText = '';
        }
        smugglingSequencesRemoved++;
      }
      smugglingCharactersRemoved++;
      // Extract the hidden ASCII character
      const ascii = tagToAscii(codePoint);
      if (ascii) {
        currentTagText += ascii;
      }
      continue;
    } else if (inTagSequence) {
      // End of tag sequence
      if (currentTagText) {
        hiddenTexts.push(currentTagText);
        smugglingResults.push({
          method: 'unicode-tags',
          text: currentTagText,
          charCount: smugglingCharactersRemoved
        });
        currentTagText = '';
      }
      inTagSequence = false;
    }

    // TIER 1b: Sneaky bits (invisible times/plus for binary encoding)
    if (isSneakyBitChar(codePoint)) {
      // Flush variant selectors if we're switching methods
      flushVariantSelectors();

      sneakyBits.push(codePoint);
      smugglingCharactersRemoved++;
      continue;
    } else if (sneakyBits.length > 0) {
      // End of sneaky bits sequence
      flushSneakyBits();
    }

    // TIER 1c: Variant selectors
    if (isVariantSelector(codePoint)) {
      // Flush sneaky bits if switching methods
      flushSneakyBits();

      variantSelectors.push(codePoint);
      smugglingCharactersRemoved++;
      continue;
    } else if (variantSelectors.length > 0) {
      // End of variant selector sequence
      flushVariantSelectors();
    }

    // TIER 2: Process invisible formatting characters only in strict mode (-s or -S)
    // Note: sneaky bit chars (2062, 2064) are excluded from REPLACEMENTS handling
    // when detected as part of a sequence above
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

  // Flush any remaining sequences at end of content
  if (currentTagText) {
    hiddenTexts.push(currentTagText);
    smugglingResults.push({
      method: 'unicode-tags',
      text: currentTagText,
      charCount: smugglingCharactersRemoved
    });
  }
  flushSneakyBits();
  flushVariantSelectors();

  return { cleaned, invisibleReplacements, homoglyphReplacements, smugglingSequencesRemoved, smugglingCharactersRemoved, hiddenTexts, smugglingResults };
}

// Sigil data file helpers
function getDataFilePath(sigil: string): string {
  return join(tmpdir(), `guild-${TOOL_NAME}-${sigil}.dat`);
}

function extractRepoFromPath(filepath: string): string {
  const match = filepath.match(/\.repos\/([^/]+\/[^/]+)\//);
  return match ? match[1] : "unknown";
}

function recordData(sigil: string, filepath: string, hasSmugglingIssues: boolean): void {
  const dataFile = getDataFilePath(sigil);
  const repo = extractRepoFromPath(filepath);
  // Format: repo|has_smuggling (1 or 0)
  const record = `${repo}|${hasSmugglingIssues ? 1 : 0}\n`;
  appendFileSync(dataFile, record);
}

function generateReport(sigil: string): string {
  const dataFile = getDataFilePath(sigil);
  if (!existsSync(dataFile)) {
    return "";
  }

  const content = readFileSync(dataFile, 'utf-8');
  const lines = content.trim().split('\n').filter(l => l);

  const repoStats = new Map<string, { total: number; smuggling: number }>();

  for (const line of lines) {
    const [repo, smugglingFlag] = line.split('|');
    if (!repoStats.has(repo)) {
      repoStats.set(repo, { total: 0, smuggling: 0 });
    }
    const stats = repoStats.get(repo)!;
    stats.total++;
    if (smugglingFlag === '1') {
      stats.smuggling++;
    }
  }

  const totalRepos = repoStats.size;
  let totalFiles = 0;
  let totalSmuggling = 0;

  for (const stats of repoStats.values()) {
    totalFiles += stats.total;
    totalSmuggling += stats.smuggling;
  }

  // Cleanup
  unlinkSync(dataFile);

  if (totalRepos === 0) return "";

  const avgFilesPerRepo = Math.round(totalFiles / totalRepos);

  let report = `  Repos analyzed: ${totalRepos}\n`;
  report += `  Total files scanned: ${totalFiles}\n`;
  report += `  Average files per repo: ${avgFilesPerRepo}\n`;
  report += `  Files with smuggling detected: ${totalSmuggling}`;

  return report;
}

function usage() {
  stderr.write(`Usage: ascii-cutterman [-s|-S] [-i] [-o output.md] [-n|-nn|-d] <filename>

The ASCII Cutterman combats the ASCII Smuggler!  Taking the supplied file, it
detects and removes invisible character sequences that can be used to hide text.
The hidden text is revealed on stderr while the "cleaned" original file is sent
to stdout.

SMUGGLING DETECTION (always-on, Tier 1):
  [unicode-tags]  Unicode tag characters (U+E0000-U+E007F) - original method
  [sneaky-bits]   Binary encoding via U+2062 (0) and U+2064 (1) invisible chars
  [variant-sel]   Variant Selectors VS1-VS256 byte mapping

ENCODING DETECTION (always-on):
  [base64]   Base64-encoded strings (decoded and analyzed for suspicious content)
  [hex]      Hex-encoded strings (decoded and analyzed for suspicious content)

Encoding detection is always-on and will flag suspicious decoded content such as
shell commands, eval() calls, prompt injection attempts, and other security-relevant
patterns. Non-suspicious encodings are reported but don't affect exit code.

WARNING: Stripping invisible formatting characters (-s) and homoglyphs (-S) can
be useful to combat fingerprinting and steganography, but may break legitimate
Unicode formatting in multilingual text, mathematical notation, or styled text.

Strictness levels (for Unicode processing):
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
  0 - Clean (no obfuscation or suspicious patterns found)
  1 - Naughty (Unicode smuggling OR suspicious encoded content detected)
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
  sigil?: string;
  reportMode: boolean;
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
    prefix: undefined as string | undefined,
    sigil: undefined as string | undefined,
    reportMode: false
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
    } else if (arg === '-g') {
      // Sigil flag - for grouping runs and data collection
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        result.sigil = args[i + 1];
        i += 2;
      } else {
        i++;
      }
    } else if (arg === '-r') {
      // Report flag - generate report for sigil
      if (i + 1 < args.length && !args[i + 1].startsWith('-')) {
        result.sigil = args[i + 1];
        result.reportMode = true;
        i += 2;
      } else {
        i++;
      }
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

  // Handle report mode - no filename needed
  if (options.reportMode && options.sigil) {
    const report = generateReport(options.sigil);
    if (report) {
      stdout.write(report + '\n');
    }
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
    const { cleaned, invisibleReplacements, homoglyphReplacements, smugglingSequencesRemoved, smugglingCharactersRemoved, hiddenTexts, smugglingResults } = cleanContent(content, options.strictness);

    // Run encoding detection (always-on)
    const encodingResults = detectEncodings(cleaned);

    // Calculate what changed
    const hasUnicodeChanges = invisibleReplacements.size > 0 || homoglyphReplacements.size > 0 || smugglingCharactersRemoved > 0;
    const hasEncodingFindings = encodingResults.base64Matches.length > 0 || encodingResults.hexMatches.length > 0;
    const hasSuspiciousEncodings = encodingResults.totalSuspicious > 0;
    const hasChanges = hasUnicodeChanges || hasEncodingFindings;

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
        if (hasUnicodeChanges) {
          if (smugglingResults.length > 0) {
            // Group results by method for cleaner output
            const byMethod = new Map<string, typeof smugglingResults>();
            for (const result of smugglingResults) {
              const existing = byMethod.get(result.method) || [];
              existing.push(result);
              byMethod.set(result.method, existing);
            }

            for (const [method, results] of byMethod) {
              const totalChars = results.reduce((sum, r) => sum + r.charCount, 0);
              stderr.write(`${linePrefix}${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [${method}] SMUGGLING DETECTED: ${BLUE_COLOR}${results.length}${RESET_COLOR} sequence${results.length !== 1 ? 's' : ''} (${BLUE_COLOR}${totalChars}${RESET_COLOR} character${totalChars !== 1 ? 's' : ''})\n`);
              results.forEach((result, idx) => {
                stderr.write(`${linePrefix}    Sequence ${idx + 1}: "${BLUE_COLOR}${result.text}${RESET_COLOR}"\n`);
              });
            }
          }

          if (invisibleReplacements.size > 0) {
            stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [unicode] Invisible formatting characters detected:\n`);
            invisibleReplacements.forEach((info, char) => {
              stderr.write(`${linePrefix}    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          if (homoglyphReplacements.size > 0) {
            stderr.write(`${linePrefix}${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [unicode] Homoglyphs detected:\n`);
            homoglyphReplacements.forEach((info, char) => {
              stderr.write(`${linePrefix}    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }
        }

        // Output encoding results in details-only mode
        if (encodingResults.base64Matches.length > 0 || encodingResults.hexMatches.length > 0) {
          outputEncodingResults(encodingResults, linePrefix, true);
        }
      } else {
        // Normal mode - show full output
        // Determine if we need extra newlines for visual separation
        // We add newlines when:
        // 1. Output goes to stdout (no -i or -o option) AND
        // 2. stdout is a TTY (not redirected) AND
        // 3. Not using -n or -nn options
        const needsNewlines = !options.inPlace && !options.outputFile && !options.noOutput && isatty(stdout.fd);
        const newlinePrefix = needsNewlines ? '\n\n' : '';

        if (!hasChanges) {
          stderr.write(`${newlinePrefix}${SUCCESS_COLOR}${CHECKMARK} SUCCESS:${RESET_COLOR} clean - No obfuscation detected in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
        } else {
          // Determine severity: smuggling or suspicious encodings are FAIL
          const hasSmugglingIssues = smugglingCharactersRemoved > 0;
          const hasSuspiciousEncodings = encodingResults.totalSuspicious > 0;

          if (hasSmugglingIssues || hasSuspiciousEncodings) {
            stderr.write(`${newlinePrefix}${FAIL_COLOR}${XMARK} FAIL:${RESET_COLOR} Obfuscation detected in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
          } else if (hasUnicodeChanges) {
            stderr.write(`${newlinePrefix}${YELLOW_COLOR}⚠ WARNING:${RESET_COLOR} Suspicious characters found in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
          } else {
            // Only has non-suspicious base64/hex - informational
            stderr.write(`${newlinePrefix}${CYAN_COLOR}ℹ INFO:${RESET_COLOR} Encoded content found in ${MAGENTA_COLOR}${options.filename}${RESET_COLOR}\n`);
          }

          if (smugglingResults.length > 0) {
            // Group results by method for cleaner output
            const byMethod = new Map<string, typeof smugglingResults>();
            for (const result of smugglingResults) {
              const existing = byMethod.get(result.method) || [];
              existing.push(result);
              byMethod.set(result.method, existing);
            }

            for (const [method, results] of byMethod) {
              const totalChars = results.reduce((sum, r) => sum + r.charCount, 0);
              stderr.write(`${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [${method}] SMUGGLING: ${BLUE_COLOR}${results.length}${RESET_COLOR} sequence${results.length !== 1 ? 's' : ''} (${BLUE_COLOR}${totalChars}${RESET_COLOR} character${totalChars !== 1 ? 's' : ''})\n`);
              stderr.write(`${FAIL_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [${method}] Hidden text:\n`);
              results.forEach((result, idx) => {
                stderr.write(`    Sequence ${idx + 1}: "${BLUE_COLOR}${result.text}${RESET_COLOR}"\n`);
              });
            }
          }

          if (invisibleReplacements.size > 0) {
            stderr.write(`${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [unicode] Invisible formatting characters replaced:\n`);
            invisibleReplacements.forEach((info, char) => {
              stderr.write(`    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          if (homoglyphReplacements.size > 0) {
            stderr.write(`${YELLOW_COLOR}${DOWN_RIGHT_ARROW}${RESET_COLOR} [unicode] Homoglyphs replaced with ASCII equivalents:\n`);
            homoglyphReplacements.forEach((info, char) => {
              stderr.write(`    ${char} (${info.name}): ${BLUE_COLOR}${info.count}${RESET_COLOR} occurrence${info.count > 1 ? 's' : ''}\n`);
            });
          }

          // Output encoding results
          if (encodingResults.base64Matches.length > 0 || encodingResults.hexMatches.length > 0) {
            outputEncodingResults(encodingResults, linePrefix, false);
          }

          if (options.inPlace) {
            stderr.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} File ${MAGENTA_COLOR}${options.filename}${RESET_COLOR} updated in-place\n`);
          } else if (options.outputFile) {
            stderr.write(`${SUCCESS_COLOR}${CHECKMARK}${RESET_COLOR} Cleaned output written to ${MAGENTA_COLOR}${options.outputFile}${RESET_COLOR}\n`);
          }
        }
      }
    }

    // Record data if sigil provided
    if (options.sigil) {
      recordData(options.sigil, options.filename!, smugglingCharactersRemoved > 0 || hasSuspiciousEncodings);
    }

    // Exit with appropriate code:
    // 0 = Clean (nothing suspicious)
    // 1 = Fail (smuggling detected OR suspicious encodings found)
    // Note: Non-suspicious encodings and minor Unicode issues don't trigger failure
    const shouldFail = smugglingCharactersRemoved > 0 || hasSuspiciousEncodings;
    exit(shouldFail ? 1 : 0);
  } catch (error) {
    if (!options.silent) {
      stderr.write(`${FAIL_COLOR}${XMARK} ERROR:${RESET_COLOR} ${error}\n`);
    }
    exit(2);
  }
}

main();
