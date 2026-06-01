/**
 * platform.ts — detect the host platform, mirroring scripts/lib/detect-os.sh:
 *   Darwin → mac · Linux+microsoft in /proc/version → wsl · else linux.
 *
 * MESH_PLATFORM overrides (so a caller — or a test — can pin it); the engine is
 * invoked with the same value via --platform.
 */
import { readFileSync } from 'node:fs';
import type { Platform } from '../types.js';

export function detectPlatform(): Platform {
  const override = process.env.MESH_PLATFORM?.trim();
  if (override === 'mac' || override === 'wsl' || override === 'linux') return override;

  if (process.platform === 'darwin') return 'mac';
  if (process.platform === 'linux') {
    try {
      if (/microsoft/i.test(readFileSync('/proc/version', 'utf8'))) return 'wsl';
    } catch {
      /* /proc/version unreadable — fall through to linux */
    }
    return 'linux';
  }
  // Unknown host — default to linux so the menu still renders (engine re-detects).
  return 'linux';
}
