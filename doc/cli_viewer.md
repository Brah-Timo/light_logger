# CLI Viewer

light_logger ships with a command-line log viewer.

## Usage

```bash
dart run bin/log_viewer.dart [options] <log-directory>
```

## Options

| Flag | Description |
|------|-------------|
| `--level <level>` | Filter by minimum level (verbose/debug/info/warning/error/fatal) |
| `--tag <tag>` | Filter by tag name |
| `--from <iso8601>` | Show entries after this timestamp |
| `--to <iso8601>` | Show entries before this timestamp |
| `--text <query>` | Case-insensitive text search |
| `--limit <n>` | Max entries to display |
| `--format <fmt>` | Output format: `text` (default), `json`, `csv` |
| `--export <file>` | Write output to file instead of stdout |

## Examples

```bash
# Show last 100 errors
dart run bin/log_viewer.dart --level error --limit 100 /data/app/logs

# Search for DB timeouts in the last hour
dart run bin/log_viewer.dart \
  --tag Database \
  --text timeout \
  --from $(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ) \
  /data/app/logs

# Export all warnings to CSV
dart run bin/log_viewer.dart \
  --level warning \
  --format csv \
  --export /tmp/warnings.csv \
  /data/app/logs
```
