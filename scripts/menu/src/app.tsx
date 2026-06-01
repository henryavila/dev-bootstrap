/**
 * app.tsx — entry point for the mesh setup wizard (Ink + blink-tui).
 *
 * Invoked as `node index.js [--dry-run]` by setup.sh / scripts/runners/menu.sh.
 * Detects the icon set, reads the platform's manifests, and runs the screen
 * flow. On confirm it writes ~/.config/mesh/{selections.list,params.env} and
 * exits 0; on cancel it exits 1 so the caller falls back to saved/default.
 *
 * NOTE: screen flow (TopicPicker → OptionsForm → Summary → Apply) lands in
 * T-304+. This bootstrap renders a manifest summary to prove the toolchain.
 */
import { render, Box, Text } from 'ink';
import { ThemeProvider, Header, detectIconSet } from '@henryavila/blink-tui';
import { readAllManifests, filterByPlatform, flattenBundles } from './core/manifest-reader.js';
import { detectPlatform } from './core/platform.js';

function Summary() {
  const platform = detectPlatform();
  const topics = filterByPlatform(readAllManifests(), platform);
  const bundles = flattenBundles(topics);
  return (
    <Box flexDirection="column" paddingX={1}>
      <Header title="mesh setup" subtitle={`${platform} · ${topics.length} topics · ${bundles.length} bundles`} />
      <Box flexDirection="column" marginTop={1}>
        {topics.map((t) => (
          <Text key={t.id}>
            {t.header.label} ({t.bundles.length})
          </Text>
        ))}
      </Box>
    </Box>
  );
}

async function main() {
  const iconSet = await detectIconSet();
  const { waitUntilExit } = render(
    <ThemeProvider iconSet={iconSet}>
      <Summary />
    </ThemeProvider>,
  );
  await waitUntilExit();
  process.exit(0);
}

main();
