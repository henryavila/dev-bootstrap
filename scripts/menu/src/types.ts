/**
 * Manifest v2 types — the TypeScript mirror of schema/manifest.schema.json.
 *
 * The authoritative cross-reference enforcer is scripts/lib/validate-manifest.sh
 * (cycles, requires_bundles targets, when:/derive_from resolution). These types
 * are the shape contract the menu reads against; they intentionally match the
 * JSON schema's field set 1:1 so a manifest that validates also parses here.
 */

export type Platform = 'mac' | 'wsl' | 'linux';

export type ItemType =
  | 'custom'
  | 'brew-formula'
  | 'brew-cask'
  | 'apt'
  | 'npm-global'
  | 'npx'
  | 'cargo'
  | 'pip'
  | 'git-clone'
  | 'github-release'
  | 'go-install'
  | 'deploy';

/** The five level-3 option controls. These map 1:1 to blink's Form FieldKind. */
export type OptionType = 'multiselect' | 'select' | 'toggle' | 'text' | 'secret';

export interface TopicHeader {
  label: string;
  hint?: string;
  required?: boolean;
  order: number;
  description?: string;
}

export interface Choice {
  value: string;
  label: string;
  default?: boolean;
}

export interface Option {
  name: string;
  type: OptionType;
  label: string;
  /** The env var the resolved value is written under in params.env. */
  env: string;
  description?: string;
  required?: boolean;
  /** Static default (string for text/select/toggle; string[] for multiselect). */
  default?: unknown;
  /** Shell command whose stdout pre-fills a text field. */
  default_from?: string;
  /** Inline choices for select/multiselect. */
  choices?: Choice[];
  /** Derive a select's choices from another option's selected values. */
  derive_from?: string;
  /** A file (relative to the topic dir) whose lines are the multiselect choices. */
  source?: string;
  /** multiselect lower bound. */
  required_min?: number;
}

export interface Item {
  name: string;
  type: ItemType;
  spec?: string;
  script?: string;
  check?: string;
  platforms?: Platform[];
  when?: string;
  idempotent?: boolean;
  autoupdate?: boolean;
  restart_service?: string;
  uninstall_tier?: number;
  post?: string;
  rollback?: string;
}

export interface Bundle {
  name: string;
  label: string;
  desc: string;
  platforms?: Platform[];
    required?: boolean;
    default_selected?: boolean;
    requires_bundles?: string[];
    /** Present when this bundle is mesh-node membership (stripped by --no-mesh). */
    membership?: 'mesh';
  icon_name?: string;
  items: Item[];
  options?: Option[];
}

export interface Topic {
  /** Directory name under topics/ — the topic id used in `topic/bundle` keys. */
  id: string;
  header: TopicHeader;
  bundles: Bundle[];
  /** Absolute path to the topic directory (for resolving option `source` files). */
  dir: string;
}

/** A bundle paired with its owning topic — the unit the menu selects. */
export interface BundleRef {
  topic: Topic;
  bundle: Bundle;
  /** Canonical `topic/bundle` key. */
  key: string;
}
