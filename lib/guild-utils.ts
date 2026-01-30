/**
 * Guild Utilities for TypeScript
 *
 * Common functionality for Guild TypeScript tools.
 * Provides consistent styling, colors, and table formatting.
 *
 * Usage:
 *   import { colors, symbols, table } from '../lib/guild-utils';
 */

// ═══════════════════════════════════════════════════════════════════════════════
// COLOR DEFINITIONS
// ═══════════════════════════════════════════════════════════════════════════════

export const colors = {
  RED: '\x1b[0;31m',
  GREEN: '\x1b[0;32m',
  YELLOW: '\x1b[0;33m',
  BLUE: '\x1b[0;34m',
  MAGENTA: '\x1b[0;35m',
  CYAN: '\x1b[0;36m',
  BOLD: '\x1b[1m',
  NC: '\x1b[0m',

  // Aliases for consistency
  SUCCESS: '\x1b[0;32m',
  FAIL: '\x1b[0;31m',
  RESET: '\x1b[0m',

  // Background colors
  CRITICAL_BG: '\x1b[41m',  // Red background
} as const;

// ═══════════════════════════════════════════════════════════════════════════════
// SYMBOLS
// ═══════════════════════════════════════════════════════════════════════════════

export const symbols = {
  CHECKMARK: '✓',
  XMARK: '✗',
  DOWN_RIGHT_ARROW: '╰─>',
  WARNING: '⚠',
  GAVEL: '⚖',
} as const;

// ═══════════════════════════════════════════════════════════════════════════════
// BOX DRAWING CHARACTERS
// ═══════════════════════════════════════════════════════════════════════════════

export const box = {
  TL: '╔',  // Top-left corner
  TR: '╗',  // Top-right corner
  BL: '╚',  // Bottom-left corner
  BR: '╝',  // Bottom-right corner
  H: '═',   // Horizontal line
  V: '║',   // Vertical line
  ML: '╠',  // Middle-left (divider)
  MR: '╣',  // Middle-right (divider)
} as const;

// ═══════════════════════════════════════════════════════════════════════════════
// TABLE FORMATTING - Conclave-style output tables
// ═══════════════════════════════════════════════════════════════════════════════

const DEFAULT_TABLE_WIDTH = 53;
const VALUE_WIDTH = 8;  // Fixed width for value column

/**
 * Generate a separator line of given length
 */
export function makeSeparator(length: number, char: string = box.H): string {
  return char.repeat(length);
}

/**
 * Center a string within a given width
 */
function center(str: string, width: number): string {
  if (str.length >= width) return str.slice(0, width);
  const leftPad = Math.floor((width - str.length) / 2);
  const rightPad = width - str.length - leftPad;
  return ' '.repeat(leftPad) + str + ' '.repeat(rightPad);
}

export const table = {
  /**
   * Generate table header with title
   * Returns: formatted header string
   */
  header(title: string, width: number = DEFAULT_TABLE_WIDTH): string {
    const border = makeSeparator(width);
    const { BOLD, NC } = colors;
    let out = '';
    out += `${BOLD}${box.TL}${border}${box.TR}${NC}\n`;
    out += `${BOLD}${box.V}${center(title, width)}${box.V}${NC}\n`;
    out += `${BOLD}${box.ML}${border}${box.MR}${NC}\n`;
    return out;
  },

  /**
   * Generate table section divider
   */
  divider(width: number = DEFAULT_TABLE_WIDTH): string {
    const border = makeSeparator(width);
    const { BOLD, NC } = colors;
    return `${BOLD}${box.ML}${border}${box.MR}${NC}\n`;
  },

  /**
   * Generate table footer
   */
  footer(width: number = DEFAULT_TABLE_WIDTH): string {
    const border = makeSeparator(width);
    const { BOLD, NC } = colors;
    return `${BOLD}${box.BL}${border}${box.BR}${NC}\n`;
  },

  /**
   * Generate a row with label and value (optionally colored)
   * Format: "║ label                    value ║"
   * @param label - Left-aligned label text
   * @param value - Right-aligned value (number or string)
   * @param color - ANSI color code (optional)
   */
  row(label: string, value: string | number, color?: string, width: number = DEFAULT_TABLE_WIDTH): string {
    const { NC } = colors;
    // Inner content = width - 2 (for leading/trailing space inside box)
    const inner = width - 2;
    const labelMax = inner - VALUE_WIDTH - 1;  // -1 for space between label and value

    // Truncate label if needed
    const displayLabel = label.slice(0, labelMax);
    const padding = ' '.repeat(labelMax - displayLabel.length);
    const valueStr = String(value).padStart(VALUE_WIDTH);

    if (color) {
      return `${box.V} ${displayLabel}${padding} ${color}${valueStr}${NC} ${box.V}\n`;
    }
    return `${box.V} ${displayLabel}${padding} ${valueStr} ${box.V}\n`;
  },

  /**
   * Generate a status row with checkmark/X
   * Format: "║ ✓ label                 value ║"
   * @param label - Label text (without symbol)
   * @param value - Numeric value
   * @param isGood - true for green checkmark, false for red X
   */
  statusRow(label: string, value: string | number, isGood: boolean, width: number = DEFAULT_TABLE_WIDTH): string {
    const { GREEN, RED, NC } = colors;
    const inner = width - 2;
    const symbolWidth = 2;  // Symbol + space
    const labelMax = inner - VALUE_WIDTH - symbolWidth - 1;

    const displayLabel = label.slice(0, labelMax);
    const padding = ' '.repeat(labelMax - displayLabel.length);
    const valueStr = String(value).padStart(VALUE_WIDTH);

    if (isGood) {
      return `${box.V} ${GREEN}${symbols.CHECKMARK}${NC} ${displayLabel}${padding} ${valueStr} ${box.V}\n`;
    }
    return `${box.V} ${RED}${symbols.XMARK}${NC} ${displayLabel}${padding} ${RED}${valueStr}${NC} ${box.V}\n`;
  },

  /**
   * Generate a section header row (cyan label, no value)
   */
  section(label: string, width: number = DEFAULT_TABLE_WIDTH): string {
    const { CYAN, NC } = colors;
    const inner = width - 2;
    const padding = ' '.repeat(inner - label.length);
    return `${box.V} ${CYAN}${label}${NC}${padding} ${box.V}\n`;
  },

  /**
   * Generate a complete table with header, rows, and footer
   * Convenience function for simple tables
   */
  simple(title: string, rows: Array<{ label: string; value: string | number; color?: string }>, width: number = DEFAULT_TABLE_WIDTH): string {
    let out = table.header(title, width);
    for (const r of rows) {
      out += table.row(r.label, r.value, r.color, width);
    }
    out += table.footer(width);
    return out;
  }
};
